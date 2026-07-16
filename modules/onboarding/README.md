# Entra ID Onboarding / Offboarding Automation

PowerShell + Microsoft Graph automation for the full identity lifecycle of an employee: CSV-driven account creation, group assignment and license allocation on day one — and a hardened, ordered leaver sequence (disable → revoke sessions → strip licenses → strip groups) on exit.

## Purpose

Joiner/Mover/Leaver (JML) automation is the bread-and-butter ticket type at every MSP service desk. This project replaces ~15 minutes of error-prone portal clicking per user with an idempotent, auditable script run, and shows the security-correct offboarding order (block sign-in **before** revoking tokens, so nothing re-authenticates mid-offboard).

## Architecture

```
 new-hires.csv ──▶ New-EmployeeOnboarding.ps1 ──▶ Microsoft Graph API ──▶ Entra ID
                     │  • create user (temp pwd, force change)              │
                     │  • usage location AU → license assign                │
                     │  • group memberships                                 ▼
                     └──▶ run log CSV (audit)                        Audit logs blade

 UPN(s) ─────────▶ Start-EmployeeOffboarding.ps1 ──▶ Graph ──▶ disable ▸ revoke ▸
                     └──▶ offboarding record CSV               unlicense ▸ ungroup
```

## Tech stack

- PowerShell 7 · Microsoft.Graph PowerShell SDK
- Microsoft Entra ID (M365 Developer/E5 or Business Premium trial tenant)
- Graph scopes: `User.ReadWrite.All`, `Group.ReadWrite.All`, `Directory.ReadWrite.All`, `Organization.Read.All`

## Repo structure

```
entra-onboarding-automation/
├── README.md
├── data/
│   └── new-hires.sample.csv        # input schema with 3 sample hires
├── docs/
│   ├── implementation-guide.md     # step-by-step lab build
│   ├── screenshot-checklist.md     # 10 ordered portal captures
│   └── img/                        # screenshots (added after lab run)
└── scripts/
    ├── New-EmployeeOnboarding.ps1  # joiner: create / group / license
    └── Start-EmployeeOffboarding.ps1  # leaver: disable / revoke / strip
```

## Implementation summary

1. Created four security groups (`SG-AllStaff` + 3 departments) in the dev tenant.
2. Onboarded three users from CSV — accounts created with forced password change, usage location `AU`, group membership and an E5 seat assigned, all in one run with a `-WhatIf` dry-run first.
3. Offboarded one user and verified each control: sign-in blocked, refresh tokens revoked, license seat returned to pool, group memberships removed.
4. Validated the whole run is traceable in **Entra audit logs** — every action attributable to the operator account.

## What this demonstrates

- Graph SDK scripting with idempotency (`-WhatIf`, skip-if-exists), error handling and run logging
- Understanding of license mechanics (usage location prerequisite, seat availability checks, SKU translation)
- Dynamic vs. assigned group membership awareness
- Security-correct leaver order and token revocation latency (≤ 1 h propagation)

## Azure resources & cost

| Item | Detail |
|---|---|
| Resource Group | None required (Entra ID is tenant-level). Optional: `rg-entra-onboarding-lab` for an Automation Account (free tier, 500 min/month included) if demonstrating unattended runbook execution |
| Cost | **$0** on a dev/trial tenant. Automation Account free-tier minutes cover the optional step |

## Relevance to Australian MSP / Azure support roles

User onboarding/offboarding is the single highest-volume request type in AU MSP service catalogues, and incomplete offboarding is a recurring finding in Essential Eight maturity assessments (restricting admin privileges, revoking access on termination). This project maps directly to L1/L2 service desk automation, and the audit-log evidence habit mirrors how MSPs prove change tickets were actioned.

## Suggested commit message

```
feat: add Graph API onboarding/offboarding automation scripts
```
