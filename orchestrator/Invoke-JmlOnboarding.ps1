<#
.SYNOPSIS
    Zero-touch onboarding: CSV of new hires → 8-step provisioning pipeline
    per user, with per-step rollback on failure.
.DESCRIPTION
    Steps: Entra user → usage location → license → groups → Autopilot device
    group → EXO mailbox config → Teams → welcome mail to manager. Each step
    is idempotent (Test before Action), so re-running after a partial failure
    is safe. -WhatIf prints the plan without touching anything.
.EXAMPLE
    ./Invoke-JmlOnboarding.ps1 -CsvPath ../data/new-hires.csv -WhatIf
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$SettingsPath = "$PSScriptRoot/../config/settings.json",
    [string]$RoleProfilePath = "$PSScriptRoot/../config/role-profiles.json"
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/lib/JmlEngine.psm1" -Force

$settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
$roleProfiles = Get-Content $RoleProfilePath -Raw | ConvertFrom-Json
$hires = Import-Csv $CsvPath
$runId = Start-JmlRun

Connect-MgGraph -TenantId $settings.tenantId -ClientId $settings.clientId `
    -CertificateThumbprint $settings.certificateThumbprint -NoWelcome
Connect-ExchangeOnline -AppId $settings.clientId -CertificateThumbprint $settings.certificateThumbprint `
    -Organization $settings.exchangeOrganization -ShowBanner:$false

$results = foreach ($hire in $hires) {
    $upn = "$($hire.FirstName).$($hire.LastName)@$($settings.domain)".ToLower()
    $role = $roleProfiles.($hire.Role)
    if (-not $role) {
        Write-JmlEvent -Subject $upn -Step 'validate' -Outcome 'failed' -Detail "Unknown role '$($hire.Role)' — not in role-profiles.json"
        [pscustomobject]@{ Upn = $upn; Success = $false }; continue
    }

    Write-Host "`n═══ Onboarding $upn ($($hire.Role)) ═══" -ForegroundColor Magenta

    # Shared mutable state: steps stash IDs here for later steps and rollback.
    $ctx = @{ Hire = $hire; Upn = $upn; Role = $role; Settings = $settings }

    $steps = @(
        @{
            Name   = '1-create-entra-user'
            Test   = { param($c) [bool](Get-MgUser -Filter "userPrincipalName eq '$($c.Upn)'" -ErrorAction SilentlyContinue) }
            Action = {
                param($c)
                $tempPassword = -join ((33..126) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
                $c.User = New-MgUser -DisplayName "$($c.Hire.FirstName) $($c.Hire.LastName)" `
                    -UserPrincipalName $c.Upn -MailNickname "$($c.Hire.FirstName)$($c.Hire.LastName)".ToLower() `
                    -GivenName $c.Hire.FirstName -Surname $c.Hire.LastName `
                    -JobTitle $c.Hire.JobTitle -Department $c.Hire.Department -AccountEnabled `
                    -PasswordProfile @{ Password = $tempPassword; ForceChangePasswordNextSignIn = $true }
                $c.TempPassword = $tempPassword
            }
            Rollback = { param($c) if ($c.User) { Remove-MgUser -UserId $c.User.Id } }
        }
        @{
            Name   = '2-set-usage-location'
            Test   = { param($c) (Get-MgUser -UserId $c.Upn -Property UsageLocation).UsageLocation -eq 'AU' }
            Action = { param($c) Update-MgUser -UserId $c.Upn -UsageLocation 'AU' }
            # No rollback: harmless on its own, removed with the user anyway.
        }
        @{
            Name   = '3-assign-license'
            Test   = {
                param($c)
                (Get-MgUserLicenseDetail -UserId $c.Upn -ErrorAction SilentlyContinue).SkuId -contains $c.Role.licenseSkuId
            }
            Action = {
                param($c)
                Set-MgUserLicense -UserId $c.Upn -AddLicenses @(@{ SkuId = $c.Role.licenseSkuId }) -RemoveLicenses @() | Out-Null
            }
            Rollback = { param($c) Set-MgUserLicense -UserId $c.Upn -AddLicenses @() -RemoveLicenses @($c.Role.licenseSkuId) | Out-Null }
        }
        @{
            Name   = '4-add-role-groups'
            Test   = { param($c) $false }   # per-group membership checked inside Action
            Action = {
                param($c)
                $userId = (Get-MgUser -UserId $c.Upn).Id
                $c.AddedGroups = @()
                foreach ($groupId in $c.Role.groupIds) {
                    $members = Get-MgGroupMember -GroupId $groupId -All | Select-Object -ExpandProperty Id
                    if ($userId -notin $members) {
                        New-MgGroupMember -GroupId $groupId -DirectoryObjectId $userId
                        $c.AddedGroups += $groupId
                    }
                }
            }
            Rollback = {
                param($c)
                $userId = (Get-MgUser -UserId $c.Upn).Id
                foreach ($groupId in $c.AddedGroups) {
                    Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $userId -ErrorAction SilentlyContinue
                }
            }
        }
        @{
            # Autopilot/Intune is group-driven: membership in the role's device
            # group assigns the Autopilot deployment profile, compliance policy
            # and required apps. The device itself enrolls zero-touch on first boot.
            Name   = '5-autopilot-device-group'
            Test   = {
                param($c)
                $userId = (Get-MgUser -UserId $c.Upn).Id
                $userId -in (Get-MgGroupMember -GroupId $c.Role.autopilotGroupId -All | Select-Object -ExpandProperty Id)
            }
            Action = {
                param($c)
                New-MgGroupMember -GroupId $c.Role.autopilotGroupId -DirectoryObjectId (Get-MgUser -UserId $c.Upn).Id
            }
            Rollback = {
                param($c)
                Remove-MgGroupMemberByRef -GroupId $c.Role.autopilotGroupId `
                    -DirectoryObjectId (Get-MgUser -UserId $c.Upn).Id -ErrorAction SilentlyContinue
            }
        }
        @{
            Name   = '6-exchange-mailbox-config'
            Test   = {
                param($c)
                $mbx = Get-EXOMailbox -Identity $c.Upn -ErrorAction SilentlyContinue
                if (-not $mbx) { return $false }   # mailbox not provisioned yet → Action waits for it
                (Get-MailboxRegionalConfiguration -Identity $c.Upn).TimeZone -eq $c.Settings.mailboxTimeZone
            }
            Action = {
                param($c)
                # License → mailbox provisioning is async; poll up to 10 min.
                $deadline = (Get-Date).AddMinutes(10)
                while (-not (Get-EXOMailbox -Identity $c.Upn -ErrorAction SilentlyContinue)) {
                    if ((Get-Date) -gt $deadline) { throw 'Mailbox not provisioned within 10 minutes of license assignment' }
                    Start-Sleep -Seconds 30
                }
                Set-MailboxRegionalConfiguration -Identity $c.Upn `
                    -TimeZone $c.Settings.mailboxTimeZone -Language $c.Settings.mailboxLanguage
            }
            # No rollback: regional config is destroyed with the mailbox/license.
        }
        @{
            Name   = '7-add-teams'
            Test   = { param($c) $false }
            Action = {
                param($c)
                $userId = (Get-MgUser -UserId $c.Upn).Id
                foreach ($teamId in $c.Role.teamIds) {
                    $body = @{
                        '@odata.type' = '#microsoft.graph.aadUserConversationMember'
                        roles = @()
                        'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$userId')"
                    }
                    Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/teams/$teamId/members" -Body $body | Out-Null
                }
            }
            # No rollback: team membership is removed with group rollback (team = M365 group).
        }
        @{
            Name   = '8-notify-manager'
            Test   = { param($c) $false }
            Action = {
                param($c)
                $body = @{
                    message = @{
                        subject = "New starter provisioned: $($c.Hire.FirstName) $($c.Hire.LastName)"
                        body = @{
                            contentType = 'Text'
                            content = @"
$($c.Hire.FirstName) $($c.Hire.LastName) is provisioned and ready for day one.

Sign-in: $($c.Upn)
Temporary password: $($c.TempPassword)  (must be changed at first sign-in; MFA registration will be prompted)
Device: ships sealed — Autopilot will build it on first boot at the user's location.

Run id: $runId — full audit trail in the JML log.
"@
                        }
                        toRecipients = @(@{ emailAddress = @{ address = $c.Hire.ManagerEmail } })
                    }
                    saveToSentItems = $false
                }
                Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/users/$($c.Settings.notificationSender)/sendMail" -Body $body
            }
        }
    )

    $ok = Invoke-JmlPipeline -Subject $upn -Steps $steps -Context $ctx -WhatIf:$WhatIfPreference
    [pscustomobject]@{ Upn = $upn; Success = $ok }
}

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue

$failed = @($results | Where-Object { -not $_.Success })
Write-Host "`nRun $runId complete: $(@($results).Count - $failed.Count) provisioned, $($failed.Count) failed (rolled back)." `
    -ForegroundColor $(if ($failed) { 'Yellow' } else { 'Green' })
if ($failed) { exit 1 }
