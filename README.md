# sf-intune-cac

Intune (and the surrounding Entra objects) for the **Nerdy Potato** Microsoft 365 tenant, as code.

This tenant is real production: it carries the family's mail, OneDrive and devices. There is no
helpdesk and no test tenant, so the repository is built around one idea - **nothing reaches the
tenant that a human has not first seen as a plan**.

| | |
| --- | --- |
| Tenant | `nerdypotato.onmicrosoft.com` |
| Licensing | Microsoft 365 E7 |
| Change path | Pull request &rarr; plan &rarr; review &rarr; approved deployment |
| Direct portal edits | Detected as drift every morning |

## How a change is made

1. Edit JSON under [`config/`](config/).
2. Open a pull request. **CI** validates the schemas and the tenant safety rules offline, and
   **Plan** signs in with a *read-only* identity and comments the exact diff on the pull request.
3. Someone reads the plan and approves the pull request.
4. Merging to `main` runs **Deploy**. Before it reaches the `production` GitHub environment, Deploy
   verifies that the commit is the merge commit of that reviewed pull request and that its exact
   head commit passed **Plan**. The environment's required reviewer is still the final write gate.
   Only Deploy holds a write credential.

Nothing else has permission to write to the tenant. A manually dispatched Deploy must select a
reviewed commit on `main`; branches and tags are rejected. Deletions are never carried out unless a
human explicitly starts that deployment with `allow_delete`.

## Layout

```
config/                    Desired state - the source of truth
  tenant.json              Tenant identity, naming, and the safety switches
  identity/users.json      Accounts and which age tier each person is in
  identity/groups.json     Assignment groups; membership is calculated from users.json
  intune/                  Policy definitions, one file per policy
schemas/                   JSON schemas every config file is validated against
src/IntuneCaC/             The plan/apply engine (PowerShell, Microsoft Graph)
scripts/Invoke-CaC.ps1     Entry point used by the workflows and by humans
bootstrap/                 The one-time, documented setup that CI/CD cannot do for itself
tests/                     Pester tests - run offline, no tenant required
docs/                      Architecture, bootstrap, age tiers, operations
```

## Running it locally

```powershell
# Offline: schemas, safety rules and tests. Safe anywhere, touches nothing.
./scripts/Invoke-CaC.ps1 -Mode validate
Invoke-Pester -Path ./tests

# Read-only diff against the tenant.
./scripts/Invoke-CaC.ps1 -Mode plan -TenantId <tenant-id> -ClientId <plan-app-client-id>
```

`-Mode plan` puts the Graph client into a read-only mode where any non-`GET` request throws, so a
local plan cannot change the tenant even by accident.

## Documentation

- [Architecture](docs/architecture.md) - how the engine decides what to change, and what it refuses to touch.
- [Age tiers](docs/age-tiers.md) - the privilege model, and how to move a child up a tier.
- [Bootstrap](docs/bootstrap.md) - the one-time setup of the federated identities and environments.
- [Operations](docs/operations.md) - routine changes, drift, emergencies and rollback.
- [Enterprise child enrollment](docs/enterprise-child-enrollment.md) - corporate-owned enrollment,
  approved apps, MDE and forced Global Secure Access.
