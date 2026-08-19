# Plan: Windows deterministic-build support for AVC

**Workstream:** E.
**Target branch:** `windows-enterprise-integration`.
**Est. size:** S (~3-5 days of engineering per parity plan §1).

## Scope

### In scope

- New Go binary `cmd/windows-repro-manifest` for byte-stable JSON emission (`manifest.json`, `payload-metadata.json`, `provenance.json`).
- New library scripts `packaging/scripts/lib/repro-flags.sh` and `.ps1` — single source of truth for the six reproducibility envs and the `go build` invocation.
- `GOTOOLCHAIN=go1.26.4` exported inside `packaging/scripts/lib/repro-flags.{sh,ps1}` and the reproducibility CI workflow (out-of-band pin — see `design.md § Tradeoffs`).
- Lint check that `go.mod` has no `toolchain` directive, so the pin can't silently leak into OSS.
- New CI workflow `.github/workflows/windows-deterministic-build.yml` that fans out to Linux + macOS, runs the assembly against a fixed signed-payload fixture, and fails the PR on SHA-256 mismatch.
- Fixture `internal/build-repro/testdata/signed-payload-fixture.tar.zst` (dummy-signed inner files) plus a small README explaining how to regenerate.
- Unit tests for the Go helper (JSON byte-stability, hash correctness, argument parsing).
- Documentation update to [`WINDOWS-AVC-PACKAGING-HANDOFF.md`](../../WINDOWS-AVC-PACKAGING-HANDOFF.md): correct the `Go 1.24.x` reference in §4 to `Go 1.26.4` and point at this spec as the deterministic-build contract.

### Out of scope

- The `assemble.sh` / `assemble.ps1` scripts themselves — those live in Workstream A2 and consume this workstream's primitives.
- The `build-managed-windows-bundle.sh` extensions — Workstream A1.
- Retiring `scripts/build-windows-enterprise-installer.ps1` — Workstream A5.
- Runtime behavior changes — this is a build-time-only workstream.
- LFS migration for the fixture — inline until size becomes a problem.
- **Any change to `go.mod`.** OSS builds, contributor tooling (`go mod tidy`, `go get`), and non-managed CI jobs all stay on today's `go 1.26.4` minimum with free patch-version drift. The reproducibility pin is a managed-enterprise-only invariant enforced via `GOTOOLCHAIN` at the assembly boundary; a lint check keeps `go.mod` clean of a `toolchain` directive.

## Dependencies

### Internal

- None. This is the first prereq workstream from the parity plan.

### External

- Go toolchain 1.26.4 available on `ubuntu-latest` and `macos-latest` GitHub runners.
- `zstd` on both runners (for the fixture tarball).
- No network access required at `go build` time (REQ-10).

## Rollout Plan

1. Land the Go helper, library scripts (with `GOTOOLCHAIN=go1.26.4` exported inside them), the `go.mod`-no-toolchain lint, and the fixture in one PR against `windows-enterprise-integration`. `go.mod` itself is unchanged. Nothing is called by production paths yet — safe to merge behind the workstream-A work.
2. Land the reproducibility CI workflow in the same PR so we exercise the new primitives immediately.
3. Workstream-A merge (a later PR) wires `assemble.sh` / `assemble.ps1` to consume the primitives.
4. Retirement of the on-host self-check in `scripts/build-windows-enterprise-installer.ps1` is deferred to Workstream A5.

No feature flag needed — every artifact here is inert until Workstream A calls it. No backward-compatibility surface either.

## Observability Plan

Build-time only. No runtime logs / metrics / traces.

- **CI signal:** The `compare` job in `windows-deterministic-build.yml` prints the two SHA-256 values side by side on mismatch, plus a `diffoscope` (if available) or `xxd | head` of the first divergence for triage.
- **Local signal:** `windows-repro-manifest` and the library scripts emit diagnostic lines on stderr when preflight fails, naming the missing env var explicitly.
- **Fixture-refresh visibility:** the fixture tarball's regeneration script prints the resulting SHA-256 to stdout so a future refresh PR can trivially update the expected value.

## Security Plan

- **Auth/Authz:** N/A (build-time helper, no service boundary).
- **Data handling:** The reproducibility fixture MUST NOT contain real signed binaries or real Authenticode certs — dummy-signed only (self-signed dev cert with disposable key). Add a lint check that the fixture's signer common-name is not `Cisco Systems, Inc.` so real signed material can never be checked in by accident.
- **Multi-tenancy:** N/A.
- **Supply-chain:** The Go helper has no third-party dependencies beyond the stdlib. Enforced by a package-level test that runs `go list -deps -f '{{.Module}}' ./cmd/windows-repro-manifest/...` and asserts every non-stdlib module resolves to `github.com/defenseclaw/defenseclaw` or the stdlib.
- **AVC handoff surface:** The build kit that Workstream A ships to AVC will consume this workstream's primitives; the deterministic-build gate protects against a mid-pipeline swap silently producing different bytes.
