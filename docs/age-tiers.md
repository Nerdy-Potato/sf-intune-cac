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
only the security-relevant settings.

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

## Moving somebody up a tier

Birthdays are a normal, reviewed change:

1. Edit that person's `tier` in `config/identity/users.json` (and set `ageTierConfirmed` to `true`).
2. Open a pull request. The plan will show them being removed from one group and added to another.
3. Review what that actually unlocks - the group change is one line, but it can move a device from
   the child restriction profile to the teen one. Read the whole plan, not just the membership diff.
4. Merge, approve the deployment.

Nothing else needs editing. Group membership is calculated from the tier, so the tier is the only
place that knowledge lives.

The child tier also owns an explicit app catalog. Defender, authentication, and the approved Microsoft
365 apps are required; Edge remains available for self-service installation. Adding any other app is
a reviewed change to `config/apps/approved-child-apps.json`.

Each tier also has a corresponding device group: `CaC-Devices-Adult`, `CaC-Devices-Teen`, and
`CaC-Devices-Child`. The normal plan/apply reconciliation loop deliberately never manages their
device membership (`Get-CaCConfiguration` always reports an empty desired member list for a
`memberType: device` group) - config-as-code has no signal for *which physical device* belongs to
*which person*.

That gap used to mean a human had to remember to add every newly enrolled device to its tier's
device group by hand, and a missed step meant device-scoped policies assigned to that group (most
importantly Windows LAPS and tier-specific restrictions) silently never applied. These three groups are now
**dynamic groups**, keyed on each device's Windows Autopilot Group Tag (Entra's `OrderID` device
physical id), so Entra ID maintains their membership itself - continuously, with no repository
code, workflow, or schedule involved:

| Tier  | Group              | Required Windows Autopilot Group Tag |
| ----- | ------------------ | ------------------------------------- |
| Adult | `CaC-Devices-Adult` | `CaC-Adult` |
| Teen  | `CaC-Devices-Teen`  | `CaC-Teen`  |
| Child | `CaC-Devices-Child` | `CaC-Child` |

Set the Group Tag when a device is hardware-hash registered with Autopilot (the CSV/portal import
already has a Group Tag column - see [`enterprise-child-enrollment.md`](enterprise-child-enrollment.md)).
For a device that was registered without a tag, or needs to move tiers, run
`scripts/bootstrap/Set-CaCAutopilotGroupTag.ps1` (or the **Set Autopilot Group Tag** workflow) to
correct it after the fact; Entra re-evaluates group membership automatically once the tag changes.

Local administrator rights for adults and teens are **not** granted by making an adult/teen group
administrator on every device in the tier. For Windows Autopilot, the adult and teen deployment
profiles use **User account type = Administrator**, which adds only the user joining that device to
that device's local Administrators group. Child deployment remains standard-user.

Group Tag dynamic rules are a **Windows Autopilot-only** mechanism. `CaC-Devices-Child` is also
targeted by the Android corporate-owned enrollment restriction policy
(`android-fully-managed-restrictions-child.json`), and Android devices have no Autopilot Group
Tag to match on - those still need to be added to `CaC-Devices-Child` by hand in the portal after
enrollment.

These three groups were migrated from assigned (explicit-membership) to dynamic groups by a
one-time bootstrap operation, because Graph does not allow converting an existing group's
membership type in place - see `scripts/bootstrap/Convert-CaCDeviceTierGroupsToDynamic.ps1` for
the mechanics and rollback caveats if this ever needs to be redone (for example, in a fresh
tenant).
