# Age tiers

Privileges increase with age. Security requirements do not - they apply to everybody, including the
parents, because a compromised adult account is worse than a compromised child account.

| Tier | Who | Posture |
| --- | --- | --- |
| `adult` | John, Robin, Samantha | Security only. |
| `teen` | Lucas, Adalynn | Security, plus light content controls. Apps are blocklisted, not allowlisted. |
| `child` | Cullen, Emmerick, Broderick | Strictest. Corporate-owned devices, approved apps only, forced GSA, tight web and media controls. |
| `admin` | johnspaid | Administrative account. No productivity workloads. |
| `excluded` | mauricemoss, bobjohnson | Break-glass. Excluded from everything by design. |

The difference between tiers is visible in the policies themselves - for example
`windows-restrictions-child` blocks the Microsoft Store so that software can only arrive through an
explicitly approved Intune app assignment, while `windows-restrictions-teen` allows it and keeps
only the security-relevant settings. Teens can also install apps from outside the Store: SmartScreen
app install control ("Microsoft Store only") is off and trusted-app sideloading is left unconfigured,
while SmartScreen still warns on unrecognised downloads.

## No ages are stored

`config/identity/users.json` records a *tier*, never a date of birth or an age. Ages change, this
repository is public history, and none of the policy decisions need more precision than the tier.

## Unconfirmed tiers default to the strictest fit

The tenant owner confirmed the current Child, Teen, and Adult placements. Any future unconfirmed child is
marked `"ageTierConfirmed": false` and placed in the **most restrictive** tier that could apply (`child`).

This is deliberate. If the placement is wrong, the failure mode is a teenager complaining that the
Store is blocked - not a 12 year old with an unrestricted device. Validation raises a warning for
every unconfirmed account so the gap stays visible in every pull request and never quietly becomes
permanent.

No tier confirmations are currently pending.

## Changing somebody's recorded tier

The `tier` in `config/identity/users.json` is account metadata. The repository does not manage live
membership of `CaC-Tier-Adult`, `CaC-Tier-Teen`, or `CaC-Tier-Child`; those groups are maintained
manually in Entra. Changing a record here does not add or remove anyone from those groups or change
which tier policies apply to them.

1. Edit that person's `tier` in `config/identity/users.json` (and set `ageTierConfirmed` to `true`)
   to keep the repository's account metadata accurate.
2. Manage any corresponding live tier-group membership separately in Entra using the tenant's
   approved manual process. Review the policy changes that membership causes before relying on
   them.

The config-as-code planner may still manage these group objects and their policy assignment
references, but it neither reads nor reconciles their membership. Changes to `users.json` alone
therefore cannot change live tier-group membership.

The child tier also owns an explicit app catalog. Defender, authentication, and the approved Microsoft
365 apps are required; Edge remains available for self-service installation. Adding any other app is
a reviewed change to `config/apps/approved-child-apps.json`.

Each tier also has a corresponding device group: `CaC-Devices-Adult`, `CaC-Devices-Teen`, and
`CaC-Devices-Child`. The normal plan/apply reconciliation loop deliberately never manages their
device membership (`Get-CaCConfiguration` always reports an empty desired member list for a
`memberType: device` group) - config-as-code has no signal for *which physical device* belongs to
*which person*.

These three groups are **dynamic groups**, keyed on the Entra device object's
`extensionAttribute1`, which an administrator sets explicitly on each device:

| Tier  | Group               | Required `extensionAttribute1` | Membership rule |
| ----- | ------------------- | ------------------------------ | --------------- |
| Adult | `CaC-Devices-Adult` | `Adult` | `(device.extensionAttribute1 -eq "Adult")` |
| Teen  | `CaC-Devices-Teen`  | `Teen`  | `(device.extensionAttribute1 -eq "Teen")` |
| Child | `CaC-Devices-Child` | `Child` | `(device.extensionAttribute1 -eq "Child")` |

The rules carry no operating system condition, so an Android corporate-owned child device is
covered by exactly the same mechanism as a Windows one. That matters: `CaC-Devices-Child` is what
the Android corporate-owned enrollment restriction and the Defender/Global Secure Access app
configuration target.

## Tagging a device

Tagging is a manual, administrator-run step for **every** newly enrolled device. Nothing in this
repository infers a device's tier from its enrolling user, and there is no enrollment-time hook that
tags a device automatically:

```powershell
gh workflow run set-device-tier-tag.yml `
  -f device_object_id='<entra-device-object-id>' `
  -f tier='Child' `
  -f confirm=true
```

(or run `scripts/bootstrap/Set-CaCDeviceTierTag.ps1` directly with Graph access.)

The input is the **Entra device object ID** - not the Intune managed device ID, not `deviceId`, not
a serial number, and not the user who signs in on it. The script refuses to overwrite a device that
already carries a different tag unless `-AllowTierChange` (workflow input `allow_tier_change`) is
passed, and it re-reads the device after the write to confirm the tag landed.

Two consequences are worth stating plainly:

- An untagged device is in no tier device group at all, so every device-scoped policy assigned to
  those groups - Windows LAPS, the tier restrictions, the child Android restrictions, and the
  Defender/GSA app configuration - simply never applies to it. Tag the device before assuming it is
  protected.
- Entra evaluates dynamic membership asynchronously. A successful tag write means the attribute is
  set, not that the device is already a member. Check the group itself before relying on a policy.

`extensionAttribute1` was confirmed empirically unused across the tenant's existing device objects
before it was adopted for this, so tagging cannot collide with an existing use of the slot. That
stays true by enforcement, not by assumption: if a device's `extensionAttribute1` holds any value
that is not exactly `Adult`, `Teen`, or `Child`, the setter refuses to touch it and `-AllowTierChange`
does not override that. The switch only permits one known tier to replace another. Clearing a
foreign value is a deliberate decision to make outside this script.

## Migrating the original assigned groups

The three groups started out as assigned (explicit-membership) groups.
`scripts/bootstrap/Convert-CaCDeviceTierGroupsToDynamic.ps1` - and the
**Convert device tier groups to dynamic** workflow - converts them **in place**. It preflights all
three groups together, reading every existing member, its current tag, and any conflicting tag;
stamps `extensionAttribute1` from the existing static membership; verifies each write by reading it
back; and only then `PATCH`es the groups with their dynamic rules. It never deletes or recreates a
group, so the object IDs - and therefore every existing policy assignment - survive the conversion.

## Local administrator rights

Local administrator rights for adults and teens are **not** granted by making an adult/teen group
administrator on every device in the tier, and not by a proactive remediation script deployed to a
tier. Windows Autopilot and Autopilot device preparation set **User account type = Administrator**
for the adult and teen profiles, which adds only the user joining that device to that device's local
Administrators group. Child deployment remains standard-user. See
[`enterprise-child-enrollment.md`](enterprise-child-enrollment.md) for the Entra device-join
setting that scopes this.