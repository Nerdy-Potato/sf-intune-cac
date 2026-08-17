# Age tiers

Privileges increase with age. Security requirements do not - they apply to everybody, including the
parents, because a compromised adult account is worse than a compromised child account.

| Tier | Who | Posture |
| --- | --- | --- |
| `adult` | John, Robin, Samantha | Security only. |
| `teen` | Lucas, Adalynn | Security, plus light content controls. Apps are blocklisted, not allowlisted. |
| `child` | Cullen, Emmerick, Broderick | Strictest. Corporate-owned devices, approved apps only, forced GSA, tight web and media controls. |
| `admin` | johnspaid | Administrative account. No productivity workloads. |
| `excluded` | mauricemoss, robertjohnson | Break-glass. Excluded from everything by design. |

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

Each tier also has a corresponding manually managed device group: `CaC-Devices-Adult`,
`CaC-Devices-Teen`, and `CaC-Devices-Child`. The repository creates these groups but does not alter
their device membership.
