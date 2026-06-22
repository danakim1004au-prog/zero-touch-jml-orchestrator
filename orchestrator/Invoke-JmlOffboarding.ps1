<#
.SYNOPSIS
    Security-ordered leaver sequence: disable → revoke → ungroup → mailbox
    to shared → unlicense → retire devices → OneDrive delegation → record.
.DESCRIPTION
    Unlike onboarding, offboarding has NO rollback — a half-offboarded leaver
    must be pushed forward, never unwound. Steps still log to JSONL and are
    idempotent, so re-running a failed offboard is the recovery path.
    Everything removed (groups, licenses, devices) is captured into a leaver
    record JSON — re-hire insurance and audit evidence.
.EXAMPLE
    ./Invoke-JmlOffboarding.ps1 -UserPrincipalName leaver@contoso.com -WhatIf
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, ValueFromPipeline)][string[]]$UserPrincipalName,
    [string]$SettingsPath = "$PSScriptRoot/../config/settings.json",
    [string]$RecordPath = "$PSScriptRoot/../logs/leaver-records"
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module "$PSScriptRoot/lib/JmlEngine.psm1" -Force

    $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    $runId = Start-JmlRun
    New-Item -ItemType Directory -Path $RecordPath -Force | Out-Null

    Connect-MgGraph -TenantId $settings.tenantId -ClientId $settings.clientId `
        -CertificateThumbprint $settings.certificateThumbprint -NoWelcome
    Connect-ExchangeOnline -AppId $settings.clientId -CertificateThumbprint $settings.certificateThumbprint `
        -Organization $settings.exchangeOrganization -ShowBanner:$false
}

process {
    foreach ($upn in $UserPrincipalName) {
        Write-Host "`n═══ Offboarding $upn ═══" -ForegroundColor Magenta
        $ctx = @{
            Upn        = $upn
            Settings   = $settings
            RecordPath = $RecordPath
            Record     = [ordered]@{ upn = $upn; offboardedAt = (Get-Date).ToString('o'); runId = $runId }
        }

        $steps = @(
            @{
                # FIRST: block the front door. Revoking tokens while sign-in is
                # still enabled just means the user re-authenticates.
                Name   = '1-disable-signin'
                Test   = { param($c) -not (Get-MgUser -UserId $c.Upn -Property AccountEnabled).AccountEnabled }
                Action = { param($c) Update-MgUser -UserId $c.Upn -AccountEnabled:$false }
            }
            @{
                Name   = '2-revoke-sessions'
                Test   = { param($c) $false }   # no cheap state check; revoke is harmless to repeat
                Action = {
                    param($c)
                    Invoke-MgGraphRequest -Method POST `
                        -Uri "https://graph.microsoft.com/v1.0/users/$($c.Upn)/revokeSignInSessions" | Out-Null
                }
            }
            @{
                Name   = '3-remove-groups'
                Test   = { param($c) $false }
                Action = {
                    param($c)
                    $user = Get-MgUser -UserId $c.Upn
                    $groups = Get-MgUserMemberOf -UserId $user.Id -All |
                        Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.group' }
                    $c.Record.removedGroups = @($groups | ForEach-Object { $_.AdditionalProperties.displayName })
                    foreach ($g in $groups) {
                        try { Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id }
                        catch { Write-Verbose "Skipping $($g.Id): $_ (dynamic groups can't be removed directly)" }
                    }
                }
            }
            @{
                # Convert BEFORE unlicensing: a shared mailbox under 50 GB needs
                # no license; unlicensing first starts the 30-day soft-delete clock.
                Name   = '4-mailbox-to-shared'
                Test   = { param($c) (Get-EXOMailbox -Identity $c.Upn -ErrorAction SilentlyContinue).RecipientTypeDetails -eq 'SharedMailbox' }
                Action = {
                    param($c)
                    if (Get-EXOMailbox -Identity $c.Upn -ErrorAction SilentlyContinue) {
                        Set-Mailbox -Identity $c.Upn -Type Shared
                        # Manager keeps read access for handover (Purview retention policy
                        # on the mailbox continues to apply regardless of type).
                        if ($c.Settings.PSObject.Properties['leaverMailboxDelegate'] -and $c.Settings.leaverMailboxDelegate) {
                            Add-MailboxPermission -Identity $c.Upn -User $c.Settings.leaverMailboxDelegate `
                                -AccessRights FullAccess -AutoMapping $false | Out-Null
                        }
                        $c.Record.mailboxConvertedToShared = $true
                    }
                }
            }
            @{
                Name   = '5-remove-licenses'
                Test   = { param($c) -not (Get-MgUserLicenseDetail -UserId $c.Upn) }
                Action = {
                    param($c)
                    $skus = @(Get-MgUserLicenseDetail -UserId $c.Upn | Select-Object -ExpandProperty SkuId)
                    $c.Record.removedLicenseSkus = $skus
                    if ($skus) { Set-MgUserLicense -UserId $c.Upn -AddLicenses @() -RemoveLicenses $skus | Out-Null }
                }
            }
            @{
                Name   = '6-retire-intune-devices'
                Test   = { param($c) $false }
                Action = {
                    param($c)
                    $devices = (Invoke-MgGraphRequest -Method GET `
                        -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=userPrincipalName eq '$($c.Upn)'").value
                    $c.Record.retiredDevices = @($devices | ForEach-Object { $_.deviceName })
                    foreach ($d in $devices) {
                        # Retire (not wipe): removes corporate data/profiles, leaves personal data.
                        Invoke-MgGraphRequest -Method POST `
                            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($d.id)/retire" | Out-Null
                    }
                }
            }
            @{
                Name   = '7-onedrive-manager-access'
                Test   = { param($c) $false }
                Action = {
                    param($c)
                    $manager = try { Get-MgUserManager -UserId $c.Upn } catch { $null }
                    if ($manager) {
                        # Entra setting "OneDrive retention + manager access" handles the grant
                        # when the account is deleted; here we record who that will be.
                        $c.Record.oneDriveDelegate = $manager.AdditionalProperties.userPrincipalName
                    }
                    else {
                        $c.Record.oneDriveDelegate = $c.Settings.fallbackOneDriveDelegate
                        Write-Warning "No manager set for $($c.Upn) — OneDrive falls back to $($c.Settings.fallbackOneDriveDelegate)"
                    }
                }
            }
            @{
                Name   = '8-write-leaver-record'
                Test   = { param($c) $false }
                Action = {
                    param($c)
                    $file = Join-Path $c.RecordPath "$($c.Upn -replace '@', '_at_').json"
                    $c.Record | ConvertTo-Json -Depth 4 | Set-Content -Path $file -Encoding utf8
                }
            }
        )

        Invoke-JmlPipeline -Subject $upn -Steps $steps -Context $ctx -WhatIf:$WhatIfPreference | Out-Null
    }
}

end {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "`nOffboarding run $runId complete — leaver records in $RecordPath" -ForegroundColor Green
}
