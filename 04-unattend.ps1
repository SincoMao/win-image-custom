#requires -Version 5.1
<#
  04-unattend.ps1 — write autounattend.xml into the ISO working copy root, then
  dism /unmount-image /commit the mounted image.

  Default mode ($LocalAdminName empty): the answer file only accepts the EULA.
  OOBE then runs exactly like stock media; the BypassNRO=1 value written by
  03-customize.ps1 removes the forced online Microsoft-account sign-in, so the
  person installing the ISO creates their own local account. Nothing user-specific
  is baked into the image, so one ISO can be deployed to any number of machines.

  Optional mode ($LocalAdminName set): pre-create that local administrator
  (with $LocalAdminPassword, blank allowed) and skip the OOBE pages for an
  unattended install.

  No product key, no ei.cfg, nothing activation-related is touched (red line 6).
#>
. "$PSScriptRoot\config.ps1"

try {
    Assert-Admin
    if (-not (Test-ImageMounted)) { Stop-Step "no image mounted at $MountDir; run 02-mount.ps1 first" }

    $createAccount = -not [string]::IsNullOrWhiteSpace($LocalAdminName)
    $oobeSystem = ''
    if ($createAccount) {
        # account name validation: no characters Windows forbids in user names
        if ($LocalAdminName -match '[\[\]:;|=,+*?<>"/\\]' -or $LocalAdminName.Length -gt 20) {
            Stop-Step "invalid `$LocalAdminName in config.ps1: '$LocalAdminName'"
        }
        # XML-escape before interpolation so passwords like 'p&ss<word' cannot break the file
        $escName = [System.Security.SecurityElement]::Escape($LocalAdminName)
        $escPass = [System.Security.SecurityElement]::Escape($LocalAdminPassword)
        $oobeSystem = @"
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
            <Name>$escName</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>$escPass</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
"@
    }

    $unattend = @"
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
$oobeSystem</unattend>
"@

    $target = Join-Path $IsoRoot 'autounattend.xml'
    Set-Content -LiteralPath $target -Value $unattend -Encoding UTF8
    # XML well-formedness check before we commit anything
    [void][xml](Get-Content -LiteralPath $target -Raw)

    if ($createAccount) {
        Write-Log "autounattend.xml written to $target (pre-created local admin '$LocalAdminName', OOBE pages skipped)" 'OK'
        if ([string]::IsNullOrEmpty($LocalAdminPassword)) {
            Write-Log "NOTE: '$LocalAdminName' has a BLANK password; set one on first logon (net user $LocalAdminName *)" 'WARN'
        }
    }
    else {
        Write-Log "autounattend.xml written to $target (EULA only; stock OOBE, BypassNRO removes forced MSA sign-in)" 'OK'
    }

    Write-Log "committing image: dism /unmount-image /mountdir:$MountDir /commit"
    Invoke-Dism @('/unmount-image', "/mountdir:$MountDir", '/commit', '/checkintegrity') | Out-Null
    if (Test-ImageMounted) { Stop-Step 'unmount reported success but image is still mounted' }
    Write-Log 'image committed and unmounted (no /startcomponentcleanup, no /resetbase)' 'OK'

    Write-Log '04-unattend completed' 'OK'
}
catch {
    Stop-Step ("04-unattend failed: " + $_.Exception.Message)
}
