# Copyright 2026 Cisco Systems, Inc. and its affiliates
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Wrapper around scripts/build-windows-managed-bundle.ps1 for the
    Cisco-managed Windows release. Fetches the private cloudreg overlay +
    CMID module from github.com/cisco-aispg/ai-common (default: latest
    develop), computes the Go pseudo-version for the exact ref you're
    building against, and invokes the inner bundle script with
    -CmidOverlay + -CmidVersion set.

.DESCRIPTION
    Windows analog of scripts/build-managed-bundle.sh. The macOS wrapper
    invokes `make packaging-macos-bundle`; here we invoke the inner
    PowerShell script directly because the whole downstream chain
    (build-windows-installer.ps1, Authenticode signing, windowsresources
    stamping) is Windows-native.

    Prereqs (fail-fast checked before we start):
      - Windows amd64 host with the Go toolchain (Go >= go.mod pinned).
      - GOPRIVATE=github.com/cisco-aispg/* (or equivalent) so `go get`
        can resolve the pinned pseudo-version at build time.
      - Read access to git@github.com-aispg:cisco-aispg/ai-common.git
        (SSH host alias) OR https://github.com/cisco-aispg/ai-common.git
        with a token in %HOMEPATH%\_netrc / $env:GH_TOKEN.

.PARAMETER Ref
    Git ref (branch, tag, or commit sha) in cisco-aispg/ai-common to
    build against. Default: develop.

.PARAMETER AiCommonDir
    Path to an existing ai-common checkout. When set, the script skips
    the clone and reuses this directory.

.PARAMETER Keep
    Keep the ai-common temporary checkout after the build. Ignored when
    -AiCommonDir is set.

.PARAMETER Version
    Release version string, e.g. 0.9.0 or 0.9.0-rc1. Forwarded to the
    inner bundle script.

.PARAMETER DistRoot
    Directory containing the Python wheel and upgrade-manifest.json.
    Forwarded to the inner bundle script (which writes the gateway zip
    here).

.PARAMETER OutRoot
    Directory where the built DefenseClawSetup-x64.exe will be written.

.PARAMETER StateRoot
    Scratch directory for the build.

.PARAMETER AiCommonRepoSsh
    Override the default SSH remote for ai-common.

.PARAMETER AiCommonRepoHttps
    Override the default HTTPS remote for ai-common (used on SSH failure).
#>

[CmdletBinding()]
param(
    [string]$Ref = 'develop',
    [string]$AiCommonDir = '',
    [switch]$Keep,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$DistRoot,
    [Parameter(Mandatory = $true)][string]$OutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$AiCommonRepoSsh = 'git@github.com-aispg:cisco-aispg/ai-common.git',
    [string]$AiCommonRepoHttps = 'https://github.com/cisco-aispg/ai-common.git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $IsWindows) {
    throw "build-managed-windows-installer.ps1 must run on Windows (mirrors build-managed-bundle.sh, which is macOS-only)."
}

foreach ($tool in @('git', 'go', 'pwsh')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "build-managed-windows-installer: missing required tool on PATH: $tool"
    }
}

if (-not $env:GOPRIVATE) {
    $env:GOPRIVATE = 'github.com/cisco-aispg/*'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$innerScript = Join-Path $PSScriptRoot 'build-windows-managed-bundle.ps1'
if (-not (Test-Path -LiteralPath $innerScript -PathType Leaf)) {
    throw "build-managed-windows-installer: inner bundle script missing: $innerScript"
}

# --- ai-common checkout ------------------------------------------------

function Invoke-Git {
    param([string[]]$Arguments, [string]$WorkingDirectory = (Get-Location).Path, [switch]$IgnoreExit)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($a in $Arguments) { [void]$start.ArgumentList.Add($a) }
    $p = [Diagnostics.Process]::Start($start)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0 -and -not $IgnoreExit) {
        throw "git $($Arguments -join ' ') failed (exit $($p.ExitCode)): $($err.Trim())"
    }
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut = $out.TrimEnd()
        StdErr = $err.TrimEnd()
    }
}

function Try-CloneAiCommon {
    param([string]$Url, [string]$Target, [string]$Ref)
    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force
    }
    [IO.Directory]::CreateDirectory($Target) | Out-Null
    # `git clone --branch` only accepts branch/tag refs. Clone without --branch
    # and explicitly fetch + detach-checkout the ref so commit-sha refs also work.
    $r = Invoke-Git @('clone', '--quiet', '--depth', '50', '--no-checkout', $Url, $Target) -IgnoreExit
    if ($r.ExitCode -ne 0) { return $false }
    $r = Invoke-Git @('-C', $Target, 'fetch', '--quiet', '--depth', '50', 'origin', $Ref) -IgnoreExit
    if ($r.ExitCode -ne 0) { return $false }
    $r = Invoke-Git @('-C', $Target, 'checkout', '--quiet', '--detach', 'FETCH_HEAD') -IgnoreExit
    if ($r.ExitCode -ne 0) { return $false }
    return $true
}

$cleanupAiCommon = $false
$resolvedAiCommon = $AiCommonDir
if (-not $resolvedAiCommon) {
    $resolvedAiCommon = Join-Path ([IO.Path]::GetTempPath()) ("ai-common-cmid-" + [Guid]::NewGuid().ToString("N"))
    $cleanupAiCommon = $true
    Write-Host "==> cloning cisco-aispg/ai-common ($Ref) into $resolvedAiCommon"
    if (-not (Try-CloneAiCommon -Url $AiCommonRepoSsh -Target $resolvedAiCommon -Ref $Ref)) {
        Write-Host "    ssh clone failed, falling back to https"
        if (-not (Try-CloneAiCommon -Url $AiCommonRepoHttps -Target $resolvedAiCommon -Ref $Ref)) {
            throw "build-managed-windows-installer: unable to clone $AiCommonRepoSsh or $AiCommonRepoHttps @ $Ref"
        }
    }
} else {
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedAiCommon '.git'))) {
        throw "build-managed-windows-installer: -AiCommonDir must point at a git checkout: $resolvedAiCommon"
    }
    Write-Host "==> using existing ai-common checkout at $resolvedAiCommon"
    (Invoke-Git @('-C', $resolvedAiCommon, 'fetch', '--quiet', 'origin', $Ref)) | Out-Null
    (Invoke-Git @('-C', $resolvedAiCommon, 'checkout', '--quiet', $Ref)) | Out-Null
}

try {
    # --- validate overlay ----------------------------------------------

    $overlayPath = Join-Path $resolvedAiCommon 'defenseclaw_cmid_overlay\provider_cisco.go'
    if (-not (Test-Path -LiteralPath $overlayPath -PathType Leaf)) {
        throw "build-managed-windows-installer: overlay file not found in ai-common@${Ref}: $overlayPath (has the cmid PR been merged into $Ref?)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedAiCommon 'cmid\go.mod') -PathType Leaf)) {
        throw "build-managed-windows-installer: cmid module not found in ai-common@${Ref}: $(Join-Path $resolvedAiCommon 'cmid\go.mod')"
    }

    # --- compute Go pseudo-version -------------------------------------
    # HEAD-based (not path-filtered) because the shallow clone might not
    # retain a cmid/ ancestor; HEAD is exactly the ref the caller asked
    # to build. Mirrors build-managed-bundle.sh:158-176.

    Write-Host "==> computing pseudo-version for ai-common/cmid @ $Ref"
    $commitSha = (Invoke-Git @('-C', $resolvedAiCommon, 'rev-parse', 'HEAD')).StdOut
    if (-not $commitSha) {
        throw "build-managed-windows-installer: could not resolve HEAD commit sha on $Ref"
    }
    $commitShort = $commitSha.Substring(0, 12)
    # UTC timestamp in Go's pseudo-version format YYYYMMDDhhmmss.
    $env:TZ = 'UTC'
    try {
        $commitTs = (Invoke-Git @('-C', $resolvedAiCommon, 'show', '-s', '--format=%cd', '--date=format-local:%Y%m%d%H%M%S', $commitSha)).StdOut
    } finally {
        Remove-Item Env:TZ -ErrorAction SilentlyContinue
    }
    if ($commitTs -notmatch '^\d{14}$') {
        throw "build-managed-windows-installer: unexpected commit timestamp format: $commitTs"
    }
    $cmidVersion = "v0.0.0-$commitTs-$commitShort"

    Write-Host "    cmid commit: $commitSha"
    Write-Host "    pseudo-ver:  $cmidVersion"

    # --- drive the inner bundle script ---------------------------------

    Write-Host "==> building managed Windows bundle"
    Write-Host "    CmidOverlay=$overlayPath"
    Write-Host "    CmidVersion=$cmidVersion"

    & $innerScript `
        -Version $Version `
        -DistRoot $DistRoot `
        -OutRoot $OutRoot `
        -StateRoot $StateRoot `
        -CmidOverlay $overlayPath `
        -CmidVersion $cmidVersion `
        -Tags 'cmid'
    if ($LASTEXITCODE -ne 0) {
        throw "build-windows-managed-bundle.ps1 failed with exit code $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host "==> managed Windows installer build complete"
}
finally {
    if ($cleanupAiCommon -and (-not $Keep) -and (Test-Path -LiteralPath $resolvedAiCommon)) {
        Write-Host "==> removing temporary ai-common checkout"
        Remove-Item -LiteralPath $resolvedAiCommon -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($Keep) {
        Write-Host "==> keeping ai-common checkout at $resolvedAiCommon"
    }
}
