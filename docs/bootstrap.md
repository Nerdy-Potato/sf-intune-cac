# Bootstrap

Everything in this repository is deployed by GitHub Actions. The exception is the identity that
GitHub Actions authenticates with - something has to create that by hand, once.

Run this as **johnspaid@nerdypotato.onmicrosoft.com** (Global Administrator) against the
**Nerdy Potato** tenant (`nerdypotato.onmicrosoft.com`). The script refuses to run against any
other tenant unless `-Force` is passed.

## 1. Create the app registrations

```powershell
Connect-MgGraph -Scopes Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, Directory.Read.All

# Always rehearse first - the script supports -WhatIf.
./bootstrap/New-CaCGitHubIdentity.ps1 -WhatIf
./bootstrap/New-CaCGitHubIdentity.ps1
```

It creates, idempotently:

| Application | Graph application roles | Federated subjects |
| --- | --- | --- |
| `sf-intune-cac-plan` | `DeviceManagementConfiguration.Read.All`, `DeviceManagementApps.Read.All`, `DeviceManagementServiceConfig.Read.All`, `Group.Read.All`, `User.Read.All` | Legacy and numeric-ID subjects for `pull_request` and `environment:plan` |
| `sf-intune-cac-apply` | `DeviceManagementConfiguration.ReadWrite.All`, `DeviceManagementApps.ReadWrite.All`, `DeviceManagementServiceConfig.ReadWrite.All`, `Group.ReadWrite.All`, `User.Read.All` | Legacy and numeric-ID subjects for `environment:production` |

No client secrets are created. Both applications authenticate by exchanging GitHub's short-lived
OIDC token, so there is nothing stored in GitHub and nothing to rotate.

Re-running the script is safe: it reconciles rather than duplicating. Re-run it after pulling a
change that adds a Graph role; existing applications are updated in place.

GitHub may present OIDC subjects with numeric organization and repository IDs (for example,
`repo:Nerdy-Potato@317626810/sf-intune-cac@1336208931:environment:plan`). The bootstrap defaults
to this repository's IDs and creates both numeric-ID and legacy subjects for compatibility. If the
repository is moved or renamed, pass its current IDs with `-GitHubOrganizationId` and
`-GitHubRepositoryId`.

### Grant the Intune Administrator directory role to the apply identity

Microsoft requires the calling principal to hold the **Intune Administrator** (formerly "Intune
Service Administrator") Microsoft Entra directory role before it can create or update device
enrollment platform restriction configurations - the Graph application permissions above are not
enough for this one resource type. Without it, Deploy fails with:

```
403 Forbidden - "Tenant is not Global Admin or Intune Service Admin. Operation is restricted."
```

This is a directory role assignment, not an app registration change, so it needs its own
Global-Administrator-run step:

```powershell
Connect-MgGraph -Scopes RoleManagement.ReadWrite.Directory, Application.Read.All

./bootstrap/Grant-CaCIntuneServiceAdminRole.ps1 -WhatIf
./bootstrap/Grant-CaCIntuneServiceAdminRole.ps1
```

It activates the directory role in the tenant if this is its first use, and adds
`sf-intune-cac-apply`'s service principal as a member. Idempotent and safe to re-run.
`sf-intune-cac-plan` is read-only and does not need this role. This is not required by CI/CD on
purpose: assigning a directory role needs `RoleManagement.ReadWrite.Directory`, and granting that
permission to the apply identity itself would be a larger privilege increase than the problem it
solves.

## 2. Set the repository variables

The script prints these with the real values at the end of its run:

```bash
gh variable set AZURE_TENANT_ID       --body <tenant-id>
gh variable set AZURE_PLAN_CLIENT_ID  --body <plan-app-client-id>
gh variable set AZURE_APPLY_CLIENT_ID --body <apply-app-client-id>
```

These are *variables*, not secrets. A client id is not a credential, and having them visible in the
workflow logs makes debugging a failed run much easier.

Until `AZURE_TENANT_ID` and `AZURE_PLAN_CLIENT_ID` are set, the Plan workflow skips the tenant plan
and says so in the run summary. Configuration is still validated offline by CI.

## 3. Create the GitHub environments

| Environment | Used by | Protection |
| --- | --- | --- |
| `plan` | Plan, Drift detection | None needed - the identity is read-only. |
| `production` | Deploy | **Required reviewer.** This is the approval gate for the whole tenant. |

Without the required reviewer on `production`, a merge to `main` writes to the tenant unattended.
That is the single most important setting in this list.

## 4. Protect `main`

Require these checks before merge:

- `CI / Validate configuration`
- `Plan / Plan against the tenant`

Direct pushes to `main` should be blocked - a push to `main` is a deployment, and Deploy rejects
any commit that is not associated with a merged pull request. Do **not** also require a pull
request review here: this is a solo-maintained repository, GitHub can never let a maintainer
approve their own pull request, and Deploy no longer gates on PR approval - the successful Plan
run, the merge-commit check, and the `production` environment's required reviewer are the
enforced gates. Manual Deploy runs must select a commit on `main`; the workflow's reviewed-commit
check rejects branches and tags.

## 5. Approve Android apps in Managed Google Play

Every Android entry in `config/apps/approved-child-apps.json` uses
`source: "managedGooglePlay"` / `@odata.type: managedAndroidStoreApp` - correctly, these are
Managed Google Play apps, not Built-in Android apps. But Managed Google Play is Google's catalog,
not Microsoft's: **Google requires each package to be approved through the Managed Google Play
console before Intune can ever finish "publishing" the corresponding app object.** There is no
Graph API or PowerShell path around this - it's an interactive, Google-side consent step, the same
one you'd do by hand if you added the app through the Intune portal's app picker instead of this
repository.

`Invoke-CaCPlan`/`Invoke-CaCApply` create the app object via a direct
`POST /deviceAppManagement/mobileApps` (see `Invoke-CaCPlan.ps1`). Graph accepts that create and
the object appears in the tenant, but if the package was never approved in Managed Google Play, it
is permanently stuck in `publishingState: processing` - not delayed, *stuck*. Retrying the deploy,
or deleting and recreating the app object, does not help: recreating the Intune-side object doesn't
touch Google's approval state, which is keyed to the package, not to our object.

Before the first deploy that creates Android apps (or if apps are stuck in `processing` for more
than an hour with no other explanation), approve every package once:

1. Sign in to [Intune admin center](https://intune.microsoft.com) as a Global Administrator.
2. **Apps > Android > Managed Google Play**. This opens Google's own app-search experience embedded
   in Intune - your Intune tenant must already show an active Android Enterprise/Managed Google Play
   connection here (it does, since child device enrollment already requires it).
3. For each package below, search for the app, open it, and click **Approve**, then confirm the
   default (or your preferred) approval/update settings:

   | Display name | Package ID |
   | --- | --- |
   | Microsoft Defender | `com.microsoft.scmx` |
   | Microsoft 365 Copilot | `com.microsoft.office.officehubrow` |
   | Microsoft Word | `com.microsoft.office.word` |
   | Microsoft Excel | `com.microsoft.office.excel` |
   | Microsoft PowerPoint | `com.microsoft.office.powerpoint` |
   | Microsoft OneNote | `com.microsoft.office.onenote` |
   | Microsoft Outlook | `com.microsoft.office.outlook` |
   | Microsoft Teams | `com.microsoft.teams` |
   | Microsoft OneDrive | `com.microsoft.skydrive` |
   | Microsoft Edge | `com.microsoft.emmx` |

4. After approving all ten, trigger a sync (**Apps > Android > Managed Google Play > Sync**, or wait
   for Intune's automatic sync). Google's own sync usually completes within minutes, not hours.
5. Redeploy. `Get-CaCRemoteAppCandidates` matches remote apps by `packageId`, so if approval created
   a separate, properly-synced object, the next plan will pick that one up as the existing app going
   forward rather than creating a duplicate. If a stuck placeholder object from before approval is
   left behind afterwards, remove it with `scripts/bootstrap/Remove-CaCStuckApp.ps1` (see the
   `Remediate stuck Intune app objects` workflow) once the approved app is confirmed `published` and
   assigned correctly.

### Known gap: `@odata.type` drift is not auto-detected

`Get-CaCPayloadDrift` intentionally excludes `@odata.type` from its comparison (Graph does not allow
converting one concrete app type into another via `PATCH` - the type is immutable at creation), and
`Get-CaCRemoteAppCandidates` matches remote objects to config purely by `packageId`/`bundleId`. If a
live app object was ever created with a different concrete type than config declares, the plan/deploy
loop will report `NoChange` for it forever; nothing here surfaces that drift automatically today.

This happened in practice: ten Android app objects were originally created (via manual Managed
Google Play approval in the portal) as `androidManagedStoreApp` - a real but legacy/beta Graph type -
while `config/apps/approved-child-apps.json` had been changed at one point to declare the newer
`managedAndroidStoreApp` type. Both are genuine Managed Google Play object types, so they still
showed "Managed Google Play Store app" (not literally "Built-in") in the Intune portal, but the
mismatch meant Graph rejected `PATCH` requests built from config's payload with a generic
`ModelValidationFailure` (400) once the plan engine actually tried to write to these objects (for
example, during one-time adoption of manually-approved apps). The fix was to correct config to
declare the type that actually matches the live objects (`androidManagedStoreApp`), since the type
is immutable and cannot be changed after creation - config must describe reality, not the newer type
name. `scripts/bootstrap/Get-CaCAppInventory.ps1` (run via the `Inventory Intune apps` workflow) is a
read-only diagnostic that lists every live app object's actual `@odata.type` next to what config
declares for that `packageId`/`bundleId`, so this class of drift can be checked for on demand.
`scripts/bootstrap/Get-CaCAppAssignments.ps1` (via `Inspect Intune app assignments`) can then confirm
which duplicate actually carries the live group assignments before anything is deleted with
`Remove-CaCStuckApp.ps1`. Permanently detecting this in the core plan/deploy reconciliation loop is
still open - see the module's `Get-CaCPayloadDrift`/`Get-CaCAppAssignmentDrift` for where that would
need to change. Separately, the one-time `Adopt` action's `PATCH` (in `Invoke-CaCPlan.ps1`) must
always include `@odata.type` in its request body - Graph's polymorphic `mobileApps` collection
returns the same generic `ModelValidationFailure` for *any* partial `PATCH`, even a single-field one,
if the concrete type is omitted.

## 6. Confirm the tenant details

Two things still need a decision from the tenant owner before the first apply:

1. **`primaryDomain` in `config/tenant.json`.** It is `null`, so the productivity accounts currently
   resolve to `@nerdypotato.onmicrosoft.com`. If the family uses a vanity domain, set it. Validation
   warns until it is set.
2. **The unconfirmed age tiers** - see [age-tiers.md](age-tiers.md).

## 7. First run

Before creating a Windows Autopilot device preparation policy, establish the Microsoft-owned
provisioning identity and assigned device group:

```powershell
Connect-MgGraph -Scopes Application.ReadWrite.All,Group.ReadWrite.All,Organization.Read.All
./bootstrap/Initialize-CaCAutopilotDevicePreparation.ps1 -WhatIf
./bootstrap/Initialize-CaCAutopilotDevicePreparation.ps1
```

This follows Microsoft's documented requirement: service principal AppId
`f1346770-5b25-470b-88bd-d5744ab7952c` is created if absent and made owner of
`CaC-Autopilot-DevicePreparation-Child`.

The first deployment against a tenant that has never been touched by this repository will create
eight groups, the approved mobile app catalog, and the configured policies. Read that plan carefully; it is the largest one that will ever be
produced. Consider running the deployment on a workday morning rather than a Friday evening - a
compliance policy landing badly costs somebody their mail on their phone.

### One-time adoption of the existing Autopilot preparation group

`config/tenant.json` contains an explicit, one-time `adoption` section for the newly created
`CaC-Autopilot-DevicePreparation-Child` group. The plan must show `Adopt` only for an exact
display-name match plus the expected group shape. Any ambiguity or mismatch is blocked. Adoption
only adds the repository managed marker; existing group membership is preserved unless a separate
desired-state action reconciles it.

Before approving the first plan, verify those `Adopt` rows and the object IDs in the JSON artifact.
After the apply succeeds, verify the managed marker and membership preservation in the tenant, then
remove the `adoption` section from `config/tenant.json` in a follow-up pull request.
The deployment checkout is read-only by design, so cleanup is intentionally a reviewed repository
change rather than an automatic commit. If adoption fails, leave the section in place and re-plan;
do not broaden it or use a global takeover switch.

## 8. Troubleshooting: MAM app registration conflicts ("already managed with account X")

The MAM SDK (used by Outlook, Teams, OneDrive, the Office apps, and Edge under
`android-app-protection-baseline.json`/`ios-app-protection-baseline.json`) can get stuck showing:

> This app is already managed with account X. Only a single managed account is allowed for this
> app. To use account X, you must first remove X from this application.

This is not caused by tenant policy - it means the tenant-side `managedAppRegistration` record for
that user/app/device is stale or orphaned, most often after a device reset, app reinstall, or
clearing Company Portal's storage without also clearing the affected app's own storage. Try, in
order:

1. On the device: clear storage/cache for the affected app itself, then for Intune Company Portal,
   restart the device, and sign back in. This is local-only and touches nothing server-side.
2. If it persists, dispatch `Inspect Intune MAM app registrations` (`upn`, optional
   `app_id_filter`) - read-only, backed by `scripts/bootstrap/Get-CaCManagedAppRegistrations.ps1` -
   to list the user's registrations and find the `deviceTag` for the stuck device.
3. Dispatch `Wipe Intune MAM app registrations by device tag` (`upn`, `device_tag`, `confirm: true`)
   - backed by `scripts/bootstrap/Invoke-CaCManagedAppWipe.ps1`, which calls Graph's documented
   `wipeManagedAppRegistrationsByDeviceTag` action. This wipes every managed app registration
   sharing that `deviceTag` for the user (i.e. every corporate-managed app container on that one
   device) - not just the one app that was showing the error, since the MAM SDK correlates
   registrations on the same device by `deviceTag`. It does not touch the user's account, mailbox,
   files, personal app data, or other devices; each app re-registers and re-syncs from the cloud the
   next time it is reopened and signed in.
