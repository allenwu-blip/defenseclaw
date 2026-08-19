# Design: Windows deterministic-build support for AVC

**Workstream:** E — prereq for Workstream A.
**Base branch:** `windows-enterprise-integration`.

## Summary

Build-time-only primitives that make the outer `DefenseClawSetup-Enterprise-x64.exe` byte-reproducible when its assembly step runs inside AVC's signing pipeline. No runtime behavior changes. No new binaries in the release. **No `go.mod` change** — the Go toolchain pin lives out-of-band in `GOTOOLCHAIN` inside the managed-enterprise assembly scripts and CI, so OSS builds and contributor tooling are unaffected. The deliverable is a small Go helper (`cmd/windows-repro-manifest`), a locked-down assembly-flag policy, that out-of-band `GOTOOLCHAIN` pin, and a CI fan-out that catches drift on every Workstream-A PR.

## Architecture

### Components

| Component | Location | Role |
|---|---|---|
| Reproducible JSON serializer | `cmd/windows-repro-manifest/` (new) | Emits `manifest.json`, `payload-metadata.json`, and `provenance.json` with sorted keys, LF endings, fixed indentation. Called by `assemble.sh` and `assemble.ps1`. |
| Reproducible build flag helper | `packaging/scripts/lib/repro-flags.sh` and `.ps1` (new) | Central place that emits the exact `go build` args + envs. Both `assemble.sh` and `assemble.ps1` source it so the flag list has one definition. |
| `GOTOOLCHAIN` pin (out-of-band, not in `go.mod`) | `packaging/scripts/lib/repro-flags.{sh,ps1}` + `.github/workflows/windows-deterministic-build.yml` env | Exports `GOTOOLCHAIN=go1.26.4` at the assembly boundary only. OSS builds and contributor `go` invocations are unaffected; the managed-enterprise assembly path is byte-reproducible against the pinned toolchain. |
| Vendored tree | `vendor/` (existing repo-wide vendor) + build-kit trim | Offline `go build -mod=vendor` at AVC. |
| CI reproducibility gate | `.github/workflows/windows-deterministic-build.yml` (new) | Fans out to `ubuntu-latest` and `macos-latest`, runs `assemble.sh` against a fixed signed-payload fixture, compares SHA-256. |
| Preflight env check | Inside `assemble.sh`/`.ps1` | Refuses to run if any of the six required envs is absent or has an unexpected value. |

### Data flow (build time)

```
build-managed-windows-bundle.sh (macOS/Linux, DefenseClaw side)
  └─ emits build kit → hand off to AVC
      └─ AVC signs payload/*.{exe,ps1,psm1}
          └─ assemble.sh (or assemble.ps1) inside AVC pipeline:
              1. source packaging/scripts/lib/repro-flags.sh
              2. preflight envs (fail-fast if missing)
              3. cmd/windows-repro-manifest ⇒ manifest.json  (byte-stable)
              4. cmd/windows-repro-manifest ⇒ payload-metadata.json
              5. go build -mod=vendor -trimpath -buildvcs=false \
                          -buildid=defenseclaw-enterprise-setup-<sha>
                          ./cmd/defenseclaw-enterprise-setup
              6. cmd/windows-repro-manifest ⇒ provenance.json  (setup_sha256 filled)
```

The `--source-commit` argument threads through all three JSON emissions plus the `-buildid` value, so every artifact carries the same commit identifier.

### Interfaces

**`cmd/windows-repro-manifest` — Go binary, CLI-only, no network.**

```
windows-repro-manifest emit-manifest \
    --schema-version 1 \
    --version <semver> \
    --source-commit <sha> \
    --distribution-flavor managed-enterprise \
    --payload-dir <path> \
    --out <path/manifest.json>

windows-repro-manifest emit-payload-metadata \
    --version <semver> \
    --source-commit <sha> \
    --cmid-pseudo-version <v> \
    --expected-filenames defenseclaw.exe,defenseclaw-gateway.exe,... \
    --out <path/payload-metadata.json>

windows-repro-manifest emit-provenance \
    --version <semver> \
    --source-commit <sha> \
    --setup-exe <path/DefenseClawSetup-Enterprise-x64.exe> \
    --out <path/provenance.json>
```

Every subcommand:
- Hashes files with SHA-256.
- Serializes JSON via `encoding/json` with `SetEscapeHTML(false)`, then manually re-encodes with sorted keys via a small `sortedMarshal` helper (Go's `json.Marshal` sorts map keys but not struct fields — using an `orderedFields[]` slice ensures stable field order).
- Writes with LF line endings, two-space indent (`  `), final trailing LF.
- Emits exit-code 0 on success and non-zero on any I/O/parse error.

**`packaging/scripts/lib/repro-flags.sh` (bash) / `.ps1` (PowerShell)**

Single source of truth for the six AVC-confirmed envs. Both scripts export:

```
GOFLAGS="-trimpath -buildvcs=false -mod=vendor"
GOTOOLCHAIN=go1.26.4        # matches go.mod
CGO_ENABLED=0
GOOS=windows
GOARCH=amd64
SOURCE_DATE_EPOCH=<commit UTC seconds, integer>
DEFENSECLAW_BUILDID=defenseclaw-enterprise-setup-<source_commit>
```

The scripts export a shell function `defenseclaw_repro_build` that invokes `go build` with the right args using `$DEFENSECLAW_BUILDID` as `-buildid`, so `assemble.sh`/`.ps1` don't repeat the flag list.

**Preflight env check.** Both `assemble.sh` and `assemble.ps1` run a `defenseclaw_repro_preflight` shell function that asserts each of the six envs is set to a non-empty, well-formed value. Missing or malformed exits non-zero with a message like `assemble: SOURCE_DATE_EPOCH must be a positive integer (got: '')`.

### CI workflow

```
.github/workflows/windows-deterministic-build.yml
├── jobs.build-linux    (ubuntu-latest)  → runs assemble.sh → uploads artifact + sha256
├── jobs.build-macos    (macos-latest)   → runs assemble.sh → uploads artifact + sha256
└── jobs.compare         needs: [build-linux, build-macos]
                         → downloads both sha256 files → diff → fails on mismatch
```

The fixture is a small tarball checked into `internal/build-repro/testdata/signed-payload-fixture.tar.zst` (LFS candidate) containing dummy-signed inner files with a fixed SDDL DACL. AC-01 depends on this fixture staying stable across runs.

## Data Model

No database changes. Two JSON schemas — all fields sorted, ASCII only, no wall-clock timestamps:

**`manifest.json` (v1)**

```json
{
  "distribution_flavor": "managed-enterprise",
  "files": [
    {"name": "DefenseClawEnterprise.psm1", "sha256": "…", "size": 12345},
    {"name": "defenseclaw-gateway.exe",    "sha256": "…", "size": 45678},
    {"name": "defenseclaw-hook.exe",       "sha256": "…", "size": 34567},
    {"name": "defenseclaw.exe",            "sha256": "…", "size": 56789},
    {"name": "install-enterprise.ps1",     "sha256": "…", "size": 23456}
  ],
  "schema_version": 1,
  "source_commit": "…",
  "version": "…"
}
```

**`payload-metadata.json`** — mirrors `manifest.json` but adds `cmid_pseudo_version` for the CMID overlay pin.

**`provenance.json`** — adds `setup_sha256` after the outer `go build` completes.

## Integration Points

- **Workstream A** consumes everything here: `assemble.sh` sources `repro-flags.sh` and invokes `windows-repro-manifest`.
- **Existing `scripts/build-windows-enterprise-installer.ps1`** (retired by Workstream A5) is out of scope for E — its on-host self-check disappears when A5 lands.
- **`go.mod`** is deliberately untouched. OSS builds, `go mod tidy`, `go get`, contributor tooling — none change. A lint check in `make lint` refuses a `toolchain` directive in `go.mod` so the managed-enterprise pin cannot silently leak in later. The reproducibility invariant is enforced entirely by the CI workflow and the two library scripts.
- **`packaging/scripts/build-managed-windows-bundle.sh`** (Workstream A1) will call `defenseclaw_repro_build` when emitting the build kit's `payload-metadata.json`.

## Tradeoffs

- **Go helper vs. `jq`.** `jq` is available on macOS/Linux but not on stock Windows; shipping a small Go binary keeps the toolchain-side one-language and avoids a bash/pwsh serializer split. Rejected: a shell-only serializer using `printf` (fragile with escaping).
- **Toolchain pin location.** Pinned via `GOTOOLCHAIN=go1.26.4` in the two library scripts and the reproducibility CI workflow — deliberately NOT in `go.mod`. Reasoning: a `go.mod toolchain` directive would force every OSS build, contributor `go mod tidy`, and non-managed CI job in this repo to download go1.26.4, without giving OSS anything in return. The AVC reproducibility contract is a managed-enterprise-only invariant, so it lives on that path only. Rejected: `go.mod toolchain go1.26.4`. Accepted risk: OSS and managed-enterprise builds may drift on Go patch version — acceptable because they produce different artifacts anyway and only the AVC path has the reproducibility contract.
- **`CGO_ENABLED=0` pinned.** The current outer Setup doesn't use cgo. Pinning to 0 removes host-C-toolchain variance. If a future dep pulls in cgo, we'll revisit — for now, byte-stability wins.
- **LFS-vs-inline fixture.** A ~1-2 MB fixture tarball fits inline in the repo. LFS is an option if the fixture grows; keep inline until it hurts.

## Risks

| Risk | Mitigation |
|---|---|
| Go stdlib's `-buildid` may still embed a synthesized value if we pass an empty string | Explicit non-empty `-buildid=defenseclaw-enterprise-setup-<sha>` per REQ-01. |
| `go mod vendor` output differs across Go patch versions | `GOTOOLCHAIN=go1.26.4` exported in `repro-flags.{sh,ps1}` and the CI workflow (REQ-05, AC-05). Because this pin is out-of-band (not in `go.mod`), the reproducibility CI is the enforcement point; a lint check asserts `go.mod` has no `toolchain` directive so the pin doesn't silently leak into OSS. |
| Someone edits `packaging/scripts/lib/repro-flags.sh` and `.ps1` out of sync | Add a lint check in the reproducibility workflow that greps the two files for the same env-var list and fails on divergence. |
| The reproducibility CI job flakes on shared-runner hardware | Both jobs use `-race off` and `CGO_ENABLED=0`, and `--fail-if-mismatch` compares SHA-256 not wall-clock — determinism is the only success signal. |
| AVC's pipeline injects an ambient env that overrides our `GOFLAGS` | Preflight (REQ-08, AC-02) reads the *effective* `GOFLAGS` at the moment of invocation and refuses to proceed if a required flag is missing. |
