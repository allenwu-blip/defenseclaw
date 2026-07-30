# Copyright 2026 Cisco Systems, Inc. and its affiliates
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Advisory packaged OmniGent native-Windows degraded-mode contract.

.DESCRIPTION
    Installs the official OmniGent 0.7.0 client with its documented uv-tool
    path, installs the packaged DefenseClaw distribution, registers the
    in-process policy, starts the real OmniGent server, and verifies live,
    fail-closed, and teardown behavior. No WSL, shell compatibility layer,
    terminal wrapper, container, or sandbox-parity assertion is involved.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactRoot,
    [Parameter(Mandatory)][string]$StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows -or [Environment]::Is64BitOperatingSystem -ne $true) {
    throw 'OmniGent native contract requires Windows x64'
}

$state = [IO.Path]::GetFullPath($StateRoot)
$artifacts = [IO.Path]::GetFullPath($ArtifactRoot)
if (-not (Test-Path -LiteralPath $artifacts -PathType Container)) {
    throw "packaged artifact directory is missing: $artifacts"
}
[IO.Directory]::CreateDirectory($state) | Out-Null

$env:DEFENSECLAW_HOME = Join-Path $state 'defenseclaw'
$env:OMNIGENT_CONFIG_HOME = Join-Path $state 'omnigent-config'
$env:OMNIGENT_DATA_DIR = Join-Path $state 'omnigent-data'
$env:UV_TOOL_DIR = Join-Path $state 'uv-tools'
$env:UV_TOOL_BIN_DIR = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local\bin'
$env:UV_CACHE_DIR = Join-Path $state 'uv-cache'
$env:OMNIGENT_ACCOUNTS_AUTO_OPEN = '0'
$env:PATH = $env:UV_TOOL_BIN_DIR + ';' + $env:PATH
foreach ($directory in @(
    $env:DEFENSECLAW_HOME,
    $env:OMNIGENT_CONFIG_HOME,
    $env:OMNIGENT_DATA_DIR,
    $env:UV_TOOL_DIR,
    $env:UV_TOOL_BIN_DIR
)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "native process failed with exit code $LASTEXITCODE`: $FilePath"
    }
}

$uv = (Get-Command uv.exe -CommandType Application -ErrorAction Stop).Source
Invoke-NativeChecked $uv @(
    'tool', 'install', '--python', '3.12', '--force', 'omnigent==0.7.0'
)
$omnigent = Join-Path $env:UV_TOOL_BIN_DIR 'omnigent.exe'
$omnigentPython = Join-Path $env:UV_TOOL_DIR 'omnigent\Scripts\python.exe'
foreach ($required in @($omnigent, $omnigentPython)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "official OmniGent uv-tool installation is incomplete: $required"
    }
}
$version = (& $omnigent '--version' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -notmatch '\b0\.7\.0\b') {
    throw "official OmniGent version probe was not 0.7.0: $version"
}

$install = Join-Path $PSScriptRoot 'install.ps1'
$pwsh = (Get-Process -Id $PID).Path
Invoke-NativeChecked $pwsh @(
    '-NoLogo', '-NoProfile', '-File', $install,
    '-Local', $artifacts, '-Connector', 'none', '-Yes', '-NoPersistPath'
)

$defenseclaw = Join-Path $env:DEFENSECLAW_HOME '.venv\Scripts\defenseclaw.exe'
$gateway = Join-Path $env:UV_TOOL_BIN_DIR 'defenseclaw-gateway.exe'
foreach ($required in @($defenseclaw, $gateway)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "packaged DefenseClaw installation is incomplete: $required"
    }
}

Invoke-NativeChecked $defenseclaw @(
    'setup', 'omnigent', '--yes', '--mode', 'action',
    '--fail-mode', 'closed', '--restart'
)

$config = Join-Path $env:OMNIGENT_CONFIG_HOME 'config.yaml'
$module = Join-Path $env:DEFENSECLAW_HOME 'hooks\defenseclaw_omnigent_policy.py'
$pth = Join-Path $env:UV_TOOL_DIR 'omnigent\Lib\site-packages\defenseclaw_omnigent.pth'
foreach ($required in @($config, $module, $pth)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "OmniGent policy setup did not create required state: $required"
    }
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$serverOut = Join-Path $state 'omnigent-server.stdout.log'
$serverErr = Join-Path $state 'omnigent-server.stderr.log'
$server = Start-Process -FilePath $omnigent -ArgumentList @(
    'server', '--host', '127.0.0.1', '--port', [string]$port,
    '--config', $config, '--no-open'
) -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if ($server.HasExited) {
            throw "official OmniGent server exited before readiness with code $($server.ExitCode)"
        }
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $client.Connect('127.0.0.1', $port)
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 250
        } finally {
            $client.Dispose()
        }
    }
    if (-not $ready) {
        throw 'official OmniGent server did not bind its native loopback listener'
    }

    $policyProbe = @'
import json
import defenseclaw_omnigent_policy as policy
print(json.dumps(policy.defenseclaw_policy({
    "type": "tool_call",
    "target": "read_file",
    "data": {"name": "read_file", "arguments": {"path": "README.md"}},
    "context": {"actor": {"client_id": "windows-native-contract"}},
})))
'@
    $liveVerdict = (& $omnigentPython '-I' '-c' $policyProbe | Out-String).Trim() | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or [string]$liveVerdict.result -notin @('ALLOW', 'ASK', 'DENY')) {
        throw 'official OmniGent Python environment did not execute the managed policy'
    }

    Invoke-NativeChecked $gateway @('stop')
    $closedVerdict = (& $omnigentPython '-I' '-c' $policyProbe | Out-String).Trim() | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or [string]$closedVerdict.result -cne 'DENY') {
        throw 'OmniGent managed policy did not fail closed after the gateway stopped'
    }

    Invoke-NativeChecked $defenseclaw @('setup', 'remove', 'omnigent', '--yes', '--restart')
    if ((Test-Path -LiteralPath $module) -or (Test-Path -LiteralPath $pth)) {
        throw 'OmniGent teardown left a managed policy runtime artifact'
    }
    if ((Test-Path -LiteralPath $config) -and
        (Get-Content -LiteralPath $config -Raw).Contains('defenseclaw_omnigent')) {
        throw 'OmniGent teardown left the DefenseClaw policy registration'
    }
} finally {
    if (-not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        $server.WaitForExit(10000)
    }
    $server.Dispose()
}

Write-Host 'OmniGent 0.7.0 packaged native-Windows degraded-mode contract passed.'
