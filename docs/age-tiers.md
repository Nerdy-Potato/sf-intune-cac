# Age tiers

Privileges increase with age. Security requirements do not - they apply to everybody, including the
parents, because a compromised adult account is worse than a compromised child account.

| Tier | Who | Posture |
| --- | --- | --- |
| `adult` | John, Robin | Security only. No content or app restrictions. First Windows update ring. |
| `young-adult` | Samantha (18) | Security only. Deliberately has **no** restriction policy assigned. |
| `teen` | 14-17 | Security, plus light content controls. Apps are blocklisted, not allowlisted. |
| `child` | 13 and under (Lucas) | Strictest. Store blocked, approved apps only, tight web and media controls. |
| `admin` | johnspaid | Administrative account. No productivity workloads. |
| `excluded` | mauricemoss, robertjohnson | Break-glass. Excluded from everything by design. |

The difference between tiers is visible in the policies themselves - for example
`windows-restrictions-child` blocks the Microsoft Store so that software can only arrive through an
explicitly approved Intune app assignment, while `windows-restrictions-teen` allows it and keeps
only the security-relevant settings. `young-adult` has no restriction policy at all; the compliance
and app protection baselines still apply.

## No ages are stored

`config/identity/users.json` records a *tier*, never a date of birth or an age. Ages change, this
repository is public history, and none of the policy decisions need more precision than the tier.

## Unconfirmed tiers default to the strictest fit

Only two ages were stated by the tenant owner: Samantha is 18 and Lucas is 13. Every other child is
marked `"ageTierConfirmed": false` and placed in the **most restrictive** tier that could apply
(`child`).

This is deliberate. If the placement is wrong, the failure mode is a teenager complaining that the
Store is blocked - not a 12 year old with an unrestricted device. Validation raises a warning for
every unconfirmed account so the gap stays visible in every pull request and never quietly becomes
permanent.

> **Action required:** confirm the tiers for Adalynn, Emmerick, Broderick and Cullen and move them
> in the same way as any other change - one pull request, reviewed plan.

## Moving somebody up a tier

Birthdays are a normal, reviewed change:

1. Edit that person's `tier` in `config/identity/users.json` (and set `ageTierConfirmed` to `true`).
2. Open a pull request. The plan will show them being removed from one group and added to another.
3. Review what that actually unlocks - the group change is one line, but it can move a device from
   the child restriction profile to the teen one. Read the whole plan, not just the membership diff.
4. Merge, approve the deployment.

Nothing else needs editing. Group membership is calculated from the tier, so the tier is the only
place that knowledge lives.

## Where the tiers do not reach yet

Two things the tenant owner called out are not implemented in this repository yet, because both
need policy types the engine does not support:

- **Forced Global Secure Access for the child tier.** GSA profiles are managed through settings
  catalog and network access policies.
- **Explicit app allowlisting.** The Store is blocked for the child tier, which enforces the
  *effect* today (only assigned apps can be installed), but the approved app list itself is not yet
  declared here.

Both are tracked in [architecture.md](architecture.md#adding-a-policy-type) behind settings catalog
support.
