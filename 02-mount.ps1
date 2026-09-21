#requires -Version 5.1
<#
  02-mount.ps1 — mount install.wim (edition-matched index) to $WorkDir\Mount.
  If a previous mount exists it is discarded first, so every run starts from a clean baseline.
#>
. "$PSScriptRoot\config.ps1"

try {
    Assert-Admin

    $wim = Join-Path $IsoRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim)) { Stop-Step "install.wim not found at $wim; run 01-extract.ps1 first" }

    if (Test-ImageMounted) {
        Write-Log 'an image is already mounted; discarding it for a clean baseline' 'WARN'
        & dism.exe /unmount-image /mountdir:$MountDir /discard 2>&1 | Out-Null
        if (Test-ImageMounted) { Stop-Step 'failed to discard the previously mounted image' }
    }

    if (-not (Test-Path -LiteralPath $MountDir)) { New-Item -ItemType Directory -Force -Path $MountDir | Out-Null }

    $idx = Get-EditionIndex -ImageFile $wim
    Write-Log "mounting $wim index $idx ('$EditionName') -> $MountDir"
    Invoke-Dism @('/mount-image', "/imagefile:$wim", "/index:$idx", "/mountdir:$MountDir") | Out-Null

    if (-not (Test-ImageMounted)) { Stop-Step 'mount reported success but the image is not listed as mounted' }
    Write-Log "image mounted at $MountDir (index $idx)" 'OK'
    Write-Log '02-mount completed' 'OK'
}
catch {
    Stop-Step ("02-mount failed: " + $_.Exception.Message)
}
