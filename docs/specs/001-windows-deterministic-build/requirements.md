# Requirements: Windows deterministic-build support for AVC

**Workstream:** E (see [WINDOWS-MANAGED-ENTERPRISE-PARITY-PLAN.md §6](../../WINDOWS-MANAGED-ENTERPRISE-PARITY-PLAN.md#6-workstream-e--deterministic-build-support-for-avc))

**Status:** Draft — pending user approval before implementation.

## Context

Workstream A (AVC-driven Windows Setup packaging) moves the outer `go build` for `DefenseClawSetup-Enterprise-x64.exe` from a DefenseClaw-owned Windows host into AVC's signing pipeline on hardware DefenseClaw does not control. Once assembly runs on a third-party host, **byte-identical outer EXEs across runs and across hosts becomes a hard contract** — the current on-host hash-compare self-check at [`scripts/build-windows-enterprise-installer.ps1:361-380`](../../../scripts/build-windows-enterprise-installer.ps1#L361-L380) is no longer sufficient because both runs happen inside AVC's isolated environment.

This spec captures the deterministic-build primitives Workstream A depends on. Nothing here is user-facing product behavior; every requirement is aimed at build-time byte-reproducibility.

The AVC-facing contract this workstream serves is [`docs/WINDOWS-AVC-PACKAGING-HANDOFF.md`](../../WINDOWS-AVC-PACKAGING-HANDOFF.md).

## EARS Requirements

### Functional

- **REQ-01:** The system shall build `DefenseClawSetup-Enterprise-x64.exe` using `go build -mod=vendor -trimpath -buildvcs=false -buildid=defenseclaw-enterprise-setup-<source_commit>` so that VCS metadata, absolute build paths, and default `buildid` entropy are eliminated from the binary.
- **REQ-02:** When invoking the outer `go build`, the system shall set `SOURCE_DATE_EPOCH` to the DefenseClaw source-commit UTC timestamp (Unix seconds), so that any wall-clock-derived value inside the toolchain is pinned to the commit rather than the build host.
- **REQ-03:** The system shall emit `manifest.json`, `payload-metadata.json`, and `provenance.json` using a serializer that produces byte-identical output regardless of script host (bash vs. pwsh). Serialization must sort object keys, use LF line endings, use two-space indentation with no trailing whitespace, and terminate the file with a single trailing LF.
- **REQ-04:** The system shall vendor the outer Setup's Go dependencies (`go mod vendor`) so `go build` requires no network access at AVC assembly time.
- **REQ-05:** The system shall pin the Go toolchain to `go1.26.4` via `GOTOOLCHAIN` inside the managed-enterprise assembly scripts (`packaging/scripts/lib/repro-flags.{sh,ps1}`) and the reproducibility CI workflow. `go.mod` shall NOT carry a `toolchain` directive, so OSS builds and contributor tooling retain their existing Go patch-version flexibility while the managed-enterprise assembly path is byte-reproducible.
- **REQ-06:** Where a caller invokes `build-managed-windows-bundle.sh` on macOS/Linux, the system shall write a `manifest.json` whose contents are byte-identical to a `manifest.json` produced by the same inputs under `assemble.ps1` on Windows.
- **REQ-07:** The system shall provide a CI check that runs the assembly step (`assemble.sh` on Linux and macOS agents) against the same signed-payload fixture on two independent runners and shall fail the check when their `DefenseClawSetup-Enterprise-x64.exe` outputs differ by even one byte.
- **REQ-08:** If any of the six AVC-confirmed environment variables (`GOFLAGS="-trimpath -buildvcs=false"`, `SOURCE_DATE_EPOCH`, `GOFLAGS`-derived flags, `GOTOOLCHAIN`, `CGO_ENABLED`, and the `-buildid` pin) are absent or contradicted by ambient env at the `go build` invocation, the system shall refuse to build and shall emit a diagnostic naming the missing variable.

### Non-Functional

- **REQ-09:** The reproducibility CI check (REQ-07) shall complete within 10 minutes on the standard GitHub-hosted Linux and macOS runner sizes so that Workstream A PRs are not slowed by a slow gate.
- **REQ-10:** The system shall not introduce a network dependency in the `go build` step: no `proxy.golang.org`, no GitHub, no private module hosts. Confirmed by unsetting `GOPROXY`/`GOSUMDB` in the CI check.
- **REQ-11:** The system shall not exceed the AVC-agreed build-kit size ceiling (300 MB) after adding vendored trees and reproducibility metadata; CI asserts this on every PR that touches vendored deps.

## Acceptance Criteria

- **AC-01 (REQ-01, REQ-02, REQ-08):** A test asset in `internal/build-repro/testdata/` contains a fixed signed-payload set. Running the assembly on two Linux agents with `SOURCE_DATE_EPOCH` derived from a fixed commit produces `DefenseClawSetup-Enterprise-x64.exe` with identical SHA-256.
- **AC-02 (REQ-01, REQ-08):** With `GOFLAGS`/`SOURCE_DATE_EPOCH`/`-buildid` intentionally unset, the assembly step exits non-zero and stderr names the missing variable(s).
- **AC-03 (REQ-03, REQ-06):** `manifest.json` produced by `assemble.sh` and `assemble.ps1` given the same signed payloads is byte-identical (`diff -q` returns clean).
- **AC-04 (REQ-04, REQ-10):** A CI job that unsets `GOPROXY` and disables outbound network still completes `go build` successfully from the vendored tree.
- **AC-05 (REQ-05):** `packaging/scripts/lib/repro-flags.sh` and `packaging/scripts/lib/repro-flags.ps1` both export `GOTOOLCHAIN=go1.26.4`; the reproducibility CI workflow sets the same value in its job env; `go env GOTOOLCHAIN` inside the assembly step reports `go1.26.4`. `go.mod` carries no `toolchain` directive (confirmed by a lint check).
- **AC-06 (REQ-07, REQ-09):** GitHub Actions workflow `windows-deterministic-build.yml` fans out to `ubuntu-latest` and `macos-latest`, both run `assemble.sh` against the same fixture, and a downstream `compare` job asserts SHA-256 equality; end-to-end wall clock < 10 min on typical scheduling.
- **AC-07 (REQ-11):** A CI assertion fails a PR that grows `windows-enterprise-buildkit-*/` past 300 MB uncompressed.

## Traceability

| REQ | Anchor | Acceptance Criteria |
|-----|--------|---------------------|
| REQ-01 | Parity plan §6.2 E1; [WINDOWS-AVC-PACKAGING-HANDOFF.md §4](../../WINDOWS-AVC-PACKAGING-HANDOFF.md#what-avc-needs-to-confirm) | AC-01, AC-02 |
| REQ-02 | Parity plan §6.2 E1 | AC-01 |
| REQ-03 | Parity plan §6.2 E2 | AC-03 |
| REQ-04 | Parity plan §6.2 E3; AVC handoff §4 | AC-04 |
| REQ-05 | Parity plan §6.2 E3 | AC-05 |
| REQ-06 | Parity plan §6.3 | AC-03 |
| REQ-07 | Parity plan §6.2 E4, §6.3 | AC-06 |
| REQ-08 | AVC handoff §4 | AC-02 |
| REQ-09 | Parity plan §8 sequencing (weeks 1-2) | AC-06 |
| REQ-10 | AVC handoff §4 (offline `go build`) | AC-04 |
| REQ-11 | Parity plan §9 (size risk) | AC-07 |
