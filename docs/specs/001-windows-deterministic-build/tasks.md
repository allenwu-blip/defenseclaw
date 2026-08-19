# Tasks: Windows deterministic-build support for AVC

**Workstream:** E.
**Target branch:** `windows-enterprise-integration`.

## Tasks

Order matters — each task is a mergeable slice, and later tasks depend on earlier ones. The whole workstream should still land in a single PR unless the CI-workflow slice needs to sequence separately because of runner setup.

1. **[ ] Pin the Go toolchain out-of-band, not in `go.mod` (REQ-05).**
   Export `GOTOOLCHAIN=go1.26.4` in `packaging/scripts/lib/repro-flags.sh` and `.ps1` (folded into Tasks 8 and 9), and set the same env in the reproducibility CI workflow (Task 12). Add a lint check to `make lint` or a small `scripts/check-go-mod-no-toolchain.sh` that fails if `go.mod` acquires a `toolchain` directive, so the pin cannot silently leak into OSS builds. Rationale is in `design.md § Tradeoffs` and `plan.md § Scope`.

2. **[ ] Skeleton for `cmd/windows-repro-manifest/` (REQ-03).**
   Create `main.go` with the three subcommand shells (`emit-manifest`, `emit-payload-metadata`, `emit-provenance`) using `flag` package for argument parsing. Return non-zero on unrecognized subcommand or missing required flag.

3. **[ ] Byte-stable JSON serializer (REQ-03, REQ-06).**
   Implement `sortedMarshal` helper: builds an `orderedField` slice per struct, marshals via `encoding/json` with `SetEscapeHTML(false)`, then walks and re-emits with sorted keys, LF endings, two-space indent, and trailing LF. Unit-test with a table of nested structs to lock the byte layout.

4. **[ ] Implement `emit-manifest` subcommand (REQ-03).**
   Read every file under `--payload-dir`, compute SHA-256, populate the `manifest.json` shape defined in `design.md § Data Model`, write via `sortedMarshal`. Unit-test with an in-repo fixture of three files.

5. **[ ] Implement `emit-payload-metadata` subcommand (REQ-03).**
   Same pattern; includes `cmid_pseudo_version` and the expected filename list.

6. **[ ] Implement `emit-provenance` subcommand (REQ-03).**
   Reads the built Setup EXE, computes SHA-256, produces `provenance.json`.

7. **[ ] Supply-chain guard test (Plan §Security).**
   Test at `cmd/windows-repro-manifest/deps_test.go` that asserts every non-stdlib dep resolves to `github.com/defenseclaw/defenseclaw` or the stdlib.

8. **[ ] Library script `packaging/scripts/lib/repro-flags.sh` (REQ-01, REQ-02, REQ-04, REQ-08).**
   Exports the six envs and defines `defenseclaw_repro_preflight` + `defenseclaw_repro_build`. Include a comment header naming this spec.

9. **[ ] Library script `packaging/scripts/lib/repro-flags.ps1` (REQ-01, REQ-02, REQ-04, REQ-08).**
   PowerShell mirror of task 8. Same env names, same function names, semantically equivalent.

10. **[ ] Cross-script parity lint (Design § Risks).**
    Small script (`scripts/check-repro-flags-parity.sh`) that greps the two files for the exported env-var list and fails on divergence. Wire into `make lint`.

11. **[ ] Reproducibility fixture (REQ-07).**
    Create `internal/build-repro/testdata/signed-payload-fixture.tar.zst` — dummy-signed five-file inner set. Add `internal/build-repro/testdata/README.md` explaining regeneration. Fixture signer common-name MUST NOT be `Cisco Systems, Inc.` (lint check).

12. **[ ] CI workflow `.github/workflows/windows-deterministic-build.yml` (REQ-07, REQ-09).**
    Three jobs: `build-linux` (ubuntu-latest), `build-macos` (macos-latest), `compare`. Both build jobs unset `GOPROXY` to enforce offline (REQ-10). `compare` fails on SHA-256 mismatch with a side-by-side diagnostic.

13. **[ ] Build-kit size guard (REQ-11, AC-07).**
    Add a small `make windows-buildkit-size` target that computes the uncompressed size of `windows-enterprise-buildkit-*/` and fails at 300 MB. Wire into the CI workflow.

14. **[ ] Update `docs/WINDOWS-AVC-PACKAGING-HANDOFF.md` §4.**
    Correct the stale `Go 1.24.x` reference to `Go 1.26.4`. Add a line pointing at this spec as the deterministic-build contract.

15. **[ ] Spec/context updates (always last).**
    Mark this spec's status `Ready for implementation → Implementing → Merged` as it moves through the PR. Add a pointer row to a top-level index if one exists at merge time.

## Test Plan

### Unit Tests

- `cmd/windows-repro-manifest/`: byte-stability of `sortedMarshal` across a table of nested structs; SHA-256 correctness against a golden file; missing-flag error messages match a stable format so integration tests can grep them.
- `cmd/windows-repro-manifest/deps_test.go`: stdlib-only supply-chain guard.

### Integration Tests

- CI workflow (task 12) is itself the integration test: two-agent reproducibility gate against the shared fixture. Failure produces a diff-friendly diagnostic (`xxd | head`, and if `diffoscope` is available on the runner, its output).
- Manual smoke on a developer macOS host: run `assemble.sh` against the fixture twice, assert output is byte-identical.

### Performance Tests

- Not applicable. The reproducibility gate has a wall-clock budget (REQ-09) enforced by the CI workflow's `timeout-minutes: 10`, so a slowdown surfaces as a red build rather than as a separate perf test.

## Traceability rollup

| Task | Requirements |
|---|---|
| 1 | REQ-05 |
| 2, 3, 4, 5, 6 | REQ-03 |
| 6 (setup_sha256) | REQ-01, REQ-02 |
| 7 | Plan §Security (supply-chain) |
| 8, 9 | REQ-01, REQ-02, REQ-04, REQ-08 |
| 10 | Design §Risks (script parity) |
| 11 | REQ-07 (fixture); Plan §Security (dummy-signed only) |
| 12 | REQ-07, REQ-09, REQ-10 |
| 13 | REQ-11 |
| 14 | REQ-01, REQ-05 (doc alignment) |
| 15 | Meta |
