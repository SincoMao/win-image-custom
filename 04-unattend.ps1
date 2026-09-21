#requires -Version 5.1
<#
  04-unattend.ps1 — write autounattend.xml into the ISO working copy root, then
  dism /unmount-image /commit the mounted image.

  The answer file skips EULA/OOBE pages, disables "protect my PC" (update auto-settings
  are left at OS defaults otherwise), and creates a local Administrator account "Xinyu"
  with a BLANK password — set it on first logon (or edit this file before running).
  No product key, no ei.cfg, nothing activation-related is touched (red line 6).
#>
. "$PSScriptRoot\config.ps1"

try {
    Assert-Admin
    if (-not (Test-ImageMounted)) { Stop-Step "no image mounted at $MountDir; run 02-mount.ps1 first" }

    $unattend = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>0</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>Xinyu</Name>
            <Group>Administrators</Group>
            <Password>
              <Value></Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
'@

    $target = Join-Path $IsoRoot 'autounattend.xml'
    Set-Content -LiteralPath $target -Value $unattend -Encoding UTF8
    # XML well-formedness check before we commit anything
    [void][xml](Get-Content -LiteralPath $target -Raw)
    Write-Log "autounattend.xml written to $target (local admin 'Xinyu', blank password)" 'OK'
    Write-Log 'NOTE: set the Xinyu account password on first logon' 'WARN'

    Write-Log "committing image: dism /unmount-image /mountdir:$MountDir /commit"
    Invoke-Dism @('/unmount-image', "/mountdir:$MountDir", '/commit', '/checkintegrity') | Out-Null
    if (Test-ImageMounted) { Stop-Step 'unmount reported success but image is still mounted' }
    Write-Log 'image committed and unmounted (no /startcomponentcleanup, no /resetbase)' 'OK'

    Write-Log '04-unattend completed' 'OK'
}
catch {
    Stop-Step ("04-unattend failed: " + $_.Exception.Message)
}
