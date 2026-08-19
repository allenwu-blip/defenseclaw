# Windows managed_enterprise parity plan

**Purpose.** Close the remaining gaps between the Windows and macOS `managed_enterprise` implementations so DefenseClaw can ship into the Cisco Secure Client / AVC packaging pipeline on Windows the same way it does on macOS.

**Scope.** This is a plan document, not a design doc. Every workstream cites the current-state code (file:line) and states the intended end-state contract; detailed design belongs in per-workstream specs under `docs/specs/`.

---

## 1. Executive summary

Three explicit asks from the packaging team, plus a sweep of other differences, break into six workstreams:

| # | Workstream | Ask origin | Priority | Est. size |
|---|---|---|---|---|
| A | AVC-driven Windows Setup packaging (single-handoff build kit) | Packaging ask #1 — **AVC-approved contract in [WINDOWS-AVC-PACKAGING-HANDOFF.md](docs/WINDOWS-AVC-PACKAGING-HANDOFF.md)** | P0 — blocks release | M |
| B | Deferred `config.yaml` / `targets.yaml` delivery | Packaging ask #2 | P0 — blocks UCB rollout | M |
| C | Windows UI IPC (AVC gRPC surface) | Packaging ask #3 | P0 — Secure Client integration | L |
| D | Hook enumerator service on Windows | Gap sweep | P1 | S |
| E | Deterministic-build + reproducibility knobs to support AVC | Prereq for A | P1 | S |
| F | Uninstall parity: per-user targeted purge on Windows | Gap sweep | P2 | S |

Not in scope for this plan (already at parity or intentionally different):
- Hook API / OTLP token custody (parity achieved: [hook_api_token_windows.go](internal/gateway/connector/hook_api_token_windows.go), [hook_api_acl_darwin.go](internal/gateway/connector/hook_api_acl_darwin.go)).
- `env_config.json` endpoint overlay (parity achieved: [env_config_unix.go](internal/config/env_config_unix.go), [env_config_windows.go](internal/config/env_config_windows.go)).
- Service-account model. Windows uses a virtual `NT SERVICE\…` SID pinned through [trust_windows.go:70-83](internal/managed/trust_windows.go#L70-L83); macOS runs as root — this is by design and does not need parity.
- Log rotation. Delegated to the OS on both platforms; no change.

---

## 2. Workstream A — AVC-driven Windows Setup packaging (single-handoff build kit)

**Handoff contract approved by AVC.** See [WINDOWS-AVC-PACKAGING-HANDOFF.md](docs/WINDOWS-AVC-PACKAGING-HANDOFF.md) for the AVC-facing agreement. This workstream implements that contract. Shape matches macOS: one DefenseClaw-side script, one artifact handoff, all downstream signing + assembly runs inside AVC's pipeline.

### 2.1 Current state

The Windows enterprise Setup is built in one linear pass on a DefenseClaw-owned Windows host that holds the Cisco Authenticode credentials:

1. Extract inner PEs from the gateway zip → verify commit identity → **sign inner PEs and PowerShell scripts** ([build-windows-enterprise-installer.ps1:225-248](scripts/build-windows-enterprise-installer.ps1#L225-L248)).
2. Hash each signed payload with [`Get-FileHashHex`](scripts/build-windows-enterprise-installer.ps1#L47-L49) → assemble `payload/manifest.json` ([:333-350](scripts/build-windows-enterprise-installer.ps1#L333-L350)) → embed via `//go:embed payload/*` in [main.go:27-28](cmd/defenseclaw-enterprise-setup/main.go#L27-L28) → `go build` the outer Setup.
3. **Sign the outer Setup EXE** ([:382-384](scripts/build-windows-enterprise-installer.ps1#L382-L384)).
4. Emit `.sha256` + `.provenance.json` with `setup_sha256` ([:386-399](scripts/build-windows-enterprise-installer.ps1#L386-L399)).

At install time, [`stageEnterprisePayload`](cmd/defenseclaw-enterprise-setup/platform_windows.go#L181-L218) re-hashes each extracted payload and refuses to run if the hash does not match the embedded manifest.

### 2.2 Gap

Under the approved model, AVC — not DefenseClaw — signs both the inner files and the outer Setup EXE, matching the macOS pipeline. The outer artifact embeds SHA-256 hashes of the signed inner files (via `//go:embed payload/*`), so the assembly step must run **between** the two signing rounds. AVC has confirmed they can host that assembly step (`go build -mod=vendor`) inside their pipeline, so we ship it as a script inside a build kit rather than requiring two round-trips.

### 2.3 Deliverables

**A1. `packaging/scripts/build-managed-windows-bundle.sh` — the single DefenseClaw-side entry point (extend existing).**

Extends the current script (which today produces just the cross-built gateway zip) to emit the full build kit AVC consumes. Runs on macOS/Linux exactly like `build-managed-macos-bundle.sh`. Same `--ref`, `--version`, `--dist-dir`, `--ai-common-dir`, `--keep` flags today plus:

- `--allow-unsigned` — see A3 below.
- `--script-host bash|pwsh` — controls whether the emitted `assemble.sh` or `assemble.ps1` ships inside the kit. Default matches AVC's confirmed preference from [WINDOWS-AVC-PACKAGING-HANDOFF.md](docs/WINDOWS-AVC-PACKAGING-HANDOFF.md).

Output at `./dist/windows-enterprise-buildkit-<version>/`:

```
windows-enterprise-buildkit-<version>/
├── payload/                          # AVC signs these five files
│   ├── defenseclaw.exe               # unsigned, `-tags cmid`, VERSIONINFO stamped
│   ├── defenseclaw-gateway.exe       # unsigned
│   ├── defenseclaw-hook.exe          # unsigned
│   ├── install-enterprise.ps1        # unsigned
│   └── DefenseClawEnterprise.psm1    # unsigned
├── source/                           # everything `go build` needs
│   ├── cmd/defenseclaw-enterprise-setup/
│   ├── internal/…                    # trimmed to the import graph rooted at
│   │                                 # cmd/defenseclaw-enterprise-setup
│   ├── vendor/                       # `go mod vendor`, offline-buildable
│   ├── go.mod
│   └── go.sum
├── assemble.sh                       # or assemble.ps1 — one entry point for AVC
├── payload-metadata.json             # version, source_commit, cmid_pseudo_version, expected filenames
└── README-AVC.md                     # ~20-line runbook
```

Import-graph trimming is done via `go list -deps ./cmd/defenseclaw-enterprise-setup/...` to keep the kit around 150–250 MB per the size budget AVC approved.

**A2. `assemble.sh` / `assemble.ps1` (new) — shipped inside the build kit.**

The script AVC runs between their two `signtool` invocations. Same logic on both shells (host is a formatting choice, not a semantic one):

1. Assert every file under `./payload/` has a Valid Authenticode signature and `SignerCertificate.SimpleName == "Cisco Systems, Inc."` — port of [`Assert-CiscoSignature`](scripts/build-windows-enterprise-installer.ps1#L151-L163). Refuse to proceed otherwise.
2. Compute SHA-256 of each signed payload file.
3. Generate `manifest.json` — `schema_version=1`, version, source_commit, `distribution_flavor="managed-enterprise"`, per-file hashes.
4. Drop signed payload files + manifest into `source/cmd/defenseclaw-enterprise-setup/payload/`.
5. Run `go build -mod=vendor -trimpath -buildvcs=false -buildid=defenseclaw-enterprise-setup-<source_commit> -o out/DefenseClawSetup-Enterprise-x64.exe ./cmd/defenseclaw-enterprise-setup`. `SOURCE_DATE_EPOCH` derived from the DefenseClaw source-commit timestamp — the six AVC-confirmed envs in [WINDOWS-AVC-PACKAGING-HANDOFF.md](docs/WINDOWS-AVC-PACKAGING-HANDOFF.md#4-what-avc-needs-to-confirm) are the contract this script exercises.
6. Emit `out/DefenseClawSetup-Enterprise-x64.exe.sha256` and a stub `out/DefenseClawSetup-Enterprise-x64.exe.provenance.json` (final `setup_sha256` populated by AVC's `signtool` post-step or by an in-kit finalizer, TBD in the workstream spec).

`README-AVC.md` shipped with the kit is the ~20-line runbook from [WINDOWS-AVC-PACKAGING-HANDOFF.md §5](docs/WINDOWS-AVC-PACKAGING-HANDOFF.md#5-build-kit-contract-option-a--what-avc-receives).

**A3. Local self-serve unsigned-build path (developer testing).**

Preserves the current [`-SkipSigning`](scripts/build-windows-enterprise-installer.ps1#L346) developer inner-loop under the new script shape. `build-managed-windows-bundle.sh --allow-unsigned`:

- Skips the AVC handoff entirely.
- Runs `assemble.sh` inline on the DefenseClaw side against the unsigned inner files.
- Skips step 1 of `assemble.sh` (the "Cisco signature" assertion) — the assemble script itself must accept an `--allow-unsigned` flag mirroring the existing runtime gate.
- Produces `DefenseClawSetup-Enterprise-x64.exe` with `Unsigned=true` baked into the embedded manifest — installs on a Windows test box via `... /install --allow-unsigned --certification-codex-home <path>` per [main.go:169-171](cmd/defenseclaw-enterprise-setup/main.go#L169-L171). The disposable-cert scope constraint stays — an unsigned build cannot target production paths by construction.
- CMID overlay dependency is unchanged: the `--ref develop` default and `--ai-common-dir <path>` override behave the same as today. Testing without CMID (a `--no-cmid` mode) is out of scope here; can be added as a follow-on if the deferred-config or UDS iteration loops need it.

**A4. Runtime — no changes required.**

[`stageEnterprisePayload`](cmd/defenseclaw-enterprise-setup/platform_windows.go#L181-L218) already re-hashes at extraction time and is signing-neutral. [`main.go:52-57`](cmd/defenseclaw-enterprise-setup/main.go#L52-L57) `--allow-unsigned` gate stays. AVC-signed builds ship with `Unsigned=false`; local-test builds via A3 ship with `Unsigned=true`.

**A5. Retire the current Windows-box builder.**

`scripts/build-windows-enterprise-installer.ps1` is superseded. Delete after A1–A3 land and CI is migrated. The trust-plumbing helpers ([`Assert-CiscoSignature`](scripts/build-windows-enterprise-installer.ps1#L151-L163), [`Get-FileHashHex`](scripts/build-windows-enterprise-installer.ps1#L47-L49), [`Assert-DefenseClawBinaryIdentity`](scripts/windows-binary-identity.ps1)) move under `packaging/scripts/lib/` for reuse by `assemble.ps1`.

**A6. Documentation.**

Update [WINDOWS-MACHINE-INSTALLER-INTERFACE.md](docs/WINDOWS-MACHINE-INSTALLER-INTERFACE.md) with a "AVC packaging handoff" section that points at [WINDOWS-AVC-PACKAGING-HANDOFF.md](docs/WINDOWS-AVC-PACKAGING-HANDOFF.md) as the source of truth for the contract, and describes the DefenseClaw-side operator flow (`build-managed-windows-bundle.sh`) alongside the existing macOS flow so a release engineer can find both in one place.

### 2.4 Success criteria

- `build-managed-windows-bundle.sh --ref develop --version <v>` on a Mac produces a build kit whose contents match §5 of the handoff doc byte-for-byte in structure.
- End-to-end CI job: emit build kit → dummy-sign inner (disposable cert) → run `assemble.sh` → dummy-sign outer → install on a Windows agent. Passes the runtime hash check at [`stageEnterprisePayload`](cmd/defenseclaw-enterprise-setup/platform_windows.go#L181-L218).
- Reproducibility test (see Workstream E): two independent `assemble.sh` runs on different Linux/macOS agents given byte-identical signed payloads produce byte-identical outer EXEs.
- `build-managed-windows-bundle.sh --allow-unsigned` produces a runnable local test EXE without any AVC engagement; installs on a Windows test box with `--allow-unsigned --certification-codex-home <path>` and refuses to target a non-disposable scope.
- Negative test: an outer Setup whose embedded manifest references pre-signing inner bytes MUST fail at install via [`stageEnterprisePayload`](cmd/defenseclaw-enterprise-setup/platform_windows.go#L181-L218)'s hash mismatch.

---

## 3. Workstream B — Deferred `config.yaml` / `targets.yaml` delivery

### 3.1 Current state

**macOS** already tolerates late `config.yaml` in the daemon: [config_manager.go:234-251](internal/gateway/config_manager.go#L234-L251) opens an fsnotify watch on the parent directory, and the startup reconcile at [:410-452](internal/gateway/config_manager.go#L410-L452) picks up a file that appears after boot. However the launchd installer itself fail-hard requires `--config` and `--manifest` at install ([install-enterprise.sh:590-591](packaging/launchd/install-enterprise.sh#L590-L591)).

`targets.yaml` on both platforms has **no live-reload channel** ([manifest.go:37-98](internal/enterprisehooks/manifest.go#L37-L98)); each hook-guardian reconcile re-reads it via `os.Lstat`, and startup reconcile errors out if missing ([enterprise_hooks.go:1295-1297](internal/cli/enterprise_hooks.go#L1295-L1297)).

**Windows** blocks in three places today:

1. Setup EXE preflight: [main.go:158-161](cmd/defenseclaw-enterprise-setup/main.go#L158-L161).
2. `defenseclaw enterprise windows install` CLI: [windows_enterprise_service.go:181-182](internal/cli/windows_enterprise_service.go#L181-L182).
3. PowerShell module `Get-DefenseClawLifecycleSources`: [DefenseClawEnterprise.psm1:8164-8175](packaging/windows/DefenseClawEnterprise.psm1#L8164-L8175), and the post-copy existence check at [:10990-11000](packaging/windows/DefenseClawEnterprise.psm1#L10990-L11000).

Even if all three preflights were bypassed, the gateway daemon PreRun opens `config.yaml` directly ([root.go:106-109](internal/cli/root.go#L106-L109) → [config_v8.go:434-437](internal/cli/config_v8.go#L434-L437)) and the SCM service exits.

### 3.2 Deliverables

**B1. Deferred-config install mode.**

Add a `--deferred-config` (or equivalent) flag to `defenseclaw enterprise windows install`, plumbed through to `install-enterprise.ps1`. In deferred mode:

- Skip the "must supply --config/--manifest" checks at all three layers listed above.
- Provision the canonical target paths (`<StateRoot>\etc\config.yaml`, `<StateRoot>\hook-guardian\targets.yaml`) with **ACLs only** — parent directories created + ACLed, but no file body written. Matches [DefenseClawEnterprise.psm1:3663-3736](packaging/windows/DefenseClawEnterprise.psm1#L3663-L3736) directory prep but without the file copy at [:10986-10988](packaging/windows/DefenseClawEnterprise.psm1#L10986-L10988).
- Register both services (`DefenseClawGateway`, `DefenseClawHookGuardian`) but **start them in a "waiting for configuration" state**, not "Running." The guardian starts trivially in this state — it only needs to be present to receive future starts.

**B2. Gateway daemon: retry-until-configured loop.**

Change [root.go:106-109](internal/cli/root.go#L106-L109) → [config_v8.go:434-437](internal/cli/config_v8.go#L434-L437) so a missing `config.yaml` in managed_enterprise mode does **not** hard-exit. Instead:

- Enter a bounded fsnotify-driven wait on the parent directory (reuse [config_manager.go:234-251](internal/gateway/config_manager.go#L234-L251) pattern).
- Publish `state=WaitingForConfig` on the health endpoint.
- Retry `LoadFromFile` on every `WRITE`/`CREATE` event; once it parses, transition to normal boot.
- Bounded to a documented max window (e.g. 24 h) to prevent an infinite waiting service.

**B3. Hook-guardian: late `targets.yaml` support.**

Extend the guardian's watch loop ([enterprise_hooks.go:1200-1300](internal/cli/enterprise_hooks.go#L1200-L1300)) so a missing manifest at startup does not exit. Add an fsnotify watch on the manifest's parent dir (partly wired at [:1220](internal/cli/enterprise_hooks.go#L1220)) and re-attempt `LoadManifest` on `CREATE`/`WRITE`. Reconcile pass runs only after a successful load.

**B4. UCB integration contract.**

Document the exact drop points and ACL expectations in a new section of [WINDOWS-MACHINE-INSTALLER-INTERFACE.md](docs/WINDOWS-MACHINE-INSTALLER-INTERFACE.md):

- `%ProgramData%\Cisco\Cisco Secure Client\DefenseClaw\etc\config.yaml` — ACL `NT AUTHORITY\SYSTEM` + `BUILTIN\Administrators` full control, `NT SERVICE\DefenseClawGateway` read, no other principals.
- `%ProgramData%\Cisco\Cisco Secure Client\DefenseClaw\hook-guardian\targets.yaml` — same ACL, guardian reads.
- UCB writes atomically (write-to-temp + rename) so the fsnotify wake sees a fully-formed file.

**B5. Health surface.**

Extend the sidecar's health JSON ([sidecar.go](internal/gateway/sidecar.go)) with a `configuration.state` field (`waiting_for_config` / `waiting_for_targets` / `ready`) so `defenseclaw enterprise windows status` and the AVC IPC surface (Workstream C) can report readiness accurately.

### 3.3 Success criteria

- Install with `--deferred-config` on a clean Windows box produces registered-but-waiting services.
- Drop `config.yaml` alone → gateway transitions to `waiting_for_targets`.
- Drop `targets.yaml` → both transition to `ready`; hook enforcement engages.
- Regression: legacy install (both files supplied at install time) behaves byte-for-byte identically to today.

---

## 4. Workstream C — Windows UI IPC (AVC gRPC surface)

### 4.1 Current state

**macOS** ships a UDS gRPC server for Cisco Secure Client at `/opt/cisco/secureclient/defenseclaw/ipc/defenseclaw_ipc.sock`, `root:staff 0660` ([paths.go:11-98](internal/ipc/paths.go#L11-L98), [server.go:203-259](internal/ipc/server.go#L203-L259)), with `LOCAL_PEERCRED` + `codesign` peer-auth pinning `TeamID=DE8Y96K9QP`, `SigningID/BundleID=com.cisco.secureclient.gui` ([peerauth_darwin.go](internal/ipc/peerauth_darwin.go), [managed.go:94-121](internal/config/managed.go#L94-L121)). Three read-only server-streaming RPCs: `GetHealth`, `GetStatsSnapshot`, `WatchNotifications` ([service.go:23-27](internal/ipc/service.go#L23-L27)).

**Windows** refuses to start the server ([server.go:187-192](internal/ipc/server.go#L187-L192): `"ipc unsupported on windows"`) and the peer-auth path is a stub ([peerauth_windows.go:43-45](internal/ipc/peerauth_windows.go#L43-L45)).

### 4.2 Deliverables

**Transport choice: reuse UDS on Windows.** Modern Windows (Win10 1803+, Server 2019+) supports AF_UNIX, and Go's `net.Listen("unix", ...)` binds there without a new listener implementation. The [server.go:242](internal/ipc/server.go#L242) UDS code path is reused verbatim. Named pipes are explicitly *not* used.

**Scope of the initial delivery: data transfer only. No auth.** Per the packaging team, beta is not blocked on auth. The initial cut ships an unauthenticated UDS listener so Cisco Secure Client can consume the health/stats/notifications streams. Every form of auth — codesign-equivalent peer-auth, DACL pinning of the GUI principal, bearer tokens — is deferred to a follow-up workstream once the packaging team lands on an approach.

**C1. Windows UDS listener path.**

- Remove the early-return in [server.go:187-192](internal/ipc/server.go#L187-L192) (`"ipc unsupported on windows"`).
- Socket path: `%ProgramData%\Cisco\Cisco Secure Client\DefenseClaw\ipc\defenseclaw_ipc.sock`, resolved through `TrustedProgramData` for the same fail-closed reason [env_config_windows.go:34-46](internal/config/env_config_windows.go#L34-L46) uses it.
- Parent directory + socket-file ACL: **baseline hygiene only** for the initial cut — full control for `NT SERVICE\DefenseClawGateway` + `NT AUTHORITY\SYSTEM` + `BUILTIN\Administrators`, plus read/write for `NT AUTHORITY\Authenticated Users` so Cisco Secure Client (whatever principal it ends up running under) can connect. This is deliberately permissive; the follow-up workstream tightens the DACL to a pinned Cisco Secure Client GUI principal once one is chosen. Do not leave the socket world-writable.
- `SE_DACL_PROTECTED` is set so inheritance from `ProgramData` is severed regardless.
- Listener + `grpc.NewServer` code from [server.go](internal/ipc/server.go) is reused; the platform diff is only in path resolution and baseline ACL application.

**C2. Peer-auth — fully deferred.**

- Peer-auth stub in [peerauth_windows.go:43-56](internal/ipc/peerauth_windows.go#L43-L56) stays present. Its accept path returns success unconditionally on Windows for the initial cut. Kind reported as `UnixPeerUnauthenticated` (new variant in [server.go:140-142](internal/ipc/server.go#L140-L142)) so the state is loud in health output and log lines.
- Gateway startup log emits an explicit warning: `[ipc] windows: peer-auth is deferred; UDS is DACL-permissive to Authenticated Users`. Prevents this posture drifting into production silently.
- **This is beta-only.** GA blocks on the follow-up in §4.4.

**C3. Config wiring.**

`cfg.ManagedIPCEnabled()` ([managed.go:87-92](internal/config/managed.go#L87-L92)) currently gates macOS-only. Extend to return `true` on Windows managed_enterprise once C1 is in place. Peer-auth type selector in [managed.go:94-121](internal/config/managed.go#L94-L121) grows a Windows branch reporting `UnixPeerUnauthenticated` for the initial delivery.

**C4. RPC surface.**

Reuse the existing proto (`proto/defenseclaw/secureclient/v1`) — no new RPCs, no schema break. `GetHealth`, `GetStatsSnapshot`, `WatchNotifications` all work over the pipe with the same payload shape.

**C5. Sidecar wiring.**

[sidecar.go:113-127](internal/cli/sidecar.go#L113-L127) constructs the IPC server when `cfg.ManagedIPCEnabled()` is true. On Windows, ensure the server lifecycle joins the SCM stop signal path so `Stop-Service` cleanly closes the listener.

**C6. Health-state integration.**

`GetHealth` responses on Windows must include the `configuration.state` field defined in Workstream B5, so Secure Client's UI can render "waiting for configuration."

### 4.3 Success criteria

- macOS RPC contract unchanged; wire-level tests reused.
- Windows: Cisco Secure Client GUI connects to the UDS and receives `GetHealth`, `GetStatsSnapshot`, `WatchNotifications` streams. Data transfer works end-to-end.
- SCM stop path closes the UDS listener + removes the socket file inode cleanly (matches [server.go:203-259](internal/ipc/server.go#L203-L259) macOS teardown).
- Health surface (`configuration.state` from Workstream B5) is reachable via `GetHealth` over the Windows UDS.
- Startup warning line is present when the process runs on Windows managed_enterprise, confirming the unauthenticated posture is visible.

### 4.4 Follow-up (blocks GA, not beta)

- **Auth for the Windows UDS surface.** Packaging team is scoping options (DACL pinning to a Cisco Secure Client GUI principal, bearer token from a protected file, PID-in-first-message + `WinVerifyTrust`, or an out-of-band token exchange with Secure Client). Once selected, a follow-up spec:
  - Tightens the socket-file DACL from `Authenticated Users` to the chosen principal.
  - Replaces `UnixPeerUnauthenticated` with the chosen `Kind` variant in [managed.go:94-121](internal/config/managed.go#L94-L121) and [server.go:140-142](internal/ipc/server.go#L140-L142).
  - Removes the startup warning line from C2.
- **GA gate.** The Windows UDS may not ship to GA with `UnixPeerUnauthenticated`. Enforced by a build-tag check or a release-gate assertion in the release-candidate CI.

---

## 5. Workstream D — Hook enumerator service on Windows

### 5.1 Current state

macOS runs a **third** LaunchDaemon `com.cisco.secureclient.defenseclaw.hook-enumerator` on a 300 s cadence ([hook-enumerator.plist:22-24](packaging/launchd/com.cisco.secureclient.defenseclaw.hook-enumerator.plist#L22-L24)) that keeps `targets.yaml` in sync with the discovered per-user hook surface. Windows has no equivalent — per-user enumeration is baked into install / repair / upgrade only ([DefenseClawEnterprise.psm1:3663-3736](packaging/windows/DefenseClawEnterprise.psm1#L3663-L3736)).

### 5.2 Impact

New Codex / Claude Code user profiles appearing between install and the next admin-driven `repair` are **not** picked up on Windows today. With the deferred-config Workstream B, this becomes worse: `targets.yaml` may arrive late but per-user discovery never re-runs.

### 5.3 Deliverables

**D1. `DefenseClawHookEnumerator` Windows service.**

New service running `defenseclaw enterprise windows enumerate --interval 5m` (or equivalent). Registration lives in [DefenseClawEnterprise.psm1](packaging/windows/DefenseClawEnterprise.psm1), same pattern as `DefenseClawHookGuardian` at [:3023](packaging/windows/DefenseClawEnterprise.psm1#L3023).

**D2. Enumerator logic.**

The per-user walk that today lives inline in [DefenseClawEnterprise.psm1:3663-3736](packaging/windows/DefenseClawEnterprise.psm1#L3663-L3736) is extracted into a reusable Go entry point under `internal/enterprisehooks/enumerator_windows.go`, callable both by the enumerator service and by the installer's fresh-install path. Emits an updated `targets.yaml` at the canonical path, atomically.

**D3. Guardian pickup.**

Guardian's existing fsnotify watch on `targets.yaml` ([enterprise_hooks.go:1220](internal/cli/enterprise_hooks.go#L1220)) is what wakes it after an enumerator write. Workstream B3's changes are prerequisite so a first enumeration after deferred-config install works.

### 5.4 Success criteria

- Create a new user profile with Codex installed on a running managed_enterprise box → within one enumerator cycle, hook wiring is present for that user without an admin `repair` call.

---

## 6. Workstream E — Deterministic-build support for AVC

### 6.1 Current state

The current builder runs the outer `go build` twice on a single Windows host ([build-windows-enterprise-installer.ps1:361-380](scripts/build-windows-enterprise-installer.ps1#L361-L380)) and compares hashes. Under Workstream A, the `go build` runs inside AVC's pipeline on hardware DefenseClaw does not control, so byte-reproducibility across hosts becomes a hard contract, not a nice-to-have.

### 6.2 Deliverables

**E1. Fully deterministic outer `go build` inputs.**

`assemble.sh` / `assemble.ps1` (Workstream A2) run `go build -mod=vendor -trimpath -buildvcs=false -buildid=defenseclaw-enterprise-setup-<source_commit>` with `SOURCE_DATE_EPOCH` derived from the source-commit timestamp. Every wall-clock, build-host, and VCS input eliminated. Matches the six envs AVC signed off in [WINDOWS-AVC-PACKAGING-HANDOFF.md §4](docs/WINDOWS-AVC-PACKAGING-HANDOFF.md#4-what-avc-needs-to-confirm).

**E2. Manifest ordering / whitespace stability.**

`manifest.json` and `payload-metadata.json` must be byte-stable across `bash` and `pwsh` script hosts. Use a small Go helper (or `jq`) with sorted keys and fixed whitespace rather than the shell's default JSON serializer. Same for `.provenance.json`.

**E3. Vendored-tree stability.**

`go mod vendor` output must be byte-identical across the macOS host that runs `build-managed-windows-bundle.sh` and AVC's runner. Pin Go toolchain version in `go.mod`'s `toolchain` directive so the vendored tree is reproducible.

**E4. Reproducibility test in CI.**

Two independent `assemble.sh` runs on different agents (one Linux, one macOS) given byte-identical signed payloads must produce byte-identical outer Setup EXEs. Blocks Workstream A merge.

### 6.3 Success criteria

- Two runs on different agents produce byte-identical `DefenseClawSetup-Enterprise-x64.exe` given identical signed payload inputs.
- `manifest.json` / `payload-metadata.json` / `provenance-preamble.json` are byte-stable across `bash` and `pwsh` script hosts.

---

## 7. Workstream F — Uninstall parity

### 7.1 Current state

macOS uninstall supports `--purge`, `--keep-agent-configs`, `--user` for targeted per-user cleanup ([uninstall.sh:19-149](packaging/macos/uninstall.sh#L19-L149)). Windows implements a transactional uninstall in [DefenseClawEnterprise.psm1:6003-6086](packaging/windows/DefenseClawEnterprise.psm1#L6003-L6086) but exposes only "uninstall everything." There is no way to remove a single user's hook wiring while other users remain registered.

### 7.2 Deliverables

**F1. `--user <SID>` flag on `defenseclaw enterprise windows uninstall`.**

Restrict cleanup to that user's hook wiring and per-user artefacts; leave services and machine ACLs untouched. Piggy-backs on the enumerator's per-user model from Workstream D2.

**F2. `--keep-config` / `--purge` symmetry.**

Match macOS semantics: default keeps `config.yaml` / `targets.yaml` on disk; `--purge` removes them.

### 7.3 Success criteria

- `enterprise windows uninstall --user S-1-5-21-…` removes only that user's hook wiring; other users remain protected.

---

## 8. Ordering and dependencies

```
E (deterministic builds) ──┐
                           ▼
A (build kit + assemble)   ─── depends on E4 reproducibility gate

B (deferred config)        ─── independent of A/C
                                │
                                ▼
D (enumerator svc)         ─── depends on B3 (guardian fsnotify) landing first

C (UI IPC)                 ─── depends on B5 (config.state health field)

F (uninstall parity)       ─── depends on D (per-user enumerator model)
```

Suggested sequencing:
1. **Week 1–2:** E first (deterministic build primitives), then A (build kit + `assemble.sh`). Unblocks the packaging team on the AVC handoff.
2. **Week 2–3:** B — the daemon and guardian late-arrival paths. Also unblocks UCB.
3. **Week 3–4:** C (UI IPC) once B5's health surface is in.
4. **Week 4–5:** D (enumerator) once B3 has landed.
5. **Week 5:** F (uninstall parity).

Each workstream lands as a separate spec under `docs/specs/NNN-<slug>/` with its own `plan.md` / `requirements.md` / `design.md` / `tasks.md` per the `spec-driven-dev` skill.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| `assemble.sh` running in AVC's isolated pipeline is a new place for `go build` to fail | Workstream A CI runs `assemble.sh` on both Linux and macOS agents to catch environment surprises before AVC sees them. Kit ships `go mod vendor` output so no network reach at build time. |
| AVC pipeline turnaround per handoff still stretches CI cycles | Handoff count is now 1 (matches macOS). Workstream E gives byte-identical rebuilds so re-signing the same source is a no-op for AVC. |
| Build-kit size (~150-250 MB) inflates over time as the import graph grows | Workstream A trims via `go list -deps ./cmd/defenseclaw-enterprise-setup/...` at build time; CI asserts an upper bound (say 300 MB) and fails if exceeded so bloat is caught. |
| Deferred config leaves the box in a permanently-waiting state | B2 introduces a bounded wait window and health surfacing so it is loudly visible. |
| Windows UDS ships to beta with **no auth at all** — DACL is permissive to Authenticated Users, peer-auth is a stub | Deliberate, agreed with the packaging team so beta isn't blocked. Startup warning makes the posture visible in logs. GA is blocked on Workstream C.4 landing (build-tag / release-gate assertion). |
| Unauthenticated posture leaks into GA silently | Emit `UnixPeerUnauthenticated` in health output + startup warning line; add a release-candidate CI assertion that rejects a build reporting this Kind. |
| Windows AF_UNIX has narrower deployment history than named pipes | Documented OS floor: Win10 1803+ / Server 2019+. Feature-detect at startup and surface a clear error on older builds. Windows managed_enterprise targets are already inside this floor per the release contract. |
| Enumerator service running on a very large user population is slow | D2's Go enumerator can walk profiles in parallel; add a bounded worker pool and per-cycle timeout. |

---

## 10. Not planned here (deliberate exclusions)

- **macOS-side `verify` / `repair` / `upgrade` CLI actions.** Windows has these ([main.go:304-310, 419-478](cmd/defenseclaw-setup/main.go#L304-L310)) and macOS does not. Adding them to macOS is a separate cross-platform effort and not required for Windows readiness.
- **macOS-side install-time Authenticode/codesign walk.** Windows-only inventory in [authenticode.go:27-767](cmd/defenseclaw-setup/authenticode.go#L27-L767) has no macOS analog; macOS delegates to Gatekeeper. No change.
- **macOS-side transactional install rollback.** Windows has it, macOS is fresh-install-only. Out of scope.
- **Service-account model unification.** Windows virtual `NT SERVICE\…` SID vs macOS root: intentional platform difference.
- **Log rotation.** Delegated to the OS on both platforms.
