#requires -Version 5.1
<#
  run-all.ps1 — executes the full pipeline 01 -> 05 in child processes.
  Any step that fails aborts the pipeline; the failing step has already unloaded hives
  and /discard'ed any mounted WIM, so no half-finished image is ever produced.
#>
. "$PSScriptRoot\config.ps1"

Assert-Admin

# fail fast if the packager is missing, before hours of extraction work
$oscdimg = Find-Oscdimg
if (-not $oscdimg) {
    Write-Log 'oscdimg.exe not found. Install Windows ADK "Deployment Tools" first:' 'FAIL'
    Write-Log '  winget install --id Microsoft.WindowsADK  (select Deployment Tools)' 'FAIL'
    exit 1
}
Write-Log "oscdimg: $oscdimg" 'OK'

if (-not (Test-Path -LiteralPath $IsoPath)) {
    Write-Log "input ISO not found: $IsoPath" 'FAIL'
    exit 1
}

$steps = @('01-extract.ps1', '02-mount.ps1', '03-customize.ps1', '04-unattend.ps1', '05-repack.ps1')
foreach ($step in $steps) {
    Write-Log "================ $step ================"
    $ErrorActionPreference = 'Continue'   # child stderr must not kill the orchestrator
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $step)
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) {
        Write-Log "$step failed (exit $code); pipeline aborted" 'FAIL'
        exit $code
    }
    Write-Log "$step finished" 'OK'
}

Write-Log "pipeline complete: $OutputIso" 'OK'
Write-Log "log: $LogFile"
