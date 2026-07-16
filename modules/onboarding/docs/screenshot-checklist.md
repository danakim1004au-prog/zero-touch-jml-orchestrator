# Screenshot Checklist — Entra Onboarding Automation

Capture in this order. Save as `docs/img/01-...png` etc. and embed in README.

| # | Capture | Where (exact blade) |
|---|---------|---------------------|
| 01 | Terminal: `-WhatIf` dry run output | PowerShell window |
| 02 | Terminal: real onboarding run with green success lines + summary table | PowerShell window |
| 03 | New users visible in user list | entra.microsoft.com → **Identity → Users → All users** (filter: created date today) |
| 04 | One user's group memberships | All users → *alice.nguyen* → **Groups** tab |
| 05 | License assigned to user | Same user → **Licenses** tab (shows E5/SPB assigned) |
| 06 | Tenant license consumption | **Identity → Billing → Licenses → All products** (ConsumedUnits went up) |
| 07 | Terminal: offboarding run output | PowerShell window |
| 08 | Offboarded user blocked | All users → *alice.nguyen* → Overview shows **Sign-in blocked: Yes** |
| 09 | Licenses freed | Same user → Licenses tab (empty) |
| 10 | Audit trail of automation | **Identity → Monitoring & health → Audit logs** — filter Activity: "Add user", "Disable account", "Remove member from group" |

After 10/10 captured → delete test users/groups (and `rg-entra-onboarding-lab` if created).
