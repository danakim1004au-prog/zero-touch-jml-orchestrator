<#
.SYNOPSIS
    Securely offboards an employee from Microsoft Entra ID.

.DESCRIPTION
    Executes the standard leaver sequence in the order recommended by
    Microsoft for compromised/terminated accounts:
      1. Disable the account                (blocks new sign-ins)
      2. Revoke all refresh/session tokens  (kills existing sessions)
      3. Remove all directly-assigned licenses (frees paid seats)
      4. Remove all group memberships       (cuts resource access)
      5. Write an offboarding record (CSV) for audit/ticket attachment

    Required Graph scopes:
      User.ReadWrite.All, Group.ReadWrite.All, Directory.ReadWrite.All

.PARAMETER UserPrincipalName
    UPN(s) of the user(s) to offboard. Accepts pipeline input.

.PARAMETER KeepGroups
    Skip group removal (e.g. when access must persist during a notice period).

.EXAMPLE
    .\Start-EmployeeOffboarding.ps1 -UserPrincipalName jane.doe@contoso.com -WhatIf

.EXAMPLE
    'a@x.com','b@x.com' | .\Start-EmployeeOffboarding.ps1

.NOTES
    Dynamic group memberships cannot be removed manually - the script
    detects and reports them instead of failing.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string[]]$UserPrincipalName,

    [switch]$KeepGroups
)

begin {
    $requiredScopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.ReadWrite.All')
    $context = Get-MgContext
    if (-not $context -or ($requiredScopes | Where-Object { $_ -notin $context.Scopes })) {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }
    $records = @()
}

process {
    foreach ($upn in $UserPrincipalName) {
        $user = Get-MgUser -Filter "userPrincipalName eq '$upn'" `
            -Property Id, DisplayName, UserPrincipalName, AccountEnabled, AssignedLicenses
        if (-not $user) {
            Write-Error "User $upn not found."
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($upn, 'Disable, revoke sessions, strip licenses and groups')) {
            continue
        }

        Write-Host "Offboarding $($user.DisplayName) <$upn>" -ForegroundColor Cyan

        # 1. Disable account FIRST so nothing new can authenticate
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
        Write-Host '  [1/4] Account disabled' -ForegroundColor Green

        # 2. Revoke refresh tokens - forces re-auth on all devices within ~1 hour
        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        Write-Host '  [2/4] Sign-in sessions revoked' -ForegroundColor Green

        # 3. Remove every directly-assigned license
        $skusRemoved = @()
        if ($user.AssignedLicenses) {
            $skuIds = $user.AssignedLicenses.SkuId
            Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skuIds | Out-Null
            $skusRemoved = $skuIds
            Write-Host "  [3/4] Removed $($skuIds.Count) license(s)" -ForegroundColor Green
        }
        else {
            Write-Host '  [3/4] No direct licenses to remove' -ForegroundColor Yellow
        }

        # 4. Remove group memberships (security + M365; skips dynamic groups)
        $groupsRemoved = @()
        if (-not $KeepGroups) {
            $groups = Get-MgUserMemberOf -UserId $user.Id -All |
                Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }
            foreach ($g in $groups) {
                $isDynamic = $g.AdditionalProperties['groupTypes'] -contains 'DynamicMembership'
                if ($isDynamic) {
                    Write-Warning "  Dynamic group '$($g.AdditionalProperties.displayName)' - membership is rule-based, cannot remove manually."
                    continue
                }
                try {
                    Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id
                    $groupsRemoved += $g.AdditionalProperties.displayName
                }
                catch {
                    Write-Warning "  Could not remove from '$($g.AdditionalProperties.displayName)': $_"
                }
            }
            Write-Host "  [4/4] Removed from $($groupsRemoved.Count) group(s)" -ForegroundColor Green
        }
        else {
            Write-Host '  [4/4] Group removal skipped (-KeepGroups)' -ForegroundColor Yellow
        }

        $records += [pscustomobject]@{
            Timestamp       = (Get-Date -Format 'o')
            User            = $upn
            AccountDisabled = $true
            SessionsRevoked = $true
            LicensesRemoved = ($skusRemoved -join ';')
            GroupsRemoved   = ($groupsRemoved -join ';')
            OperatorUpn     = (Get-MgContext).Account
        }
    }
}

end {
    if ($records) {
        $logPath = Join-Path $PSScriptRoot "offboarding-run-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $records | Export-Csv -Path $logPath -NoTypeInformation
        $records | Format-Table -AutoSize
        Write-Host "Audit record written to $logPath"
    }
}
