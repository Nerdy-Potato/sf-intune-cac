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

and require a pull request review. Direct pushes to `main` should be blocked - a push to `main` is
a deployment, and Deploy rejects any commit that is not associated with a reviewed pull request.
Manual Deploy runs must select a commit on `main`; the workflow's reviewed-commit check rejects
branches and tags.

## 5. Confirm the tenant details

Two things still need a decision from the tenant owner before the first apply:

1. **`primaryDomain` in `config/tenant.json`.** It is `null`, so the productivity accounts currently
   resolve to `@nerdypotato.onmicrosoft.com`. If the family uses a vanity domain, set it. Validation
   warns until it is set.
2. **The unconfirmed age tiers** - see [age-tiers.md](age-tiers.md).

## 6. First run

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
