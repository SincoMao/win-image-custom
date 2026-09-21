#requires -Version 5.1
<#
  03-customize.ps1 — offline registry hive injection (SYSTEM / SOFTWARE / DEFAULT ntuser.dat),
  Defender binary & task removal, SecHealthUI provisioned-package removal, SetupComplete.cmd.

  Offline hives expose ControlSet001 only. All writes use reg.exe add /f (idempotent overwrite).
  WinSxS is never touched; no component cleanup is performed anywhere in this project.
#>
. "$PSScriptRoot\config.ps1"

function Remove-MountedTree {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    $target = Join-Path $MountDir $RelativePath
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Log "already absent, skipping: $RelativePath" 'WARN'
        return
    }
    # ACLs inside the WIM deny delete to admins; take ownership first (built-in tools only)
    $ErrorActionPreference = 'Continue'   # native stderr must not become a terminating error
    & takeown.exe /F $target /R /D Y 2>&1 | Out-Null
    & icacls.exe $target /grant 'Administrators:F' /T /C /Q 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $target) { throw "failed to fully remove $RelativePath" }
    Write-Log "removed $RelativePath" 'OK'
}

try {
    Assert-Admin
    if (-not (Test-ImageMounted)) { Stop-Step "no image mounted at $MountDir; run 02-mount.ps1 first" }

    # =====================================================================
    # A. load offline hives (SYSTEM, SOFTWARE, default user ntuser.dat)
    # =====================================================================
    $hives = @(
        @{ Alias = 'HKLM\CUS_SYS'; File = Join-Path $MountDir 'Windows\System32\config\SYSTEM' },
        @{ Alias = 'HKLM\CUS_SW';  File = Join-Path $MountDir 'Windows\System32\config\SOFTWARE' },
        @{ Alias = 'HKLM\CUS_DU';  File = Join-Path $MountDir 'Users\Default\ntuser.dat' }
    )
    foreach ($h in $hives) {
        if (-not (Test-Path -LiteralPath $h.File)) { Stop-Step "hive file missing: $($h.File)" }
        if (Test-RegKey $h.Alias) {
            $ErrorActionPreference = 'Continue'
            & reg.exe unload $h.Alias 2>$null | Out-Null   # idempotent re-run
            $ErrorActionPreference = 'Stop'
        }
        Invoke-Reg @('load', $h.Alias, $h.File) | Out-Null
        Write-Log "hive loaded: $($h.Alias) <- $($h.File)"
    }

    # =====================================================================
    # B. SYSTEM hive  (HKLM\CUS_SYS\ControlSet001\...)
    # =====================================================================
    $cs = 'HKLM\CUS_SYS\ControlSet001'

    if ($RemoveDefender) {
        foreach ($svc in $DefenderServices) {
            $key = "$cs\Services\$svc"
            if (-not (Test-RegKey $key)) { Write-Log "service key absent in image, creating value anyway: $svc" 'WARN' }
            Set-RegDword $key 'Start' 4
        }
        Write-Log '8 Defender-related services set to Start=4 (disabled)' 'OK'
    }
    # red line: these services are never modified — firewall is policy-off, wuauserv stays patchable
    foreach ($svc in $ProtectedServices) { Write-Log "protected service left untouched: $svc" }

    if ($DisableBitLockerAutoEncrypt) {
        Set-RegDword "$cs\Control\BitLocker" 'PreventDeviceEncryption' 1
        Write-Log 'BitLocker automatic device encryption disabled' 'OK'
    }

    if ($DisableVBS_HVCI_CredGuard) {
        Set-RegDword "$cs\Control\DeviceGuard" 'EnableVirtualizationBasedSecurity' 0
        Set-RegDword "$cs\Control\DeviceGuard" 'RequirePlatformSecurityFeatures' 0
        Set-RegDword "$cs\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" 'Enabled' 0
        Set-RegDword "$cs\Control\DeviceGuard\Scenarios\CredentialGuard" 'Enabled' 0
        Set-RegDword "$cs\Control\Lsa" 'LsaCfgFlags' 0
        Write-Log 'VBS / HVCI (memory integrity) / Credential Guard disabled' 'OK'
    }

    if ($BypassInstallChecks) {
        Set-RegDword "$cs\Setup\LabConfig" 'BypassTPMCheck' 1
        Set-RegDword "$cs\Setup\LabConfig" 'BypassSecureBootCheck' 1
        Set-RegDword "$cs\Setup\LabConfig" 'BypassRAMCheck' 1
        Set-RegDword "$cs\Setup\LabConfig" 'BypassCPUCheck' 1
        Write-Log 'LabConfig install-requirement bypass written' 'OK'
    }

    if ($DisableSpectreMeltdownMitigations) {
        Set-RegDword "$cs\Control\Session Manager\Memory Management" 'FeatureSettingsOverride' 3
        Set-RegDword "$cs\Control\Session Manager\Memory Management" 'FeatureSettingsOverrideMask' 3
        Write-Log 'Spectre/Meltdown mitigations disabled by user switch' 'WARN'
    }
    else {
        Write-Log 'Spectre/Meltdown mitigations kept (switch is off)'
    }

    # =====================================================================
    # C. SOFTWARE hive  (HKLM\CUS_SW\...)
    # =====================================================================
    $sw = 'HKLM\CUS_SW'

    if ($RemoveDefender) {
        Set-RegDword "$sw\Microsoft\Windows Defender\Features" 'TamperProtection' 0
        Set-RegDword "$sw\Policies\Microsoft\Windows Defender" 'DisableAntiSpyware' 1
        Set-RegDword "$sw\Policies\Microsoft\Windows Defender" 'DisableAntiVirus' 1
        $rtp = "$sw\Policies\Microsoft\Windows Defender\Real-Time Protection"
        foreach ($v in @('DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection',
                         'DisableScanOnRealtimeEnable','DisableIOAVProtection','DisableScriptScanning')) {
            Set-RegDword $rtp $v 1
        }
        Set-RegDword "$sw\Policies\Microsoft\Windows Defender\Spynet" 'SpynetReporting' 0
        Set-RegDword "$sw\Policies\Microsoft\Windows Defender\Spynet" 'SubmitSamplesConsent' 2
        Write-Log 'Defender policy layer written (tamper protection off, AV/ASpy/RTP/Spynet disabled)' 'OK'
    }

    if ($DisableSmartScreen) {
        Set-RegString "$sw\Microsoft\Windows\CurrentVersion\Explorer" 'SmartScreenEnabled' 'Off'
        Set-RegDword  "$sw\Policies\Microsoft\Windows\System" 'EnableSmartScreen' 0
        Set-RegDword  "$sw\Policies\Microsoft\Edge" 'SmartScreenEnabled' 0
        Write-Log 'SmartScreen disabled (Explorer / system policy / Edge)' 'OK'
    }

    if ($DisableFirewallAllProfiles) {
        foreach ($p in @('DomainProfile','StandardProfile','PublicProfile')) {
            Set-RegDword "$sw\Policies\Microsoft\WindowsFirewall\$p" 'EnableFirewall' 0
        }
        Write-Log 'firewall policy EnableFirewall=0 for Domain/Standard(Private)/Public profiles' 'OK'
    }

    if ($DisableTelemetry) {
        Set-RegDword "$sw\Policies\Microsoft\Windows\DataCollection" 'AllowTelemetry' 0
        Write-Log 'telemetry / CEIP disabled' 'OK'
    }

    Set-RegDword "$sw\Microsoft\Windows\CurrentVersion\OOBE" 'BypassNRO' 1
    Write-Log 'OOBE BypassNRO=1 written' 'OK'

    # =====================================================================
    # D. DEFAULT user hive (HKLM\CUS_DU -> Users\Default\ntuser.dat)
    # =====================================================================
    Set-RegDword 'HKLM\CUS_DU\Software\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation' 0
    Write-Log 'default-user AppHost EnableWebContentEvaluation=0 written' 'OK'

    # unload hives before touching files (open handles would block /discard on failure)
    Unload-OfflineHives
    Write-Log 'registry manifest applied and hives unloaded' 'OK'

    # =====================================================================
    # E. file removal manifest (inside the mounted image only)
    # =====================================================================
    if ($RemoveDefender) {
        $fileManifest = @(
            'Program Files\Windows Defender',
            'Program Files\Windows Defender Advanced Threat Protection',
            'ProgramData\Microsoft\Windows Defender',
            'Windows\System32\drivers\wd',
            'Windows\System32\Tasks\Microsoft\Windows\Windows Defender'
        )
        foreach ($rel in $fileManifest) { Remove-MountedTree $rel }
        Write-Log 'Defender binaries and scheduled tasks removed from image' 'OK'
    }
    if ($RemoveSecHealthUI) {
        Remove-MountedTree 'Windows\SystemApps\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy'
    }

    # =====================================================================
    # F. provisioned AppX: only Microsoft.Windows.SecHealthUI, nothing else
    # =====================================================================
    if ($RemoveSecHealthUI) {
        $pkgs = @(Get-AppxProvisionedPackage -Path $MountDir -ErrorAction Stop |
                  Where-Object { $_.DisplayName -eq 'Microsoft.Windows.SecHealthUI' })
        if ($pkgs.Count -eq 0) {
            Write-Log 'no Microsoft.Windows.SecHealthUI provisioned package found (already absent)' 'WARN'
        }
        foreach ($p in $pkgs) {
            $p | Remove-AppxProvisionedPackage -ErrorAction Stop | Out-Null
            Write-Log "provisioned package removed: $($p.DisplayName) $($p.Version)" 'OK'
        }
        Write-Log 'all other provisioned AppX packages left untouched'
    }

    # =====================================================================
    # G. SetupComplete.cmd — post-install fallback, idempotent, closes gaps
    # =====================================================================
    $setupDir = Join-Path $MountDir 'Windows\Setup\Scripts'
    if (-not (Test-Path -LiteralPath $setupDir)) { New-Item -ItemType Directory -Force -Path $setupDir | Out-Null }
    $cmd = New-Object System.Collections.Generic.List[string]
    $cmd.Add('@echo off')
    $cmd.Add('rem post-install fallback written by 03-customize.ps1; every line is idempotent')
    if ($DisableVBS_HVCI_CredGuard) { $cmd.Add('bcdedit /set hypervisorlaunchtype off >nul 2>&1') }
    if ($DisableFirewallAllProfiles) { $cmd.Add('netsh advfirewall set allprofiles state off >nul 2>&1') }
    $cmd.Add('powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1')   # high performance
    if ($RemoveDefender) {
        foreach ($svc in $DefenderServices) { $cmd.Add("sc.exe config $svc start= disabled >nul 2>&1") }
    }
    Set-Content -LiteralPath (Join-Path $setupDir 'SetupComplete.cmd') -Value $cmd -Encoding ASCII
    Write-Log 'SetupComplete.cmd written (bcdedit / advfirewall / powercfg / 8x sc config)' 'OK'

    Write-Log '03-customize completed' 'OK'
}
catch {
    Stop-Step ("03-customize failed: " + $_.Exception.Message)
}
