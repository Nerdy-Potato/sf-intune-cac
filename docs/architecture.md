# Architecture

## Why this shape

The obvious alternatives were considered and rejected for this tenant:

- **Clicking in the portal.** No history, no review, no way to rebuild after a mistake.
- **A generic backup/restore tool.** Good at capturing what exists, weak at expressing *intent*.
  It also tends to want to own everything in the tenant, which is dangerous here.
- **A full desired-state framework.** Powerful, but it pulls in a large dependency surface and
  wants broad permissions. For a tenant this size the cost is all downside.

So: plain JSON for desired state, a small PowerShell engine to reconcile it, and GitHub Actions as
the only thing holding a credential.

## The pipeline

```
pull request ──► CI (offline)          schemas + safety rules + Pester
             └─► Plan (read-only app)  diff vs tenant, commented on the PR
                          │
                     human review
                          │
merge to main ──► Deploy (reviewed plan artifact, read-write app, production environment, required reviewer)
nightly ─────────► Drift (read-only app) fails if the tenant stopped matching the repo
```

Two Entra applications, not one:

| Application | Permissions | Federated subject |
| --- | --- | --- |
| `sf-intune-cac-plan` | `*.Read.All` | `pull_request`, `environment:plan` |
| `sf-intune-cac-apply` | `*.ReadWrite.All` | `environment:production` |

Because the write credential is bound to the `production` environment subject, a pull request -
including one that edits a workflow file - cannot obtain it. The environment's required reviewer is
the final approval gate. Deploy also rejects commits that are not the merge commit of an approved
pull request with a successful Plan run and unblocked plan artifact for that pull request's exact
head commit. Manual dispatches
must therefore select a reviewed commit on `main`; arbitrary branches and tags cannot apply.

Neither application has a client secret. Both authenticate by exchanging the workflow's short-lived
GitHub OIDC token, so there is no credential in GitHub to leak or rotate.

## What the engine will and will not touch

Everything this repository owns lives in a namespace: `displayName` starts with the tenant
`namePrefix` (`CaC - `), and `description` contains the managed marker. Validation refuses to accept
a policy definition that lacks either.

That gives three categories:

| Object | Behaviour |
| --- | --- |
| In config, in the tenant | Reconciled to match the repository |
| In config, not in the tenant | Created |
| Not in config, in the tenant, **inside** the managed namespace | Reported as a deletion, only carried out with `allow_delete` |
| Not in config, in the tenant, **outside** the managed namespace | Never read as drift, never modified, never deleted |

The last row is the important one. Anything created by hand in the portal - now or in an emergency
at 2am - is invisible to this repository and survives untouched.

## Matching and drift

Objects are matched by `displayName`, which is why validation rejects duplicates: `displayName` is
the identity key. Renaming a policy is therefore a delete-and-create, not a rename, and the plan
shows it as such.

Matching is also ownership-aware. A matching group or policy must carry both the configured managed
marker and the repository name prefix; apps must carry the managed marker. If an object with the
same identity is unmanaged, the plan records a skipped conflict instead of updating it or creating
a duplicate. Apply treats that skipped action as incomplete, so deployment cannot report success
until the conflict is reviewed.

Drift comparison covers scalar properties and arrays of primitives. Nested objects - the scheduled
action tree on a compliance policy, for example - carry server-generated ids that would produce
permanent false drift, so they are re-sent on every write instead of being diffed. The practical
effect is that a change to `scheduledActionsForRule` alone does not show up in the plan, but it is
applied whenever the policy is written for any other reason.

## Safety rules

Enforced by `Test-CaCConfiguration`, so they fail the pull request rather than the tenant:

- No policy may be assigned to **All Users** or **All Devices**. Every assignment goes through an
  explicit group, so the blast radius of a change is always visible in the diff.
- The break-glass accounts must never be members of an assignment group, and the group that holds
  them is marked exclusion-only.
- Every policy must carry the managed marker and the name prefix.
- A policy must have at least one *include* assignment - an exclusion-only policy applies to nobody
  and is almost always a mistake.
- Group ids referenced by assignments must exist.
- No duplicate policy names or display names.

`New-CaCPlan` performs only `GET` requests, and `Connect-CaCGraph -ReadOnly` makes the Graph client
throw on any write, so planning cannot mutate the tenant even if the code is wrong.

## Ordering

`Invoke-CaCPlan` applies in a fixed order: create groups, reconcile membership, write policies,
then assign. It uses only ids carried by the reviewed plan or returned by creates; it never
rediscovers ids from the live tenant. Assignment targets therefore always exist by the time a
policy is assigned, which is the failure mode a naive implementation hits on a first run against
an empty tenant.

Each write action records `Applied`, `Skipped`, or `Failed`. Graph write errors are captured with
their action context, and the deployment entry point fails if any action is skipped or failed.
The Graph client never retries `POST`: a timeout can happen after Graph accepted a create, and
retrying it could create a duplicate. Safe read/update/delete retries remain available.

## Adding a policy type

`Get-CaCResourceMap` is the only place that knows about Graph endpoints. Adding a supported resource
means adding an entry there and to the `resource` enum in `schemas/policy.schema.json`; everything
else is data.

Settings-catalog policies (`deviceManagementConfigurationPolicies`) are deliberately not supported
yet. They are expressed as opaque setting-instance trees rather than named properties, so they need
a different diff strategy than the one above - that is the next thing to build, and it is where
Defender ASR rules and the security baselines will live.
