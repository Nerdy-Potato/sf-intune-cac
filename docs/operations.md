# Operations

## Routine change

1. Branch, edit the JSON under `config/`, open a pull request.
2. **CI** validates schemas and safety rules offline and runs the tests. **Plan** comments the diff.
3. Read the plan. In particular read the *assignment* rows: a one-line edit that changes who a
   policy targets is the change most likely to interrupt somebody's day.
4. Merge. Deploy verifies the merged commit against the reviewed pull request, downloads that
   pull request's exact `plan` artifact, and rejects missing, blocked, or mismatched plan identity
   before asking for approval in the `production` environment.

An apply is successful only when every requested action is applied. Unmanaged identity conflicts,
missing prerequisites, and write failures are reported in the applied plan and fail the deployment;
review the message before retrying. `POST` requests are not automatically retried because a lost
response may follow a successful create. Re-running the plan first discovers the object and avoids
creating a duplicate.

### One-time adoption cleanup

The first plan may contain narrowly scoped `Adopt` rows for the Autopilot preparation group and the
configured Microsoft Authenticator apps. Confirm the exact display name, group shape, app Graph type,
and package/bundle identity before approval. After a successful apply, verify the managed marker and
that existing membership/assignments remain intact, then remove `adoption` from `config/tenant.json`
through a reviewed pull request. A mismatch remains blocked; never replace this section with a
global unmanaged-object bypass.

Deploy never regenerates a live plan with the write credential. Apply consumes only the reviewed
artifact, whose commit and deterministic action hash are verified before any tenant connection is
opened.

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
