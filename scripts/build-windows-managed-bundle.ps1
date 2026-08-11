# Copyright 2026 Cisco Systems, Inc. and its affiliates
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Build a managed-enterprise Windows setup.exe: swap the private cloudreg
    overlay in, cross-build defenseclaw.exe + defenseclaw-hook.exe with
    -tags cmid, package the goreleaser-shaped gateway zip, then drive
    build-windows-installer.ps1 -DistributionFlavor managed-enterprise.

.DESCRIPTION
    Windows counterpart of scripts/build-macos-bundle.sh, adapted to the
    Windows installer's DistRoot contract: $DistRoot must already contain
    the wheel and upgrade-manifest.json produced elsewhere (typically by
    the release candidate pipeline); this script writes / overwrites only
    the gateway zip.

    The overlay swap follows the exact snapshot / restore pattern of
    scripts/build-macos-bundle.sh: internal/managed/cloudreg/provider_cisco.go,
    go.mod, and go.sum are copied into a temp dir before the swap and
    restored on exit whether the build succeeded or failed, leaving the
    working tree clean for the next run.

    The Windows binding for the CMID library lives in the private
    github.com/cisco-aispg/ai-common/cmid module; the caller of this script
    is responsible for having a valid -CmidOverlay path and a matching
    -CmidVersion pseudo-version. scripts/build-managed-windows-installer.ps1
    wraps this script and handles that plumbing.

.PARAMETER Version
    Release version string, e.g. 0.9.0 or 0.9.0-rc1.

.PARAMETER DistRoot
    Directory containing the Python wheel and upgrade-manifest.json. The
    generated gateway zip is written here alongside those files.

.PARAMETER OutRoot
    Directory where DefenseClawSetup-x64.exe and its sidecars will be
    written by build-windows-installer.ps1.

.PARAMETER StateRoot
    Scratch directory for build-windows-installer.ps1.

.PARAMETER CmidOverlay
    Absolute (or repo-relative) path to the private cloudreg
    provider_cisco.go overlay file. Required whenever -Tags contains
    "cmid" and -SkipOverlay is not passed.

.PARAMETER CmidVersion
    Pseudo-version to pin github.com/cisco-aispg/ai-common/cmid to via
    `go get`. Required whenever -CmidOverlay is set.

.PARAMETER Tags
    Comma-separated go build -tags value. Defaults to "cmid".

.PARAMETER SkipOverlay
    Skip the overlay swap and go-get pin. Intended for local packaging
    tests without private-registry access; the resulting managed-enterprise
    binary will fail-closed at runtime because the OSS stub is still in
    place.

.PARAMETER SkipInstaller
    Skip invoking build-windows-installer.ps1. Only build the gateway zip
    (useful for testing this script in isolation).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$DistRoot,
    [Parameter(Mandatory = $true)][string]$OutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$CmidOverlay = "",
    [string]$CmidVersion = "",
    [string]$Tags = "cmid",
    [switch]$SkipOverlay,
    [switch]$SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $IsWindows) {
    throw "build-windows-managed-bundle.ps1 must run on Windows (needs the .exe toolchain and PowerShell resource stamping)."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cloudregTarget = Join-Path $repoRoot 'internal\managed\cloudreg\provider_cisco.go'
$goModFile = Join-Path $repoRoot 'go.mod'
$goSumFile = Join-Path $repoRoot 'go.sum'
$windowsResources = Join-Path $repoRoot 'internal\tools\windowsresources'
$iconAsset = Join-Path $repoRoot 'macos\DefenseClawMac\DefenseClawMac\Assets.xcassets\AppIcon.appiconset\icon_256.png'
$buildInstaller = Join-Path $PSScriptRoot 'build-windows-installer.ps1'

foreach ($required in @($cloudregTarget, $goModFile, $goSumFile, $iconAsset, $buildInstaller)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "build-windows-managed-bundle: missing required repo input: $required"
    }
}

if ($Version -notmatch '^\d+\.\d+\.\d+(-[A-Za-z0-9_.-]+)?$') {
    throw "Invalid version for managed Windows bundle: $Version"
}

$distFull = [IO.Path]::GetFullPath($DistRoot)
$outFull = [IO.Path]::GetFullPath($OutRoot)
$stateFull = [IO.Path]::GetFullPath($StateRoot)
[IO.Directory]::CreateDirectory($distFull) | Out-Null
[IO.Directory]::CreateDirectory($outFull) | Out-Null
[IO.Directory]::CreateDirectory($stateFull) | Out-Null

$applyOverlay = -not $SkipOverlay -and ($Tags -match '(^|,)cmid(,|$)')
if ($applyOverlay) {
    if (-not $CmidOverlay) {
        throw "-CmidOverlay is required when -Tags contains 'cmid' (pass -SkipOverlay to build with the OSS stub for local tests only)."
    }
    if (-not $CmidVersion) {
        throw "-CmidVersion is required when -CmidOverlay is set."
    }
    $overlayAbs = $CmidOverlay
    if (-not [IO.Path]::IsPathRooted($overlayAbs)) {
        $overlayAbs = Join-Path $repoRoot $CmidOverlay
    }
    if (-not (Test-Path -LiteralPath $overlayAbs -PathType Leaf)) {
        throw "build-windows-managed-bundle: overlay file not found: $overlayAbs"
    }
}

# --- overlay snapshot + restore (mirrors build-macos-bundle.sh:87-131) ---

$snapshotDir = $null
$overlayApplied = $false

function Restore-Overlay {
    if ($script:overlayApplied -and $script:snapshotDir -and (Test-Path -LiteralPath $script:snapshotDir)) {
        Write-Host "==> restoring cloudreg stub + go.mod/go.sum from snapshot"
        Copy-Item -LiteralPath (Join-Path $script:snapshotDir 'provider_cisco.go') -Destination $cloudregTarget -Force
        Copy-Item -LiteralPath (Join-Path $script:snapshotDir 'go.mod')             -Destination $goModFile      -Force
        Copy-Item -LiteralPath (Join-Path $script:snapshotDir 'go.sum')             -Destination $goSumFile      -Force
        $script:overlayApplied = $false
    }
    if ($script:snapshotDir -and (Test-Path -LiteralPath $script:snapshotDir)) {
        Remove-Item -LiteralPath $script:snapshotDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    if ($applyOverlay) {
        $snapshotDir = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("dc-cmid-overlay-" + [Guid]::NewGuid().ToString("N"))) | Select-Object -ExpandProperty FullName
        Write-Host "==> snapshotting cloudreg stub + go.mod/go.sum to $snapshotDir"
        Copy-Item -LiteralPath $cloudregTarget -Destination (Join-Path $snapshotDir 'provider_cisco.go') -Force
        Copy-Item -LiteralPath $goModFile      -Destination (Join-Path $snapshotDir 'go.mod')             -Force
        Copy-Item -LiteralPath $goSumFile      -Destination (Join-Path $snapshotDir 'go.sum')             -Force

        # Flip OVERLAY_APPLIED BEFORE the swap so a mid-write failure past
        # this point still triggers a restore from the snapshot.
        $overlayApplied = $true
        Write-Host "==> applying cloudreg overlay: $overlayAbs"
        Copy-Item -LiteralPath $overlayAbs -Destination $cloudregTarget -Force

        Write-Host "==> pinning managed cloud auth module @$CmidVersion"
        Push-Location $repoRoot
        try {
            & go get "github.com/cisco-aispg/ai-common/cmid@$CmidVersion"
            if ($LASTEXITCODE -ne 0) {
                throw "go get failed with exit code $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    }

    # --- cross-build gateway + hook with -tags $Tags ------------------

    $stageDir = Join-Path $stateFull "gateway-stage"
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    }
    [IO.Directory]::CreateDirectory($stageDir) | Out-Null

    $gatewayExe = Join-Path $stageDir 'defenseclaw.exe'
    $hookExe    = Join-Path $stageDir 'defenseclaw-hook.exe'
    $ldflagsGateway = "-s -w -buildid=defenseclaw-$Version-windows-amd64 -X main.version=$Version"
    $ldflagsHook    = "-s -w -buildid=defenseclaw-hook-$Version-windows-amd64 -H=windowsgui -X main.version=$Version"

    Push-Location $repoRoot
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        $goArgs = @('build', '-trimpath', '-buildvcs=false')
        if ($Tags) { $goArgs += @('-tags', $Tags) }
        Write-Host "==> building defenseclaw.exe (windows/amd64 tags=$Tags)"
        & go @goArgs -ldflags $ldflagsGateway -o $gatewayExe ./cmd/defenseclaw
        if ($LASTEXITCODE -ne 0) { throw "go build defenseclaw failed with exit code $LASTEXITCODE" }

        Write-Host "==> stamping defenseclaw.exe VERSIONINFO / icon"
        & go run "./internal/tools/windowsresources" -target windows_amd64 `
            -executable $gatewayExe -component gateway -version $Version -icon $iconAsset
        if ($LASTEXITCODE -ne 0) { throw "windowsresources gateway stamp failed with exit code $LASTEXITCODE" }

        Write-Host "==> building defenseclaw-hook.exe (windows/amd64 tags=$Tags)"
        & go @goArgs -ldflags $ldflagsHook -o $hookExe ./cmd/defenseclaw-hook
        if ($LASTEXITCODE -ne 0) { throw "go build defenseclaw-hook failed with exit code $LASTEXITCODE" }

        Write-Host "==> stamping defenseclaw-hook.exe VERSIONINFO / icon"
        & go run "./internal/tools/windowsresources" -target windows_amd64 `
            -executable $hookExe -component hook -version $Version -icon $iconAsset
        if ($LASTEXITCODE -ne 0) { throw "windowsresources hook stamp failed with exit code $LASTEXITCODE" }
    } finally {
        Remove-Item Env:GOOS -ErrorAction SilentlyContinue
        Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
        Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
        Pop-Location
    }

    # --- assemble the goreleaser-shaped archive ------------------------

    Write-Host "==> assembling gateway archive contents"
    foreach ($shipped in @('LICENSE', 'README.md', 'CHANGELOG.md')) {
        $source = Join-Path $repoRoot $shipped
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $stageDir $shipped) -Force
        }
    }
    $packagingSource = Join-Path $repoRoot 'packaging'
    Copy-Item -LiteralPath $packagingSource -Destination (Join-Path $stageDir 'packaging') -Recurse -Force

    $gatewayZipName = "defenseclaw_${Version}_windows_amd64.zip"
    $gatewayZip = Join-Path $distFull $gatewayZipName
    if (Test-Path -LiteralPath $gatewayZip) {
        Remove-Item -LiteralPath $gatewayZip -Force
    }
    Write-Host "==> writing $gatewayZipName"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stageDir, $gatewayZip,
        [IO.Compression.CompressionLevel]::Optimal, $false
    )

    if ($SkipInstaller) {
        Write-Host "==> -SkipInstaller set: gateway zip written to $gatewayZip; not invoking build-windows-installer.ps1"
        return
    }

    # --- drive build-windows-installer.ps1 ----------------------------

    Write-Host "==> building managed-enterprise setup.exe"
    & $buildInstaller `
        -DistRoot $distFull `
        -OutRoot $outFull `
        -StateRoot $stateFull `
        -Version $Version `
        -DistributionFlavor 'managed-enterprise'
    if ($LASTEXITCODE -ne 0) {
        throw "build-windows-installer.ps1 failed with exit code $LASTEXITCODE"
    }
    Write-Host "==> managed-enterprise Windows bundle complete"
}
finally {
    Restore-Overlay
}
