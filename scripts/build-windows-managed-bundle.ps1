# Copyright 2026 Cisco Systems, Inc. and its affiliates
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Windows-side consumer of a pre-staged managed-enterprise gateway zip.

.DESCRIPTION
    packaging/scripts/build-managed-windows-bundle.sh runs on macOS (or any host with a
    Go toolchain and SSH access to cisco-aispg/ai-common) and produces:

        <DistRoot>/defenseclaw_<Version>_windows_amd64.zip
        <DistRoot>/gateway-source-commit.txt

    This script is the Windows-side counterpart. Given a -DistRoot that
    already contains the gateway zip above plus the release-candidate wheel
    and upgrade-manifest.json, it:

        1. Verifies the gateway zip is present and contains the two exe's.
        2. Reads gateway-source-commit.txt and refuses to proceed unless the
           defenseclaw working tree is checked out at that commit — the
           installer bakes the local git HEAD into the payload manifest and
           the provenance JSON, so a commit mismatch would misreport where
           the gateway was built from.
        3. Invokes scripts/build-windows-installer.ps1 with
           -DistributionFlavor managed-enterprise.

    Everything CMID-specific (private overlay, -tags cmid build, resource
    stamping) already happened on the macOS side; this script does not need
    SSH access to the private repo and does not swap anything in the working
    tree.

.PARAMETER Version
    Release version string, must match the version used to build the gateway
    zip (which the script cross-checks by expected file name).

.PARAMETER DistRoot
    Directory containing the pre-staged gateway zip, wheel, upgrade-manifest,
    and gateway-source-commit.txt.

.PARAMETER OutRoot
    Directory where DefenseClawSetup-x64.exe and its sidecars will land.

.PARAMETER StateRoot
    Scratch directory for build-windows-installer.ps1.

.PARAMETER SkipCommitCheck
    Bypass the gateway-source-commit.txt cross-check. Only for local dev when
    you know what you are doing (the installer will still record the local
    HEAD as source_commit; the resulting artifact should not be treated as
    a reproducible release).

.PARAMETER SkipSigning
    Forwarded to build-windows-installer.ps1. Skips Authenticode signing.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$DistRoot,
    [Parameter(Mandatory = $true)][string]$OutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [switch]$SkipCommitCheck,
    [switch]$SkipSigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $IsWindows) {
    throw "build-windows-managed-bundle.ps1 must run on Windows (drives build-windows-installer.ps1)."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$distFull = [IO.Path]::GetFullPath($DistRoot)
$outFull = [IO.Path]::GetFullPath($OutRoot)
$stateFull = [IO.Path]::GetFullPath($StateRoot)
$buildInstaller = Join-Path $PSScriptRoot 'build-windows-installer.ps1'

foreach ($required in @($buildInstaller)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "build-windows-managed-bundle: missing required repo input: $required"
    }
}

# --- pre-flight: gateway zip present with the expected shape ------------

$gatewayZipName = "defenseclaw_${Version}_windows_amd64.zip"
$gatewayZip = Join-Path $distFull $gatewayZipName
if (-not (Test-Path -LiteralPath $gatewayZip -PathType Leaf)) {
    throw @"
build-windows-managed-bundle: missing pre-staged gateway zip: $gatewayZip

Run packaging/scripts/build-managed-windows-bundle.sh on macOS to produce it, then
copy it (and gateway-source-commit.txt) into $distFull alongside the
release-candidate wheel and upgrade-manifest.json.
"@
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($gatewayZip)
try {
    $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    foreach ($needed in @('defenseclaw.exe', 'defenseclaw-hook.exe')) {
        if ($needed -notin $entryNames) {
            throw "Pre-staged gateway zip is missing $needed at the archive root: $gatewayZip"
        }
    }
} finally {
    $archive.Dispose()
}

# --- pre-flight: local git HEAD matches the gateway's source commit ----

$commitSidecar = Join-Path $distFull 'gateway-source-commit.txt'
if (-not $SkipCommitCheck) {
    if (-not (Test-Path -LiteralPath $commitSidecar -PathType Leaf)) {
        throw @"
build-windows-managed-bundle: missing gateway-source-commit.txt in $distFull.
Either copy it from the macOS build output, or re-run with -SkipCommitCheck
if you understand that the installer will bake the local git HEAD into the
manifest and provenance without any cross-check.
"@
    }
    $expected = (Get-Content -LiteralPath $commitSidecar -Raw -Encoding UTF8).Trim()
    if ($expected -notmatch '^[0-9a-f]{40}$') {
        throw "build-windows-managed-bundle: gateway-source-commit.txt does not contain a 40-char lowercase git OID: $expected"
    }
    $localHead = (& git -C $repoRoot rev-parse --verify HEAD).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0) {
        throw "build-windows-managed-bundle: git rev-parse HEAD failed in $repoRoot"
    }
    if ($localHead -ne $expected) {
        throw @"
build-windows-managed-bundle: local defenseclaw HEAD does not match the
gateway's source commit.

  gateway built from: $expected
  local HEAD:         $localHead

Check the same commit out (git -C $repoRoot checkout $expected) before
building the installer, or re-run with -SkipCommitCheck if you accept a
mismatched source_commit in the manifest / provenance.
"@
    }
}

# --- drive the OSS installer flow -------------------------------------

[IO.Directory]::CreateDirectory($outFull) | Out-Null
[IO.Directory]::CreateDirectory($stateFull) | Out-Null

Write-Host "==> building managed-enterprise setup.exe from pre-staged gateway zip"
$installerArgs = @(
    '-DistRoot', $distFull,
    '-OutRoot',  $outFull,
    '-StateRoot', $stateFull,
    '-Version', $Version,
    '-DistributionFlavor', 'managed-enterprise'
)
if ($SkipSigning) { $installerArgs += '-SkipSigning' }

& $buildInstaller @installerArgs
if ($LASTEXITCODE -ne 0) {
    throw "build-windows-installer.ps1 failed with exit code $LASTEXITCODE"
}

Write-Host "==> managed-enterprise Windows bundle complete"
