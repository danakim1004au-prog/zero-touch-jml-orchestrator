# Zero-Touch JML Orchestrator

End-to-end joiner/mover/leaver automation built as a **step pipeline with rollback**: Entra ID account → license → groups → Intune/Autopilot device enrollment groups → Exchange Online mailbox config → Teams membership, each step logged, retried, and reversible. If step 6 of 8 fails, the orchestrator unwinds the completed steps in reverse order instead of leaving a half-provisioned ghost account.

> Sibling project: [`entra-onboarding-automation`](../entra-onboarding-automation) is the straightforward script version (create → license → group). This project is the production-shaped version of the same problem: orchestration engine, idempotency, rollback, structured logging, and the device layer (Autopilot/Intune) that makes onboarding genuinely *zero-touch* — the laptop ships sealed from the supplier and builds itself at the user's kitchen table.

## Purpose

Australian MSP job ads treat "Autopilot + Intune zero-touch provisioning" as near non-negotiable. The hard part isn't calling the APIs — it's what happens when call 6 of 8 fails at 5pm on a Friday. This project's value is the failure engineering: every step declares its own rollback, every run writes a JSONL audit trail, and re-running a half-finished user is safe because every step checks state before acting (idempotency).

## Architecture

```
new-hires.csv ──▶ Invoke-JmlOnboarding.ps1
                      │
                      ▼
              JmlEngine.psm1  ── Invoke-JmlPipeline ──────────────────────────┐
                      │   for each step:                                       │
                      │     1. Test  (already done? → skip, idempotent)        │
                      │     2. Action (with retry on throttling/429)           │
                      │     3. push rollback onto stack                        │
                      │   on failure: pop & run rollback stack in reverse      │
                      ▼                                                        ▼
   ┌──────────────────────────── onboarding steps ─────────────────┐   logs/jml-<run>.jsonl
   │ 1 Create Entra user (temp pwd, force change at sign-in)       │   (one JSON event per
   │ 2 Set usage location (AU) — license prerequisite              │    step: ts, user, step,
   │ 3 Assign license from SKU map                                 │    outcome, error, ms)
   │ 4 Add security/M365 groups from role profile                  │
   │ 5 Add Autopilot device-assignment group → Intune profiles,    │
   │   compliance policy, apps all flow from group membership      │
   │ 6 Exchange Online: timezone, language, email-address policy   │
   │ 7 Teams: add to role-profile teams                            │
   │ 8 Send welcome sheet to manager (Graph sendMail)              │
   └───────────────────────────────────────────────────────────────┘

offboard-request ──▶ Invoke-JmlOffboarding.ps1   (ordered for security, no rollback —
                      1 Disable sign-in            leavers are not unwound)
                      2 Revoke refresh tokens
                      3 Remove from all groups (capture list to record file)
                      4 Convert mailbox to shared (preserves mail, frees the license)
                      5 Remove licenses
                      6 Intune: retire corporate devices
                      7 Set OneDrive manager access (note for Purview retention)
                      8 Write leaver record JSON (what was removed — re-hire insurance)
```

## Why the order matters (offboarding)

Disable **before** revoke: a revoked token can be re-acquired in seconds if the account can still sign in. Convert-to-shared **before** unlicensing: dropping the license first puts the mailbox in a 30-day soft-delete countdown. These orderings are the difference between "ran some commands" and "understands identity lifecycle."

## Tech stack

- PowerShell 7 · Microsoft Graph PowerShell SDK · ExchangeOnlineManagement (cert app-only for both)
- Microsoft Intune + Windows Autopilot (group-driven profile assignment)
- Role profiles as JSON (`config/role-profiles.json`) — sales hire vs engineer hire = one input field
- Graph scopes: `User.ReadWrite.All`, `Group.ReadWrite.All`, `DeviceManagementManagedDevices.PrivilegedOperations.All`, `Mail.Send`; EXO: `Exchange.ManageAsApp` + Exchange Recipient Management role

## Repo structure

```
zero-touch-jml-orchestrator/
├── README.md
├── .gitignore
├── orchestrator/
│   ├── lib/JmlEngine.psm1            # pipeline engine: steps, retry, rollback, JSONL log
│   ├── Invoke-JmlOnboarding.ps1      # CSV in → 8-step pipeline per user
│   └── Invoke-JmlOffboarding.ps1     # UPN(s) in → ordered leaver sequence
├── config/
│   ├── role-profiles.sample.json     # role → groups, teams, license SKU, autopilot group
│   └── settings.sample.json          # tenant/app/cert, org defaults
├── data/
│   └── new-hires.sample.csv
└── docs/
    ├── autopilot-intune-setup.md     # the device half: Autopilot profile, enrollment, ESP
    └── screenshot-checklist.md
```

## Quick start

```powershell
Install-Module Microsoft.Graph, ExchangeOnlineManagement -Scope CurrentUser
Copy-Item config/settings.sample.json config/settings.json          # fill in
Copy-Item config/role-profiles.sample.json config/role-profiles.json

# Dry run first — prints the step plan per user, touches nothing
./orchestrator/Invoke-JmlOnboarding.ps1 -CsvPath data/new-hires.csv -WhatIf

./orchestrator/Invoke-JmlOnboarding.ps1 -CsvPath data/new-hires.csv
./orchestrator/Invoke-JmlOffboarding.ps1 -UserPrincipalName leaver@contoso.com
```

## Resume-ready outcome line

> Designed a zero-touch provisioning workflow with Autopilot and Intune orchestrated by a PowerShell pipeline engine with per-step rollback and JSONL audit logging, reducing new-starter setup from ~4 hours of portal work to a 30-minute unattended run.
