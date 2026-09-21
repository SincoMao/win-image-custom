#requires -Version 5.1
<#
  01-extract.ps1 — validate input, copy ISO contents to $WorkDir\ISO (source stays read-only),
  convert install.esd -> install.wim via dism /export-image when needed.
#>
. "$PSScriptRoot\config.ps1"

try {
    Assert-Admin

    # --- step 1: input validation -------------------------------------------
    if (-not (Test-Path -LiteralPath $IsoPath)) { Stop-Step "input ISO not found: $IsoPath" }
    (Get-Item -LiteralPath $IsoPath).IsReadOnly = $true   # enforce read-only on the source
    Write-Log "source ISO: $IsoPath (set read-only)" 'OK'

    $driveName = [IO.Path]::GetPathRoot($WorkDir).TrimEnd('\')
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$driveName'" -ErrorAction Stop
    $freeGB = [math]::Floor($disk.FreeSpace / 1GB)
    if ($freeGB -lt $MinFreeGB) { Stop-Step "free space on $driveName is ${freeGB}GB, need >= ${MinFreeGB}GB" }
    Write-Log "free space on ${driveName}: ${freeGB}GB (>= ${MinFreeGB}GB)" 'OK'

    # --- steps 2-3: extract (idempotent via marker) --------------------------
    $marker = Join-Path $WorkDir '.extract-done'
    $wim = Join-Path $IsoRoot 'sources\install.wim'
    $esd = Join-Path $IsoRoot 'sources\install.esd'

    if ((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $wim)) {
        Write-Log 'extraction marker present, reusing existing working copy'
        $idx = Get-EditionIndex -ImageFile $wim   # re-validate edition match
        Write-Log "edition '$EditionName' = index $idx (reused)" 'OK'
    }
    else {
        if (Test-Path -LiteralPath $IsoRoot) {
            Write-Log 'removing stale working copy' 'WARN'
            Remove-Item -LiteralPath $IsoRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $IsoRoot | Out-Null

        Write-Log "mounting ISO $IsoPath"
        $mounted = $false
        try {
            $vol = $null
            for ($i = 1; $i -le 5 -and -not $vol; $i++) {
                $vol = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -PassThru -ErrorAction Stop | Get-Volume
                if (-not $vol -or -not $vol.DriveLetter) { $vol = $null; Start-Sleep -Seconds 1 }
            }
            if (-not $vol) { throw 'Mount-DiskImage returned no drive letter' }
            $mounted = $true
            $src = "$($vol.DriveLetter):\"
            Write-Log "copying $src* -> $IsoRoot"
            Copy-Item -Path "$src*" -Destination $IsoRoot -Recurse -Force -ErrorAction Stop
        }
        finally {
            if ($mounted) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null; Write-Log 'ISO dismounted' }
        }
        Write-Log 'ISO contents copied to working dir' 'OK'

        if (Test-Path -LiteralPath $esd) {
            # MCT media ships install.esd; export the matching edition to install.wim
            $idx = Get-EditionIndex -ImageFile $esd
            Write-Log "exporting index $idx ('$EditionName') from install.esd -> install.wim"
            Invoke-Dism @('/export-image', "/sourceimagefile:$esd", "/sourceindex:$idx",
                          "/destinationimagefile:$wim", '/compress:max', '/checkintegrity') | Out-Null
            Remove-Item -LiteralPath $esd -Force
            Write-Log 'install.esd exported to install.wim and removed' 'OK'
        }
        elseif (Test-Path -LiteralPath $wim) {
            $idx = Get-EditionIndex -ImageFile $wim
            Write-Log "install.wim already present; edition '$EditionName' = index $idx" 'OK'
        }
        else {
            Stop-Step "neither install.esd nor install.wim found under $IsoRoot\sources"
        }
        New-Item -ItemType File -Force -Path $marker | Out-Null
    }

    Write-Log '01-extract completed' 'OK'
}
catch {
    Stop-Step ("01-extract failed: " + $_.Exception.Message)
}
