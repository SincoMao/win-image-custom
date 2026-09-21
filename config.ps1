#requires -Version 5.1
<#
  config.ps1 — central switches + shared helpers for the Win11 UEFI-dev ISO pipeline.
  Dot-sourced by every step script. Edit values here, then run run-all.ps1 elevated.

  Anti-revival design (three redundant layers):
    1) Policy layer  : Policies\* keys turn off Defender / SmartScreen / firewall filtering.
    2) Service layer : Start=4 on the 8 Defender services blocks startup even if a security
                       intelligence update resets the policy layer.
    3) Binary layer  : Defender binaries and scheduled tasks are removed from the image, so
                       nothing remains to execute even if both layers above were reverted.
  Monthly cumulative updates do NOT rebuild these removals. A feature (in-place) upgrade is a
  reinstall — re-run this project against the new ISO afterwards.
#>

$ErrorActionPreference = 'Stop'

# ---------- user settings ----------
$IsoPath     = 'D:\Win11_Pro.iso'   # input, read-only, never modified
$WorkDir     = 'D:\ISO-Work'
$OutputIso   = 'D:\Win11_Dev.iso'
$EditionName = 'Windows 11 专业版'  # exact ImageName match inside the WIM/ESD
                                    # this file must stay UTF-8 WITH BOM (PS5.1 reads BOM-less
                                    # files as ANSI and the CJK name would be garbled).
                                    # for English media use: 'Windows 11 Pro'

# ---------- feature switches ----------
$RemoveDefender               = $true
$RemoveSecHealthUI            = $true
$DisableBitLockerAutoEncrypt  = $true
$DisableSmartScreen           = $true
$DisableFirewallAllProfiles   = $true   # policy off only; mpssvc service stays running
$DisableVBS_HVCI_CredGuard    = $true
$BypassInstallChecks          = $true
$DisableTelemetry             = $true
$DisableSpectreMeltdownMitigations = $false   # keep mitigations by default; switch reserved

# ---------- install account (optional; see docs/03 section 3.4) ----------
# empty (default): do NOT pre-create any account. autounattend.xml then only accepts the
# EULA, and OOBE runs exactly like stock media - the BypassNRO=1 value written into the
# image removes the forced online Microsoft-account sign-in, so whoever installs the ISO
# creates their own local account. One ISO, deployable to any machine.
# set a name here to pre-create a local administrator instead (OOBE pages are then
# skipped for an unattended install); $LocalAdminPassword may stay blank.
$LocalAdminName     = ''
$LocalAdminPassword = ''

# ---------- derived paths ----------
$IsoRoot   = Join-Path $WorkDir 'ISO'
$MountDir  = Join-Path $WorkDir 'Mount'
$LogDir    = Join-Path $WorkDir 'Logs'
$LogFile   = Join-Path $LogDir 'customize.log'
$MinFreeGB = 20

# 8 Defender services set to Start=4. NEVER touch the protected list:
# mpssvc/BFE/wscsvc (firewall & security-center infra), wuauserv/CryptSvc/DcomLaunch
# (Windows Update, cryptographic services and COM must stay healthy for patching).
$DefenderServices  = @('WinDefend','WdNisSvc','Sense','SecurityHealthService','WdFilter','WdBoot','WdNisDrv','MsSecFlt')
$ProtectedServices = @('mpssvc','BFE','wscsvc','wuauserv','CryptSvc','DcomLaunch')

foreach ($d in @($WorkDir, $LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---------- helpers ----------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','FAIL')] [string]$Level = 'INFO')
    $line = '[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'OK'   { Write-Host "[OK] $Message" -ForegroundColor Green }
        'FAIL' { Write-Host "[FAIL] $Message" -ForegroundColor Red }
        'WARN' { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log 'this script must run from an elevated (Administrator) PowerShell' 'FAIL'
        exit 1
    }
}

function Find-Oscdimg {
    $kits = @()
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($root) { $kits += Join-Path $root 'Windows Kits' }
    }
    # exact known path first, then any version variant (Kits\10, Kits\11, amd64/x86)
    $candidates = @()
    foreach ($k in $kits) {
        $candidates += Join-Path $k '10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
        $candidates += Join-Path $k '10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe'
    }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    foreach ($k in $kits) {
        $hit = Get-ChildItem -LiteralPath $k -Filter oscdimg.exe -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -like '*Oscdimg*' } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $onPath = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

function Invoke-Reg {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    # EAP=Stop turns native stderr into a terminating NativeCommandError; keep it Continue here
    $ErrorActionPreference = 'Continue'
    $out = & reg.exe @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "reg.exe $($Arguments -join ' ') failed (exit $LASTEXITCODE): $($out.Trim())" }
    return $out
}

function Enable-TokenPrivilege {
    param([string[]]$Privileges = @('SeTakeOwnershipPrivilege','SeRestorePrivilege','SeBackupPrivilege'))
    if (-not ([System.Management.Automation.PSTypeName]'Win32TokenPriv').Type) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Win32TokenPriv {
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, int acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool LookupPrivilegeValue(string host, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP n, int len, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    // native TOKEN_PRIVILEGES is 4-byte aligned: DWORD Count, LUID (2x DWORD), DWORD Attr
    // a C# long would introduce padding and hand the API a garbage LUID - split it instead
    [StructLayout(LayoutKind.Sequential)] struct TP { public int Count; public uint LuidLow; public int LuidHigh; public int Attr; }
    public static bool Enable(string name) {
        IntPtr tok; if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
        long luid; if (!LookupPrivilegeValue(null, name, out luid)) return false;
        TP tp; tp.Count = 1; tp.LuidLow = (uint)(luid & 0xffffffff); tp.LuidHigh = (int)(luid >> 32); tp.Attr = 2;
        bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        return ok && Marshal.GetLastWin32Error() == 0;   // reject ERROR_NOT_ALL_ASSIGNED
    }
}
'@
    }
    foreach ($p in $Privileges) {
        if (-not [Win32TokenPriv]::Enable($p)) { Write-Log "could not enable privilege $p" 'WARN' }
    }
}

function Grant-RegFullControl {
    # some offline keys (e.g. Microsoft\Windows Defender\*) deny write to Administrators.
    # NOTE: the PowerShell registry provider caches HKLM root keys and cannot see offline hives
    # loaded after process start, so everything here uses the Microsoft.Win32.Registry API
    # (reg.exe sees the hive fine; Registry::HKLM\... does not).
    # Strategy: enable SeTakeOwnershipPrivilege, open the deepest EXISTING key on the path with
    # TakeOwnership, set owner=Administrators, reopen with ChangePermissions, add FullControl.
    param([Parameter(Mandatory=$true)][string]$Key)
    Enable-TokenPrivilege
    $sub = $Key -replace '^HKLM\\', ''
    $parts = $sub -split '\\'
    $target = $null
    for ($i = $parts.Count; $i -gt 1 -and -not $target; $i--) {
        $candidate = ($parts[0..($i-1)] -join '\')
        $probe = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($candidate, $false)
        if ($probe) { $probe.Close(); $target = $candidate }
    }
    if (-not $target) { throw "Grant-RegFullControl: no existing key found on path $Key" }
    if ($target -ne $sub) { Write-Log "key $sub does not exist yet; relaxing nearest existing ancestor $target" }

    $admins = New-Object System.Security.Principal.NTAccount('Administrators')
    $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($target,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
    if (-not $rk) { throw "Grant-RegFullControl: cannot open $target for TakeOwnership" }
    $acl = $rk.GetAccessControl()
    $acl.SetOwner($admins)
    $rk.SetAccessControl($acl)
    $rk.Close()
    $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($target,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
    $acl = $rk.GetAccessControl()
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($admins, 'FullControl', 'ContainerInherit', 'None', 'Allow')
    $acl.SetAccessRule($rule)
    $rk.SetAccessControl($acl)
    $rk.Close()
    Write-Log "ACL relaxed on offline key: $target"
}

function Set-RegDword {
    param([string]$Key, [string]$Name, [int]$Value)
    try {
        Invoke-Reg @('add', $Key, '/v', $Name, '/t', 'REG_DWORD', '/d', [string]$Value, '/f') | Out-Null
    } catch {
        if ($_.Exception.Message -match 'Access is denied|拒绝访问') {
            Write-Log "access denied writing $Key -> $Name; relaxing ACL and retrying" 'WARN'
            Grant-RegFullControl $Key
            Invoke-Reg @('add', $Key, '/v', $Name, '/t', 'REG_DWORD', '/d', [string]$Value, '/f') | Out-Null
        } else { throw }
    }
    Write-Log ("reg  {0}  {1} = {2} (DWORD)" -f $Key, $Name, $Value)
}

function Set-RegString {
    param([string]$Key, [string]$Name, [string]$Value)
    try {
        Invoke-Reg @('add', $Key, '/v', $Name, '/t', 'REG_SZ', '/d', $Value, '/f') | Out-Null
    } catch {
        if ($_.Exception.Message -match 'Access is denied|拒绝访问') {
            Write-Log "access denied writing $Key -> $Name; relaxing ACL and retrying" 'WARN'
            Grant-RegFullControl $Key
            Invoke-Reg @('add', $Key, '/v', $Name, '/t', 'REG_SZ', '/d', $Value, '/f') | Out-Null
        } else { throw }
    }
    Write-Log ("reg  {0}  {1} = `"{2}`" (SZ)" -f $Key, $Name, $Value)
}

function Test-RegKey {
    param([string]$Key)
    $ErrorActionPreference = 'Continue'
    & reg.exe query $Key 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Unload-OfflineHives {
    $ErrorActionPreference = 'Continue'
    foreach ($alias in @('HKLM\CUS_DU', 'HKLM\CUS_SW', 'HKLM\CUS_SYS')) {
        if (Test-RegKey $alias) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $ok = $false
            for ($i = 1; $i -le 3 -and -not $ok; $i++) {
                & reg.exe unload $alias 2>$null | Out-Null
                $ok = ($LASTEXITCODE -eq 0)
                if (-not $ok) { Start-Sleep -Seconds 1 }
            }
            if ($ok) { Write-Log "hive unloaded: $alias" }
            else { Write-Log "failed to unload hive $alias (handle still open)" 'WARN' }
        }
    }
}

function Test-ImageMounted {
    try {
        $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop)
        return [bool]($mounted | Where-Object { $_.Path -eq $MountDir })
    } catch { return $false }
}

function Get-EditionIndex {
    param([Parameter(Mandatory=$true)][string]$ImageFile)
    $images = @(Get-WindowsImage -ImagePath $ImageFile -ErrorAction Stop)
    $names = ($images | ForEach-Object { '{0}="{1}"' -f $_.ImageIndex, $_.ImageName }) -join ', '
    Write-Log "indexes in ${ImageFile}: $names"
    $match = @($images | Where-Object { $_.ImageName -eq $EditionName })
    if ($match.Count -ne 1) {
        throw "edition '$EditionName' matched $($match.Count) index(es) in $ImageFile; exact single match required"
    }
    return $match[0].ImageIndex
}

function Invoke-Dism {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    Write-Log ("dism " + ($Arguments -join ' '))
    $out = & dism.exe @Arguments 2>&1 | Out-String
    Add-Content -LiteralPath $LogFile -Value $out -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "dism.exe failed (exit $LASTEXITCODE); see log" }
    return $out
}

function Stop-Step {
    # single failure path: log, unload hives, /discard any mounted WIM, abort. No half image.
    # must never throw: force Continue so a native stderr line cannot kill the cleanup itself
    param([string]$Message)
    $ErrorActionPreference = 'Continue'
    Write-Log $Message 'FAIL'
    Unload-OfflineHives
    if (Test-ImageMounted) {
        Write-Log "discarding mounted image at $MountDir (no commit)" 'WARN'
        & dism.exe /unmount-image /mountdir:$MountDir /discard 2>&1 | Out-Null
    }
    Write-Log 'step aborted; the source ISO was never modified' 'FAIL'
    exit 1
}
