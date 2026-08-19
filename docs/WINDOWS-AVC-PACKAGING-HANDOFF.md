# Windows AVC packaging handoff — feasibility check

**Ask.** Can AVC run the three steps below inside the Windows managed_enterprise signing pipeline? Reply yes / no per item.

---

## What DefenseClaw hands you

A single build kit (tarball or zip):

```
windows-enterprise-buildkit-<version>/
├── payload/                          # you sign these five files
│   ├── defenseclaw.exe               # unsigned
│   ├── defenseclaw-gateway.exe       # unsigned
│   ├── defenseclaw-hook.exe          # unsigned
│   ├── install-enterprise.ps1        # unsigned
│   └── DefenseClawEnterprise.psm1    # unsigned
├── source/                           # everything `go build` needs
│   ├── cmd/defenseclaw-enterprise-setup/
│   ├── internal/…                    # trimmed import graph
│   ├── vendor/                       # `go mod vendor`, offline-buildable
│   ├── go.mod
│   └── go.sum
├── assemble.sh                       # or assemble.ps1 — one entry point
├── payload-metadata.json
└── README-AVC.md                     # ~20-line runbook
```

Estimated kit size: **~150–250 MB** (dominated by the vendored Go module cache).

---

## Steps you run

```
# 1. Sign the unsigned inner files:
signtool sign /f <cert> ... payload/*.exe
Set-AuthenticodeSignature -FilePath payload/*.ps1 ...

# 2. Assemble the outer Setup EXE:
./assemble.sh          # or: pwsh -File assemble.ps1

# 3. Sign the outer Setup EXE:
signtool sign /f <cert> ... out/DefenseClawSetup-Enterprise-x64.exe
```

Final release artifact: `DefenseClawSetup-Enterprise-x64.exe` + `.sha256` + `.provenance.json`.

---

## What AVC needs to confirm

Please tick each:

- [ ] **Go toolchain available** in the pipeline (Go 1.24.x, matching the version pinned in `go.mod`). Bundling the toolchain into the build kit is possible if preferred — please indicate.
- [ ] **Offline `go build -mod=vendor` is acceptable** — no network access to `proxy.golang.org` or GitHub required.
- [ ] **PowerShell 7+ or bash available** to run the assemble script. Which do you prefer we ship: `bash` or `pwsh`?
- [ ] **Signing order supported:** sign inner (step 1) → run our assemble script (step 2) → sign outer (step 3).
- [ ] **Build-kit disk footprint (~150–250 MB) fits** artifact-size limits.
- [ ] **Envs preserved during `go build`:** `GOFLAGS="-trimpath -buildvcs=false"` and `SOURCE_DATE_EPOCH` (needed for byte-reproducible outer EXE).

---

## Response we need

1. Yes / no per checkbox above.
2. Preferred script host: `bash` or `pwsh`.
3. Any constraint we missed.
