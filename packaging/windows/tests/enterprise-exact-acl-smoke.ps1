# Copyright 2026 Cisco Systems, Inc. and its affiliates
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 5.1

[CmdletBinding()]
param()

Microsoft.PowerShell.Core\Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = [IO.Path]::GetFullPath(
    (Microsoft.PowerShell.Management\Join-Path `
        $PSScriptRoot `
        '..\DefenseClawEnterprise.psm1')
)
$module = Microsoft.PowerShell.Core\Import-Module `
    -Name $modulePath `
    -Force `
    -PassThru `
    -ErrorAction Stop

$serviceSID = 'S-1-5-80-1-2-3-4-5'
$expected = [ordered]@{
    InstallDirectory = 'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
    InstallFile = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)'
    ServiceInstallDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;OICI;0x1200a9;;;$serviceSID)"
    ServiceInstallFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)(A;;0x1200a9;;;$serviceSID)"
    StateDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;$serviceSID)"
    AdminDirectory = 'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
    AdminFile = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
    ConfigDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;$serviceSID)"
    ConfigFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;$serviceSID)"
    MachinePolicyFile = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)'
    RuntimeDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;$serviceSID)"
    RuntimeFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1301bf;;;$serviceSID)"
    AuthorizationDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;$serviceSID)"
    AuthorizationFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;$serviceSID)"
    LogDirectory = 'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
    GatewayLogDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;$serviceSID)"
}
$directoryKinds = @(
    'InstallDirectory',
    'ServiceInstallDirectory',
    'StateDirectory',
    'AdminDirectory',
    'ConfigDirectory',
    'RuntimeDirectory',
    'AuthorizationDirectory',
    'LogDirectory',
    'GatewayLogDirectory'
)

$observed = & $module {
    param($Cases, $Directories, $GatewaySID)
    $sections = [Security.AccessControl.AccessControlSections]::All
    foreach ($entry in $Cases.GetEnumerator()) {
        $kind = [string]$entry.Key
        $security = New-DefenseClawCanonicalPathAcl `
            -IsDirectory ($kind -in $Directories) `
            -Kind $kind `
            -GatewayServiceSID $GatewaySID
        [pscustomobject]@{
            kind = $kind
            protected = [bool]$security.AreAccessRulesProtected
            sddl = $security.GetSecurityDescriptorSddlForm($sections)
        }
    }
} $expected $directoryKinds $serviceSID

foreach ($row in $observed) {
    if (-not [bool]$row.protected -or
        [string]$row.sddl -cne [string]$expected[[string]$row.kind]) {
        throw "canonical ACL descriptor mismatch for $($row.kind)"
    }
}
if ($observed.Count -ne $expected.Count) {
    throw 'canonical ACL smoke did not exercise every managed path kind'
}

foreach ($mismatch in @(
    [pscustomobject]@{ directory = $true; kind = 'AdminFile' },
    [pscustomobject]@{ directory = $false; kind = 'AdminDirectory' }
)) {
    $rejected = & $module {
        param($IsDirectory, $Kind, $GatewaySID)
        try {
            New-DefenseClawCanonicalPathAcl `
                -IsDirectory $IsDirectory `
                -Kind $Kind `
                -GatewayServiceSID $GatewaySID |
                    Microsoft.PowerShell.Core\Out-Null
            return $false
        }
        catch {
            return $_.Exception.Message -match 'does not match'
        }
    } ([bool]$mismatch.directory) ([string]$mismatch.kind) $serviceSID
    if (-not $rejected) {
        throw "canonical ACL builder accepted object-type mismatch $($mismatch.kind)"
    }
}

$adminRows = @($observed | Microsoft.PowerShell.Core\Where-Object {
    [string]$_.kind -in @(
        'AdminDirectory',
        'AdminFile',
        'LogDirectory'
    )
})
foreach ($row in $adminRows) {
    if ([string]$row.sddl -match [regex]::Escape($serviceSID) -or
        [string]$row.sddl -match ';;;BU\)') {
        throw "administrator-only ACL retained a stale explicit principal: $($row.kind)"
    }
}

# The installer writes canonical ACLs from one table and the deployment
# verifier re-asserts them from another. They are only correct together, so
# every pairing must agree on what the gateway service is granted.
$pairings = [ordered]@{
    InstallDirectory = 'Install'
    InstallFile = 'Install'
    ServiceInstallDirectory = 'ServiceInstall'
    ServiceInstallFile = 'ServiceInstall'
    StateDirectory = 'State'
    AdminDirectory = 'Admin'
    AdminFile = 'Admin'
    ConfigDirectory = 'ConfigDirectory'
    ConfigFile = 'Config'
    MachinePolicyFile = 'MachinePolicy'
    RuntimeDirectory = 'Runtime'
    RuntimeFile = 'Runtime'
    AuthorizationDirectory = 'AuthorizationDirectory'
    AuthorizationFile = 'AuthorizationFile'
    LogDirectory = 'Admin'
    GatewayLogDirectory = 'Runtime'
}
if ($pairings.Count -ne $expected.Count) {
    throw 'installer/verifier pairing table does not cover every managed path kind'
}
$pairingsChecked = & $module {
    param($Pairings, $Directories, $GatewaySID)
    $checked = 0
    foreach ($entry in $Pairings.GetEnumerator()) {
        $aclKind = [string]$entry.Key
        $rightsKind = [string]$entry.Value
        $security = New-DefenseClawCanonicalPathAcl `
            -IsDirectory ($aclKind -in $Directories) `
            -Kind $aclKind `
            -GatewayServiceSID $GatewaySID
        $granted = [Security.AccessControl.FileSystemRights]0
        foreach ($rule in $security.GetAccessRules(
            $true,
            $false,
            [Security.Principal.SecurityIdentifier]
        )) {
            if ([string]$rule.IdentityReference.Value -eq $GatewaySID -and
                $rule.AccessControlType -eq
                    [Security.AccessControl.AccessControlType]::Allow) {
                $granted = $granted -bor $rule.FileSystemRights
            }
        }
        $required = New-DefenseClawRequiredRights `
            -Kind $rightsKind `
            -GatewayServiceSID $GatewaySID
        $expectedRights = if ($required.ContainsKey($GatewaySID)) {
            [Security.AccessControl.FileSystemRights]$required[$GatewaySID]
        }
        else {
            [Security.AccessControl.FileSystemRights]0
        }
        if (($granted -band $expectedRights) -ne $expectedRights) {
            throw (
                "installer ACL kind {0} grants the gateway service {1}, " +
                "short of the {2} required by verifier rights kind {3}"
            ) -f $aclKind, $granted, $expectedRights, $rightsKind
        }
        # The reverse direction: a grant the verifier does not model is read by
        # its administrator-only reader allow-list as an untrusted principal.
        if ($expectedRights -eq 0 -and $granted -ne 0) {
            throw (
                "installer ACL kind {0} grants the gateway service {1}, " +
                "but verifier rights kind {2} is administrator-only"
            ) -f $aclKind, $granted, $rightsKind
        }
        $checked++
    }
    return $checked
} $pairings $directoryKinds $serviceSID
if ($pairingsChecked -ne $pairings.Count) {
    throw 'installer/verifier pairing check did not exercise every pairing'
}

$comparisonCases = & $module {
    $expectedRaw = [Security.AccessControl.RawSecurityDescriptor]::new(
        'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
    )
    $autoInheritedRaw = [Security.AccessControl.RawSecurityDescriptor]::new(
        'O:BAG:BAD:PAI(A;;FA;;;SY)(A;;FA;;;BA)'
    )
    $extraRaw = [Security.AccessControl.RawSecurityDescriptor]::new(
        'O:BAG:BAD:PAI(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)'
    )
    $splitRaw = [Security.AccessControl.RawSecurityDescriptor]::new(
        'O:BAG:BAD:PAI(A;;FA;;;SY)' +
            '(A;;0x100000;;;BA)(A;;0x0f01ff;;;BA)'
    )
    [pscustomobject]@{
        auto_inherited_accepted = Test-DefenseClawExactRawDACL `
            -Actual $autoInheritedRaw `
            -Expected $expectedRaw
        extra_ace_rejected = -not (Test-DefenseClawExactRawDACL `
            -Actual $extraRaw `
            -Expected $expectedRaw)
        split_aces_rejected = -not (Test-DefenseClawExactRawDACL `
            -Actual $splitRaw `
            -Expected $expectedRaw)
    }
}
foreach ($property in $comparisonCases.psobject.Properties) {
    if (-not [bool]$property.Value) {
        throw "canonical ACL comparison regression failed: $($property.Name)"
    }
}

$nativeDescriptor = & $module {
    param($Path)
    $native = Initialize-DefenseClawNativeSecurity
    [Security.AccessControl.RawSecurityDescriptor]::new(
        $native::GetFileSecurityDescriptor($Path),
        0
    )
} $modulePath
if ($null -eq $nativeDescriptor.DiscretionaryAcl) {
    throw 'native raw ACL query returned a null DACL'
}

[pscustomobject]@{
    ok = $true
    schema_version = 1
    descriptors_checked = $observed.Count
    stale_explicit_aces_retained = $false
    object_type_mismatches_rejected = $true
    auto_inherited_control_flag_accepted = $true
    ace_mismatches_rejected = $true
    native_raw_acl_query_checked = $true
    split_explicit_aces_rejected = $true
    installer_verifier_pairings_checked = $pairingsChecked
} | Microsoft.PowerShell.Utility\ConvertTo-Json -Compress
