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
`CaC-Devices-Child`. The repository creates these groups, but the normal plan/apply reconciliation
loop deliberately never manages their device membership (`Get-CaCConfiguration` always reports an
empty desired member list for a `memberType: device` group) - config-as-code has no signal for
*which physical device* belongs to *which person*.

That gap used to mean a human had to remember to add every newly enrolled device to its tier's
device group by hand, and a missed step meant device-scoped policies assigned to that group (most
importantly local-admin and Windows LAPS) silently never applied. The **Sync device tier groups**
workflow (`.github/workflows/sync-device-tier-groups.yml`, backed by
`scripts/bootstrap/Sync-CaCDeviceTierGroups.ps1`) now closes that gap on its own schedule: it reads
each enrolled Windows device's primary user, looks up that user's tier from
`config/identity/users.json`, and adds the device to the matching group if it is not already a
member. It only adds - if a device ends up in the wrong tier's group (for example, after a birthday
moves someone up a tier) it is reported as a conflict for manual review, never auto-removed.
