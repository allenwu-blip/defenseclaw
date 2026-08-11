# Windows machine installer interface

This is the contract a deployment system programs against when it drives the
machine-level DefenseClaw deployment from `defenseclaw.exe`. The certification
runbook in `WINDOWS-ENTERPRISE-CERTIFICATION.md` covers what a correct
deployment looks like; this document covers how to call it.

## Commands

Every machine-level action is a subcommand of `defenseclaw.exe enterprise
windows`, and every one of them requires an elevated caller except `status`.

| Command | Purpose |
| --- | --- |
| `install` | Create the protected tree, register both services, and start them. |
| `upgrade` | Replace artifacts and re-register in one transaction. |
| `repair` | Reapply ACL, service, environment, and recovery invariants. |
| `reconcile` | Restart the guardian and wait for a fresh reconcile pass. |
| `verify` | Check files, DACLs, service policy, mode pin, and readiness. |
| `status` | Report SCM process state separately from application readiness. |
| `uninstall` | Remove services and binaries, keeping managed state unless `--purge`. |

Add `--json` to any of them for machine-readable output.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The requested action completed. |
| 1603 | The requested action failed. The deployment is unchanged or rolled back, and the failure text on stderr names the cause. |

1603 is the standard fatal-install result, so a deployment system that already
understands MSI results needs no translation layer.

Two codes are deliberately absent. 3010 never appears, because it means
installed and awaiting a reboot, and no failure here has earned that reading;
if a future action does require a reboot it will be added as an explicit
success code. 1602 never appears, because these commands are non-interactive
and nothing can be cancelled.

## The executable carries its own scripts

The lifecycle is implemented in PowerShell, and a Windows `defenseclaw.exe`
carries both script files inside the binary. A release can therefore ship the
single executable: it stages the scripts into a directory only SYSTEM and
Administrators can write, runs them, and removes them afterwards.

Resolution order for the entry script:

1. The `--installer` flag.
2. The `DEFENSECLAW_WINDOWS_ENTERPRISE_INSTALLER` environment variable.
3. `install-enterprise.ps1` in the `libexec` directory beside the executable,
   which is what an installed tree uses.
4. The embedded copy.

An installer named by the flag or the variable is used exactly as given. If it
is missing or fails the trust check, the command fails rather than quietly
falling back to the embedded copy.

## Requirements

Windows PowerShell 5.1 at its fixed System32 location runs the scripts. The
executable does not use PowerShell 7 and does not read the caller's
environment, profile, or working directory.

## Managed-enterprise build

The public OSS setup.exe is built by `scripts/build-windows-installer.ps1
-DistributionFlavor oss`. A managed-enterprise setup.exe additionally links the
private CMID provider so the gateway can authenticate to AI Defense; that
requires a `-tags cmid` gateway with the private cloudreg overlay swapped into
`internal/managed/cloudreg/provider_cisco.go` and the
`github.com/cisco-aispg/ai-common/cmid` module pinned to a specific
pseudo-version.

Two scripts wrap that:

- `scripts/build-managed-windows-installer.ps1` — outer orchestrator. Clones
  `cisco-aispg/ai-common` at `-Ref` (default `develop`), computes the Go
  pseudo-version of that ref, and invokes the inner script with `-CmidOverlay`
  and `-CmidVersion` set. Mirrors `scripts/build-managed-bundle.sh` for macOS.

- `scripts/build-windows-managed-bundle.ps1` — inner build script. Snapshots
  `provider_cisco.go` + `go.mod` + `go.sum`, applies the overlay, runs
  `go get` to pin the module, cross-builds `defenseclaw.exe` and
  `defenseclaw-hook.exe` with `-tags cmid`, packages them into the goreleaser-
  shaped gateway zip, then drives `build-windows-installer.ps1
  -DistributionFlavor managed-enterprise`. The snapshot is restored on exit
  whether the build succeeded or failed. Mirrors `scripts/build-macos-bundle.sh`
  for macOS.

The Makefile target `packaging-windows-managed-bundle` wraps the inner script
when `CMID_OVERLAY` + `CMID_VERSION` are already known (parallels
`packaging-macos-bundle`). Otherwise call
`scripts/build-managed-windows-installer.ps1` directly:

```powershell
pwsh -File .\scripts\build-managed-windows-installer.ps1 `
    -Ref develop -Version 0.9.0-rc1 `
    -DistRoot .\dist -OutRoot .\dist\windows-installer `
    -StateRoot .\dist\windows-installer-state
```

`-DistRoot` must already contain `defenseclaw-<version>-py3-none-any.whl` and
`upgrade-manifest.json` (typically staged by the release candidate pipeline);
the script writes / overwrites `defenseclaw_<version>_windows_amd64.zip` in
the same directory before driving the installer build.

The resulting `DefenseClawSetup-x64.exe.provenance.json` reports
`distribution_flavor: "managed-enterprise"`; `cmd/defenseclaw-setup` accepts
both `oss` and `managed-enterprise` payload flavors and rejects any other value.
