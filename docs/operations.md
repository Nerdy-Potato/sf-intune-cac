# Operations

## Routine change

1. Branch, edit the JSON under `config/`, open a pull request.
2. **CI** validates schemas and safety rules offline and runs the tests. **Plan** comments the diff.
3. Read the plan. In particular read the *assignment* rows: a one-line edit that changes who a
   policy targets is the change most likely to interrupt somebody's day.
4. Merge. Deploy plans and applies directly against the current `main` commit, refusing to apply
   a blocked plan (skipped/prerequisite actions). The job uses the `production` environment;
   approval is required only if reviewers are configured there.

An apply is successful only when every requested action is applied. Unmanaged identity conflicts,
missing prerequisites, and write failures are reported in the applied plan and fail the deployment;
review the message before retrying. `POST` requests are not automatically retried because a lost
response may follow a successful create. Re-running the plan first discovers the object and avoids
creating a duplicate.

### One-time adoption cleanup

The first plan may contain a narrowly scoped `Adopt` row for the Autopilot preparation group.
Confirm the exact display name and group shape before approval. After a successful apply, verify the
managed marker and that existing membership remains intact, then remove `adoption` from
`config/tenant.json` through a reviewed pull request. A mismatch remains blocked; never replace this
section with a global unmanaged-object bypass.

### Re-running a deploy

Deploy runs on matching configuration, source, script, or deploy-workflow pushes to `main` and can
also be run manually (`workflow_dispatch`) - for
example, redeploying after out-of-band tenant remediation, or re-running a deploy whose automatic
push-triggered run did not fire. There's no separate recovery procedure: it plans and applies
against its triggering commit only when that commit is still current `main`, and still refuses to
apply a blocked plan (skipped/prerequisite actions). Before credentialed planning and again
immediately before apply, `scripts/Assert-CaCDeploymentSource.ps1` requires `GITHUB_REF` to be
`refs/heads/main` and both `GITHUB_SHA` and checkout `HEAD` to equal the current remote main SHA
read from the GitHub API. Non-main dispatches, stale reruns, mismatched checkouts, and API lookup
failures fail explicitly rather than being skipped. Dispatch a new run on `main` after such a
failure; no peer-review or separate recovery ceremony is required.

These are point-in-time checks, not a lock against a push after verification. Historical workflow
versions do not acquire the new guards when rerun. Configure the `production` environment's
deployment branch restriction to allow **only `main`** before relying on it to reject historical
non-main execution; the October 2 audit found no live environment branch restriction or reviewer
protection. Branch restrictions alone do not reject an old SHA on `main`: do not rerun historical
unguarded deploys, and dispatch the current workflow instead. Repository changes here do not
alter GitHub environment protections. The optional `production` approval gate (configured in
GitHub, not this repo's workflow code) is the control to use if you want a manual check before
apply - see [bootstrap.md](bootstrap.md) for setting that up.

### Device missing from its tier device group

`CaC-Devices-Adult`/`-Teen`/`-Child` are dynamic groups whose membership rule matches the Entra
device object's `extensionAttribute1` (`Adult`/`Teen`/`Child` - see [`age-tiers.md`](age-tiers.md)).
Entra maintains membership; this repository never writes it. If a device-scoped policy (most
importantly Windows LAPS, the tier restrictions, or the child Android restrictions and Defender/GSA
app configuration) is not applying to an enrolled device, check in this order:

1. **Confirm the device is tagged.** Entra admin center > Devices > find the device > check
   `extensionAttribute1`. Tagging is a manual step per device and a newly enrolled device has no
   tag until an administrator sets one. If it is blank or wrong, fix it with the exact Entra device
   object ID:

   ```powershell
   gh workflow run set-device-tier-tag.yml `
     -f device_object_id='<entra-device-object-id>' `
     -f tier='Adult' `
     -f confirm=true
   ```

   (or run `scripts/bootstrap/Set-CaCDeviceTierTag.ps1` directly with Graph access). Changing an
   existing nonempty tag additionally needs `allow_tier_change`/`-AllowTierChange`.
2. **Confirm dynamic group membership caught up.** Entra re-evaluates dynamic rules asynchronously
   after a device attribute changes. A verified tag write is not proof of membership - open the
   group in the Entra admin center and confirm the device is listed before concluding the policy is
   at fault.
3. **Trigger an Intune policy sync** on the affected device (Company Portal, or Devices > the
   device > **Sync** in the Intune admin center) so it picks up the policy on its next check-in.

Because these are dynamic groups, adding the device to the group by hand is not a fallback - Entra
recomputes membership from the attribute. Tag the device instead. The rule has no operating system
condition, so Android corporate-owned child devices are covered by the same tag.

Adult/teen local administrator rights are handled at enrollment by the Windows Autopilot profile's
**User account type = Administrator** setting and the Entra device-join registering-users scope, not
by these device groups. If the joining adult/teen user is not a local admin immediately after
Autopilot completes, check the assigned deployment profile first; MDM policy sync is not the source
of that permission.

### Retiring the removed local administrator remediation

The proactive-remediation approach to enrolling-user local admin (the detection/remediation script
pair, its bootstrap, the one-device recovery script, and their workflows) has been removed from this
repository, along with the Autopilot Group Tag setter. Do not reintroduce a retry script, a
one-device recovery workflow, or a broad "make the Adult/Teen group administrator" assignment;
local administrator rights come from the enrollment-time settings described above.

Removing those files does **not** change the tenant. The following remain live until somebody
retires them deliberately, under an explicit and audited change:

- The deployed `deviceHealthScripts` proactive remediation object and its assignments. Repository
  cleanup neither deletes it nor stops it running.
- Any recovery policy, static recovery device group, or membership created by the retired recovery
  flow. Unassigning an additive policy does not prove that a local Administrators membership it
  granted has been revoked - verify on the endpoint itself (for example with
  `Get-LocalGroupMember -Group Administrators`) before treating it as removed. Leave live recovery
  policies in place until local administrator membership and LAPS escrow are both verified.
- The Microsoft Graph application permissions the retired flows used. The identity bootstrap adds
  the permissions this repository now needs; it never revokes rights that were previously granted.
  Revoke the obsolete grants manually once no caller remains, and re-consent the applications so
  the live consent matches `bootstrap/New-CaCGitHubIdentity.ps1` - see
  [bootstrap.md](bootstrap.md).

#### Retiring the portal recovery policies

`Recover Adult Admin` and `Recover Teen Admin` were created by hand in the Intune portal. Each one
adds a whole tier user group (`CaC-Tier-Adult` / `CaC-Tier-Teen`) to local Administrators on every
device in the matching tier device group - the broad grant this design rules out. Because they carry
no managed marker, `Remove-CaCOrphanConfigurationPolicy.ps1` refuses them. Retire them with the
**Retire local admin recovery policies** workflow instead:

```powershell
gh workflow run retire-local-admin-recovery-policies.yml -f policy='Both' -f confirm=true
```

It runs `scripts/bootstrap/Remove-CaCLocalAdminRecoveryPolicy.ps1` under the apply identity, in the
`production` environment. It accepts only those two exact names. Before deleting anything it proves
that every selected policy is unique by name and contains exactly one setting, which adds
(Update, never Replace) exactly the live tier user group's SID to local Administrators. If any
selected policy fails that check, nothing is deleted.

Before you run it, make sure each Adult/Teen Windows device has an enrollment-time grant to fall
back on. The registering-users scope and device preparation apply **only when a device joins**. A
device that was joined before the scope was set, or joined without device preparation, never
received one. Its user is an administrator only because of the recovery policy. Re-provision such
devices through Autopilot device preparation, signing in as their own user, before you retire the
policy that covers them. Windows LAPS (`x3nc0n`) remains the break-glass path either way.

Deleting an additive policy neither reliably revokes nor reliably keeps the membership it granted.
After the next sync, check each affected device with `Get-LocalGroupMember -Group Administrators`.

### Verifying child Defender and Global Secure Access coverage

The **Inventory Intune apps** workflow runs
`scripts/bootstrap/Get-CaCAppInventory.ps1 -IncludeChildGsa` under the read-only plan identity, so
every request is a `GET` and it cannot change anything. Beyond the app object inventory it reports,
for the child Defender app configuration:

- for each Global Secure Access key, the desired typed value next to every actual typed value Intune
  stores. `ForcedOn` is true only for the native `EnableGSA` key = `valueInteger` `3`, so a string `"3"`
  doesn't count. `PrivateAccessDisabled` is true only for `GlobalSecureAccessPrivateChannel` =
  `valueInteger` `0`, and Private Access is intentionally off. `ContractSatisfied`/`ContractErrors`
  give the overall verdict;
- the live Managed Google Play schema evidence (the schema id, the GSA-related keys and their data
  types), with a warning if the schema doesn't type both keys as `integer`;
- the child user- and device-group include flags and their member counts, and the exclusion count;
- how many competing Defender app configurations exist, warning when more than one could overlap;
- the aggregate reported `deviceStatuses`, with no device, user, or tenant identifiers. These are
  Intune delivery states: a policy counted as `compliant` was delivered, but that doesn't show that
  GSA is on and locked on the device.

Run it twice around a change to this area: once before deploying, to record the starting state, and
once after, to confirm the reviewed configuration is what the tenant now holds.

What it proves is bounded. It reads what Graph says the *configuration object and its assignments*
are, plus what devices have *reported back*. It is not endpoint proof: a device that has not checked
in, has not yet been evaluated into a dynamic group, or has not applied the profile is not
distinguishable here from one that has. Aggregate status counts are reported state, not enforcement.
Confirm on the endpoint itself before concluding that a child device is actually covered.

### Stuck Intune app remediation

If a newly created Intune store app remains in Microsoft Graph `publishingState: processing` for
well over an hour, treat it as a backend sync failure rather than normal publish latency.
Microsoft's guidance says store apps normally publish within a few minutes; when an app object stays
stuck, the recommended remediation is to delete that Graph object and let the deployment recreate
it.

Use the manual-only `remediate-stuck-app.yml` workflow for this one-off cleanup. It uses the same
OIDC-backed apply identity pattern as the deployment workflow, requires explicit confirmation, and
never runs on push or pull request events.

Only use this when the stuck app has no successful assignments yet; otherwise deleting it would
break the existing assignment lineage.

```powershell
gh workflow run remediate-stuck-app.yml `
  -f app_ids=0016c1fd-2abc-4b5c-8d37-a6da9ba650d5,2c3b96cc-b476-4d12-877d-1fff8dfa28f5 `
  -f confirm=true
```

Run the same checks locally before pushing:

```powershell
./scripts/Invoke-CaC.ps1 -Mode validate
Invoke-Pester -Path ./tests
```

## Evaluating a change for risk

This tenant carries real mail and real files, so before approving, ask:

| Question | Why |
| --- | --- |
| Who does the plan actually touch? | Assignment rows show the real blast radius, not the intent. |
| Can this lock somebody out? | Compliance policies gate access. Grace periods are set to notify immediately and block after 72 hours precisely so a bad policy is noticed before it bites. |
| Does it hit both update rings? | Two update rings on one device is an outage class of its own. The broad ring explicitly excludes the adult tier for this reason. |
| Is it reversible? | Almost everything here is: revert the commit and deploy. See rollback below. |
| Does it need to land now? | Prefer a weekday morning. Nobody wants to debug MDM enrolment at midnight. |

Higher-risk changes are worth staging: apply to the adult tier first, live with it for a few days,
then widen the assignment in a second pull request.

## Deletions

The plan reports objects that this repository owns but no longer defines. They are **not** deleted
by a normal deployment. To carry them out, select the reviewed merge commit on `main` when manually
starting **Deploy**, check `allow_delete`, and approve the `production` environment after reading
the plan. Dispatching from another branch or tag is rejected.

Objects outside the managed namespace - anything without the `CaC - ` prefix and the managed marker
- are never proposed for deletion at all.

## Drift

The **Drift detection** workflow runs every morning and fails if the tenant no longer matches this
repository. A failure means one of two things:

- Somebody changed something in the portal. Decide whether the change was right: if it was, bring it
  into `config/` in a pull request; if it was not, re-run **Deploy** to reconcile it away.
- A deployment did not finish. Check the last Deploy run before doing anything else.

Custom OMA-URI policies are compared setting by setting, so an added or changed node is real drift.
Encrypted OMA settings (`isEncrypted`) are the exception: Graph returns them masked, so the plan
cannot compare them and warns instead. A missing drift report for an encrypted node is not evidence
that the tenant matches - verify the effective setting on an endpoint.

## Emergency change

If something has to change *right now* - a compromised account, a policy locking everybody out -
change it in the portal. That is a legitimate thing to do and the tooling is built to tolerate it:

1. Fix it in the portal.
2. Expect the next morning's drift run to fail, or trigger it manually.
3. Bring the change back into `config/` in a pull request the same week, so the repository and the
   tenant agree again.

The one thing not to do is leave the portal and the repository disagreeing indefinitely - the next
routine deployment would quietly revert the emergency fix.

## Rollback

```bash
git revert <commit>
```

Open it as a pull request like any other change: the plan will show the tenant being returned to its
previous state. Deployments are reconciliations, not migrations, so replaying an old commit produces
the state that commit describes.

The exception is deletion. If a deployment ran with `allow_delete` and removed a policy, reverting
recreates the policy with a new object id. Assignment and settings return; historical per-device
compliance data against the old object does not.

## Break-glass accounts

`mauricemoss` and `bobjohnson` are excluded from everything by design, and validation fails if
they ever end up in a group that has policy assigned to it. Do not "tidy" them into a group.
