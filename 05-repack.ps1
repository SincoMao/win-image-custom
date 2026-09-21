#requires -Version 5.1
<#
  05-repack.ps1 — dual-boot (BIOS + UEFI) repack of $WorkDir\ISO into $OutputIso via oscdimg.
  Requires Windows ADK "Deployment Tools" (oscdimg.exe); the script locates it automatically.
#>
. "$PSScriptRoot\config.ps1"

try {
    Assert-Admin

    $oscdimg = Find-Oscdimg
    if (-not $oscdimg) {
        Write-Log 'oscdimg.exe not found. Install the Windows ADK with the "Deployment Tools" feature' 'FAIL'
        Write-Log '  winget install --id Microsoft.WindowsADK   (then select Deployment Tools), or' 'FAIL'
        Write-Log '  https://learn.microsoft.com/windows-hardware/get-started/adk-install' 'FAIL'
        exit 1
    }
    Write-Log "oscdimg: $oscdimg" 'OK'

    if (Test-ImageMounted) {
        Stop-Step "an image is still mounted at $MountDir; run 04-unattend.ps1 to commit it first"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $IsoRoot 'sources\install.wim'))) {
        Stop-Step 'sources\install.wim missing in working copy; run 01-extract.ps1 first'
    }

    $etfs = Join-Path $IsoRoot 'boot\etfsboot.com'
    if (-not (Test-Path -LiteralPath $etfs)) { Stop-Step "BIOS boot image missing: $etfs" }
    $efi = Join-Path $IsoRoot 'efi\microsoft\boot\efisys_noprompt.bin'
    if (-not (Test-Path -LiteralPath $efi)) {
        $efiAlt = Join-Path $IsoRoot 'efi\microsoft\boot\efisys.bin'
        if (Test-Path -LiteralPath $efiAlt) {
            Write-Log 'efisys_noprompt.bin not found; falling back to efisys.bin' 'WARN'
            $efi = $efiAlt
        }
        else { Stop-Step "EFI boot image missing: $efi" }
    }

    if (Test-Path -LiteralPath $OutputIso) {
        Remove-Item -LiteralPath $OutputIso -Force
        Write-Log 'previous output ISO removed (idempotent re-run)'
    }

    # exact spec command; built as one cmd line so embedded quotes survive verbatim
    $cmdline = '"{0}" -m -o -u2 -udfver102 -bootdata:2#p0,e,b"{1}"#pEF,e,b"{2}" "{3}" "{4}"' -f `
               $oscdimg, $etfs, $efi, $IsoRoot, $OutputIso
    Write-Log "repack: $cmdline"
    $ErrorActionPreference = 'Continue'   # native stderr must not become a terminating error
    $out = & cmd.exe /c $cmdline 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    Add-Content -LiteralPath $LogFile -Value $out -Encoding UTF8
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputIso)) {
        throw "oscdimg failed (exit $LASTEXITCODE); see log"
    }
    $sizeMB = [math]::Round((Get-Item -LiteralPath $OutputIso).Length / 1MB)
    Write-Log "output ISO written: $OutputIso (${sizeMB} MB)" 'OK'

    # acceptance checklist -> console, log and a standalone file
    $checklist = @'
==================== ACCEPTANCE CHECKLIST (verify in a Hyper-V VM first) ====================
1. Clean-install the output ISO in a VM; at first desktop:
   - sc query WinDefend            -> service does not exist or is disabled
   - tasklist | findstr MsMpEng    -> no matches
   - manage-bde -status C:         -> Protection Off, no automatic encryption running
   - netsh advfirewall show allprofiles -> State OFF on Domain/Private/Public
   - msinfo32: "Virtualization-based security" = Not enabled
   - no "Windows Security" app, or its Virus & threat protection page is gone
2. Copy a firmware build tree containing .efi / .fd files anywhere: no block, no delete alerts
3. Download dev resources from intranet share and browser: no SmartScreen prompt
4. Visual Studio Installer runs and completes installation
5. wuauclt /detectnow (or Settings > Windows Update) works: WU service healthy
6. Power plan = High performance; bcdedit shows hypervisorlaunchtype = Off
===========================================================================================
'@
    Write-Host $checklist
    Add-Content -LiteralPath $LogFile -Value $checklist -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $LogDir 'acceptance-checklist.txt') -Value $checklist -Encoding UTF8

    Write-Log '05-repack completed' 'OK'
}
catch {
    Stop-Step ("05-repack failed: " + $_.Exception.Message)
}
