<#
.SYNOPSIS
    Onboards new employees into Microsoft Entra ID from a CSV file.

.DESCRIPTION
    For each row in the input CSV this script:
      1. Creates the Entra ID user account (with a generated temporary password)
      2. Sets the usage location (required before license assignment)
      3. Adds the user to the security/M365 groups listed in the CSV
      4. Assigns the license SKU listed in the CSV (e.g. DEVELOPERPACK_E5)

    Authentication uses the Microsoft Graph PowerShell SDK (delegated or
    app-only). Required Graph scopes:
      User.ReadWrite.All, Group.ReadWrite.All, Organization.Read.All

.PARAMETER CsvPath
    Path to the new-hire CSV. See data/new-hires.sample.csv for the schema:
    DisplayName,FirstName,LastName,UserPrincipalName,Department,JobTitle,Groups,LicenseSku
    (Groups is a semicolon-separated list of group display names.)

.PARAMETER UsageLocation
    Two-letter ISO country code stamped on every user. Defaults to AU
    (Australia) — license assignment fails without a usage location.

.EXAMPLE
    .\New-EmployeeOnboarding.ps1 -CsvPath ..\data\new-hires.sample.csv -WhatIf

.EXAMPLE
    .\New-EmployeeOnboarding.ps1 -CsvPath ..\data\new-hires.csv

.NOTES
    Author : Dana Kim
    Module : Microsoft.Graph (Install-Module Microsoft.Graph -Scope CurrentUser)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$CsvPath,

    [ValidatePattern('^[A-Z]{2}$')]
    [string]$UsageLocation = 'AU'
)

#region Connect
$requiredScopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Organization.Read.All')
$context = Get-MgContext
if (-not $context -or ($requiredScopes | Where-Object { $_ -notin $context.Scopes })) {
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
}
#endregion

#region Helpers
function New-TemporaryPassword {
    # 16 chars, guaranteed upper/lower/digit/symbol to satisfy default password policy
    $sets = @(
        [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ',
        [char[]]'abcdefghijkmnpqrstuvwxyz',
        [char[]]'23456789',
        [char[]]'!@#$%&*'
    )
    $chars = foreach ($set in $sets) { $set | Get-Random -Count 4 }
    -join ($chars | Sort-Object { Get-Random })
}

# Cache tenant SKUs once so we can translate SkuPartNumber -> SkuId
$tenantSkus = Get-MgSubscribedSku -All
#endregion

$results = @()
$hires = Import-Csv -Path $CsvPath

foreach ($hire in $hires) {
    $upn = $hire.UserPrincipalName
    Write-Host "Processing $upn ..." -ForegroundColor Cyan

    # Skip if the account already exists (idempotent re-runs)
    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "  $upn already exists - skipping creation."
        $results += [pscustomobject]@{ User = $upn; Status = 'Skipped (exists)' }
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($upn, 'Create user, assign groups and license')) { continue }

    try {
        # --- 1. Create the account -------------------------------------------------
        $tempPassword = New-TemporaryPassword
        $userParams = @{
            DisplayName       = $hire.DisplayName
            GivenName         = $hire.FirstName
            Surname           = $hire.LastName
            UserPrincipalName = $upn
            MailNickname      = ($upn -split '@')[0]
            Department        = $hire.Department
            JobTitle          = $hire.JobTitle
            UsageLocation     = $UsageLocation
            AccountEnabled    = $true
            PasswordProfile   = @{
                Password                      = $tempPassword
                ForceChangePasswordNextSignIn = $true
            }
        }
        $user = New-MgUser @userParams
        Write-Host "  Created account ($($user.Id))" -ForegroundColor Green

        # --- 2. Group memberships ----------------------------------------------------
        foreach ($groupName in ($hire.Groups -split ';' | Where-Object { $_ })) {
            $group = Get-MgGroup -Filter "displayName eq '$($groupName.Trim())'"
            if (-not $group) {
                Write-Warning "  Group '$groupName' not found - skipped."
                continue
            }
            New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id
            Write-Host "  Added to group: $groupName" -ForegroundColor Green
        }

        # --- 3. License assignment ---------------------------------------------------
        if ($hire.LicenseSku) {
            $sku = $tenantSkus | Where-Object SkuPartNumber -eq $hire.LicenseSku
            if (-not $sku) {
                Write-Warning "  SKU '$($hire.LicenseSku)' not found in tenant - license skipped."
            }
            elseif (($sku.PrepaidUnits.Enabled - $sku.ConsumedUnits) -lt 1) {
                Write-Warning "  SKU '$($hire.LicenseSku)' has no free seats - license skipped."
            }
            else {
                Set-MgUserLicense -UserId $user.Id `
                    -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @()
                Write-Host "  Assigned license: $($hire.LicenseSku)" -ForegroundColor Green
            }
        }

        $results += [pscustomobject]@{
            User         = $upn
            Status       = 'Onboarded'
            TempPassword = $tempPassword   # hand to service desk via secure channel
        }
    }
    catch {
        Write-Error "  Failed for $upn : $_"
        $results += [pscustomobject]@{ User = $upn; Status = "Failed: $($_.Exception.Message)" }
    }
}

# Summary table + audit artifact for the run
$results | Format-Table -AutoSize
$logPath = Join-Path $PSScriptRoot "onboarding-run-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $logPath -NoTypeInformation
Write-Host "Run log written to $logPath"
