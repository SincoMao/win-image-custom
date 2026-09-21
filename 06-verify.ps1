#requires -Version 5.1
<#
  06-verify.ps1 — offline verification of the customized output ISO.
  Read-only throughout: mounts the ISO, read-only mounts install.wim, copies the three
  hives to a temp dir for reg inspection, checks the removal manifest and protected
  services, then discards everything. Writes PASS/FAIL per item.
#>
. "$PSScriptRoot\config.ps1"

$script:failCount = 0
function Check {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { Write-Log ("VERIFY PASS: {0} {1}" -f $Name, $Detail) 'OK' }
    else { $script:failCount++; Write-Log ("VERIFY FAIL: {0} {1}" -f $Name, $Detail) 'FAIL' }
}

function Get-HiveDword {
    param([string]$Key, [string]$Name)
    $ErrorActionPreference = 'Continue'   # missing values write to stderr; that must not throw
    $out = & reg.exe query $Key /v $Name 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($out -match [regex]::Escape($Name) + '\s+REG_DWORD\s+0x([0-9a-fA-F]+)') { return [Convert]::ToInt32($Matches[1], 16) }
    return $null
}
function Get-HiveString {
    param([string]$Key, [string]$Name)
    $ErrorActionPreference = 'Continue'
    $lines = & reg.exe query $Key /v $Name 2>$null   # array of lines: $ anchors per line
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $lines) {
        if ($line -match ('^\s*' + [regex]::Escape($Name) + '\s+REG_SZ\s+(.*?)\s*$')) { return $Matches[1] }
    }
    return $null
}

$verifyMount = Join-Path $WorkDir 'VerifyMount'
$hiveTemp    = Join-Path $WorkDir 'VerifyHives'
$isoVol = $null

try {
    Assert-Admin

    # ---- 1. output ISO ----
    Check (Test-Path -LiteralPath $OutputIso) 'output ISO exists' $OutputIso
    if ($script:failCount) { Stop-Step 'output ISO missing, nothing to verify' }
    $isoSizeMB = [math]::Round((Get-Item -LiteralPath $OutputIso).Length / 1MB)
    Check ($isoSizeMB -gt 3000) 'ISO size sane' "${isoSizeMB} MB"

    # ---- 2. ISO structure ----
    $isoVol = Mount-DiskImage -ImagePath $OutputIso -StorageType ISO -PassThru | Get-Volume
    $r = "$($isoVol.DriveLetter):\"
    Check (Test-Path "${r}autounattend.xml")            'autounattend.xml present at ISO root'
    Check (Test-Path "${r}sources\install.wim")         'sources\install.wim present'
    Check (-not (Test-Path "${r}sources\install.esd"))  'install.esd removed'
    Check (Test-Path "${r}boot\etfsboot.com")           'BIOS boot image present'
    Check ((Test-Path "${r}efi\microsoft\boot\efisys_noprompt.bin") -or (Test-Path "${r}efi\microsoft\boot\efisys.bin")) 'EFI boot image present'
    [void][xml](Get-Content "${r}autounattend.xml" -Raw)
    $u = Get-Content "${r}autounattend.xml" -Raw
    $escName = [System.Security.SecurityElement]::Escape($LocalAdminName)
    Check ($u -match '<AcceptEula>true</AcceptEula>' -and $u -match '<ProtectYourPC>0</ProtectYourPC>' -and $u.Contains("<Name>$escName</Name>")) 'unattend content (EULA/ProtectYourPC/local admin account)'

    $idx = Get-EditionIndex -ImageFile "${r}sources\install.wim"
    Check ($idx -ge 1) 'edition index resolvable in output WIM' "index $idx"
    $imgCount = @(Get-WindowsImage -ImagePath "${r}sources\install.wim").Count
    Check ($imgCount -eq 1) 'output WIM holds exactly one edition' "count=$imgCount"

    # ---- 3. read-only mount of the customized WIM ----
    if (-not (Test-Path $verifyMount)) { New-Item -ItemType Directory -Force $verifyMount | Out-Null }
    Invoke-Dism @('/mount-image', "/imagefile:${r}sources\install.wim", "/index:$idx", "/mountdir:$verifyMount", '/readonly') | Out-Null

    # hives: copy to temp so reg load never touches the read-only mount
    if (Test-Path $hiveTemp) { Remove-Item $hiveTemp -Recurse -Force }
    New-Item -ItemType Directory -Force $hiveTemp | Out-Null
    Copy-Item "$verifyMount\Windows\System32\config\SYSTEM"    "$hiveTemp\SYS" -Force
    Copy-Item "$verifyMount\Windows\System32\config\SOFTWARE"  "$hiveTemp\SW"  -Force
    Copy-Item "$verifyMount\Users\Default\ntuser.dat"          "$hiveTemp\DU"  -Force
    Invoke-Reg @('load', 'HKLM\VER_SYS', "$hiveTemp\SYS") | Out-Null
    Invoke-Reg @('load', 'HKLM\VER_SW',  "$hiveTemp\SW")  | Out-Null
    Invoke-Reg @('load', 'HKLM\VER_DU',  "$hiveTemp\DU")  | Out-Null

    # ---- 4. SYSTEM hive checks ----
    $cs = 'HKLM\VER_SYS\ControlSet001'
    foreach ($svc in $DefenderServices) {
        Check ((Get-HiveDword "$cs\Services\$svc" 'Start') -eq 4) "service disabled: $svc"
    }
    # protected services must NOT be disabled (Start != 4)
    foreach ($svc in @('mpssvc','BFE','wscsvc','wuauserv','CryptSvc','DcomLaunch')) {
        $v = Get-HiveDword "$cs\Services\$svc" 'Start'
        Check (($null -ne $v) -and ($v -ne 4)) "protected service not disabled: $svc" "Start=$v"
    }
    Check ((Get-HiveDword "$cs\Control\BitLocker" 'PreventDeviceEncryption') -eq 1) 'BitLocker PreventDeviceEncryption=1'
    Check ((Get-HiveDword "$cs\Control\DeviceGuard" 'EnableVirtualizationBasedSecurity') -eq 0) 'VBS=0'
    Check ((Get-HiveDword "$cs\Control\DeviceGuard" 'RequirePlatformSecurityFeatures') -eq 0) 'RequirePlatformSecurityFeatures=0'
    Check ((Get-HiveDword "$cs\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" 'Enabled') -eq 0) 'HVCI=0'
    Check ((Get-HiveDword "$cs\Control\DeviceGuard\Scenarios\CredentialGuard" 'Enabled') -eq 0) 'CredentialGuard=0'
    Check ((Get-HiveDword "$cs\Control\Lsa" 'LsaCfgFlags') -eq 0) 'LsaCfgFlags=0'
    foreach ($v in @('BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck','BypassCPUCheck')) {
        Check ((Get-HiveDword "$cs\Setup\LabConfig" $v) -eq 1) "LabConfig $v=1"
    }
    $fso = Get-HiveDword "$cs\Control\Session Manager\Memory Management" 'FeatureSettingsOverride'
    Check ($null -eq $fso) 'Spectre/Meltdown mitigations untouched (FeatureSettingsOverride absent)' "value=$fso"

    # ---- 5. SOFTWARE hive checks ----
    $sw = 'HKLM\VER_SW'
    Check ((Get-HiveDword "$sw\Microsoft\Windows Defender\Features" 'TamperProtection') -eq 0) 'TamperProtection=0'
    Check ((Get-HiveDword "$sw\Policies\Microsoft\Windows Defender" 'DisableAntiSpyware') -eq 1) 'DisableAntiSpyware=1'
    Check ((Get-HiveDword "$sw\Policies\Microsoft\Windows Defender" 'DisableAntiVirus') -eq 1) 'DisableAntiVirus=1'
    $rtp = "$sw\Policies\Microsoft\Windows Defender\Real-Time Protection"
    foreach ($v in @('DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection','DisableScanOnRealtimeEnable','DisableIOAVProtection','DisableScriptScanning')) {
        Check ((Get-HiveDword $rtp $v) -eq 1) "RTP $v=1"
    }
    Check ((Get-HiveDword "$sw\Policies\Microsoft\Windows Defender\Spynet" 'SpynetReporting') -eq 0) 'SpynetReporting=0'
    Check ((Get-HiveDword "$sw\Policies\Microsoft\Windows Defender\Spynet" 'SubmitSamplesConsent') -eq 2) 'SubmitSamplesConsent=2'
    Check ((Get-HiveString "$sw\Microsoft\Windows\CurrentVersion\Explorer" 'SmartScreenEnabled') -eq 'Off') 'Explorer SmartScreenEnabled=Off'
    Check ((Get-HiveDword "$sw\Policies\Microsoft\Windows\System" 'EnableSmartScreen') -eq 0) 'System EnableSmartScreen=0'
    Check ((Get-HiveDword "$sw\Policies\Microsoft\Edge" 'SmartScreenEnabled') -eq 0) 'Edge SmartScreenEnabled=0'
    foreach ($p in @('DomainProfile','StandardProfile','PublicProfile')) {
        Check ((Get-HiveDword "$sw\Policies\Microsoft\WindowsFirewall\$p" 'EnableFirewall') -eq 0) "firewall policy off: $p"
    }
    Check ((Get-HiveDword "$sw\Policies\Microsoft\Windows\DataCollection" 'AllowTelemetry') -eq 0) 'AllowTelemetry=0'
    Check ((Get-HiveDword "$sw\Microsoft\Windows\CurrentVersion\OOBE" 'BypassNRO') -eq 1) 'OOBE BypassNRO=1'

    # ---- 6. DEFAULT hive check ----
    Check ((Get-HiveDword 'HKLM\VER_DU\Software\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation') -eq 0) 'default-user AppHost EnableWebContentEvaluation=0'

    # unload verification hives
    foreach ($a in @('HKLM\VER_DU','HKLM\VER_SW','HKLM\VER_SYS')) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $ErrorActionPreference = 'Continue'
        & reg.exe unload $a 2>$null | Out-Null
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Check ($code -eq 0) "verification hive unloaded: $a"
    }

    # ---- 7. removal manifest ----
    $removed = @(
        'Program Files\Windows Defender',
        'Program Files\Windows Defender Advanced Threat Protection',
        'ProgramData\Microsoft\Windows Defender',
        'Windows\System32\drivers\wd',
        'Windows\System32\Tasks\Microsoft\Windows\Windows Defender',
        'Windows\SystemApps\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy'
    )
    foreach ($rel in $removed) {
        Check (-not (Test-Path (Join-Path $verifyMount $rel))) "removed from image: $rel"
    }
    Check (Test-Path (Join-Path $verifyMount 'Windows\WinSxS')) 'WinSxS present and untouched'

    # ---- 8. SetupComplete.cmd ----
    $sc = Join-Path $verifyMount 'Windows\Setup\Scripts\SetupComplete.cmd'
    Check (Test-Path $sc) 'SetupComplete.cmd present'
    $scBody = Get-Content $sc -Raw
    Check ($scBody -match 'bcdedit /set hypervisorlaunchtype off') 'SetupComplete: hypervisorlaunchtype off'
    Check ($scBody -match 'netsh advfirewall set allprofiles state off') 'SetupComplete: firewall off'
    Check ($scBody -match 'powercfg /setactive 8c5e7fda') 'SetupComplete: high performance'
    foreach ($svc in $DefenderServices) {
        Check ($scBody -match "sc\.exe config $svc start= disabled") "SetupComplete: sc config $svc"
    }

    # ---- 9. cleanup ----
    Invoke-Dism @('/unmount-image', "/mountdir:$verifyMount", '/discard') | Out-Null
    Dismount-DiskImage -ImagePath $OutputIso | Out-Null; $isoVol = $null
    Remove-Item $hiveTemp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log ''
    if ($script:failCount -eq 0) { Write-Log 'ALL VERIFICATION CHECKS PASSED' 'OK'; exit 0 }
    Write-Log "$($script:failCount) verification check(s) FAILED" 'FAIL'
    exit 1
}
catch {
    $ErrorActionPreference = 'Continue'   # cleanup path must never throw
    foreach ($a in @('HKLM\VER_DU','HKLM\VER_SW','HKLM\VER_SYS')) {
        if (Test-RegKey $a) { [GC]::Collect(); & reg.exe unload $a 2>$null | Out-Null }
    }
    try { & dism.exe /unmount-image /mountdir:$verifyMount /discard 2>$null | Out-Null } catch { }
    if ($isoVol) { try { Dismount-DiskImage -ImagePath $OutputIso | Out-Null } catch { } }
    Write-Log ("06-verify crashed: " + $_.Exception.Message) 'FAIL'
    exit 1
}
