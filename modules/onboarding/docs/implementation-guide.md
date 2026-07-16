# Implementation Guide — Entra ID Onboarding/Offboarding Automation

## Prerequisites

1. **Tenant**: M365 Developer Tenant (E5) or any tenant where you hold *User Administrator* + *Groups Administrator* (or Global Admin in a lab).
   > Note (2026): the free M365 Developer Program now requires a Visual Studio Enterprise subscription. If you don't have one, use a **Microsoft 365 Business Premium 30-day trial** or an **E5 trial** instead — everything in this lab works the same.
2. **Workstation**: PowerShell 7.x and the Graph SDK:
   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser
   ```
3. **Azure Resource Group**: *none strictly required* — Entra ID objects are tenant-level, not resource-group-level. Create `rg-entra-onboarding-lab` **only** if you do the optional Automation Account step (Step 8) so everything is one-click deletable.

## Steps

1. **Prepare test groups** in Entra admin center (entra.microsoft.com) → *Groups* → *New group*. Create four security groups: `SG-AllStaff`, `SG-Finance`, `SG-Operations`, `SG-HR`.
2. **Confirm available license SKU**:
   ```powershell
   Connect-MgGraph -Scopes Organization.Read.All
   Get-MgSubscribedSku | Select SkuPartNumber, ConsumedUnits -ExpandProperty PrepaidUnits
   ```
   Put the `SkuPartNumber` you see (e.g. `DEVELOPERPACK_E5`, `SPB` for Business Premium) into the CSV's `LicenseSku` column.
3. **Edit the CSV**: copy `data/new-hires.sample.csv` → `data/new-hires.csv`, replace `YOURTENANT` with your tenant domain.
4. **Dry run** (nothing is changed):
   ```powershell
   cd scripts
   .\New-EmployeeOnboarding.ps1 -CsvPath ..\data\new-hires.csv -WhatIf
   ```
5. **Onboard for real** — drop `-WhatIf`. Verify in the portal (see screenshot checklist) that the 3 users exist, hold group memberships and a license.
6. **Offboard one user**:
   ```powershell
   .\Start-EmployeeOffboarding.ps1 -UserPrincipalName alice.nguyen@YOURTENANT.onmicrosoft.com
   ```
   Confirm in the portal: account disabled (sign-in blocked), licenses freed, groups empty, and *Audit logs* show "Disable account", "Update user", "Remove member from group" entries performed by your admin account.
7. **Capture screenshots** per `screenshot-checklist.md`.
8. **(Optional) Scheduled execution**: create `rg-entra-onboarding-lab` → Automation Account (Free tier) → import the onboarding script as a PowerShell 7.2 runbook using a managed identity granted `User.ReadWrite.All` app role. This demonstrates unattended/app-only auth, a common MSP pattern. Delete the RG afterwards.
9. **Clean up**: delete the three test users, the four groups, and (if created) `rg-entra-onboarding-lab`.

## Troubleshooting notes worth documenting in your repo

| Symptom | Cause / Fix |
|---|---|
| `Set-MgUserLicense` → "license assignment failed" | `UsageLocation` not set — the script sets `AU` by default |
| User creation OK but group add fails | Group is **dynamic** — membership is rule-driven; scripts detect and warn |
| Sessions still alive after revocation | Token revocation propagates in up to 1 hour; access tokens live ≤ 60–90 min by design |
