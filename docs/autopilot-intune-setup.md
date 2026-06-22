# Autopilot + Intune setup (the device half of zero-touch)

The orchestrator's step 5 only adds the user to a device-assignment group. This doc is the one-time tenant setup that makes that membership *mean something*: a sealed laptop that builds itself on first boot.

## 1. MDM auto-enrollment

Entra admin center → Mobility (MDM/WPS) → Microsoft Intune → **MDM user scope: All** (or the Autopilot groups). This is what enrolls the device into Intune automatically during Entra join — no scope, no zero-touch.

## 2. Autopilot deployment profile

Intune admin center → Devices → Enrollment → Windows Autopilot → **Deployment profiles → Create**:

- Deployment mode: **User-Driven**, Entra joined
- Out-of-box experience: hide EULA, hide privacy settings, user account type **Standard** (admins are a CA/PIM story, not a default)
- Apply device name template: `CONTOSO-%SERIAL%`
- **Assign to**: the role's Autopilot group (e.g. `SG-Autopilot-Engineering`)

## 3. Enrollment Status Page (ESP)

Enrollment → Enrollment Status Page → Create: **block device use until required apps install**, timeout 60 min, assign to the same groups. ESP is what guarantees the device is compliant *before* the user ever reaches the desktop — skip it and "zero-touch" becomes "zero-touch but call the helpdesk about missing Outlook."

## 4. Compliance policy + app assignments

Both assigned to the role Autopilot groups, so step 5 of the orchestrator cascades into everything:

- Compliance: BitLocker required, Defender on, minimum OS version, password/PIN policy. Mark device **noncompliant after 1 day** grace.
- Apps (required): M365 Apps, Company Portal, role-specific apps per group.
- Conditional Access ties it together: *Require compliant device* for M365 access (see [`conditional-access-lab`](../../conditional-access-lab)).

## 5. Hardware hash registration

For lab/demo (no OEM integration): on the reference VM —

```powershell
Install-Script Get-WindowsAutopilotInfo -Force
Get-WindowsAutopilotInfo -Online   # uploads hash straight to the tenant (needs Intune admin)
```

In production the supplier registers hashes against your tenant at purchase — that's what makes it genuinely zero-IT-touch.

## 6. Demo flow (for screenshots)

1. Run `Invoke-JmlOnboarding.ps1` for a test hire → user lands in `SG-Autopilot-Engineering`.
2. Reset the lab VM (or boot a fresh one whose hash is registered).
3. OOBE shows the company branding → test user signs in → ESP installs policy + apps → desktop is BitLocker'd, compliant, and CA lets it into M365.
4. Time it. That number ("4 hours of manual build → ~30 min unattended") is the resume line.
