# IntuneCaC.Extensions (reference implementation - staged, not deployed)

This module closes resource-type gaps between the production `IntuneCaC` module and
[IntuneCD](https://github.com/almenscorner/IntuneCD): Settings Catalog policies, Endpoint Security
(Management Intents), Conditional Access, Assignment Filters, and Proactive Remediation scripts.

**It is not wired into anything.** It is not imported by the production module, not referenced by
`scripts/Invoke-CaC.ps1`, not validated by `schemas/policy.schema.json`, not scanned by any GitHub
Actions workflow, and it has never made a single call against the live tenant. It lives entirely
under `src/IntuneCaC.Extensions/` on the `feature/intunecac-extensions-reference` branch so it can
be reviewed, discussed, and picked apart before any of it is allowed to touch production.

Read [`DECISIONS.md`](DECISIONS.md) first. It lists every place this module made a judgment call
instead of a settled decision - several of them (Conditional Access in particular) have real
blast-radius if the wrong default is carried forward unreviewed.

## Why a separate module instead of extending `IntuneCaC` in place

Production `IntuneCaC` is deployed and running against a real tenant with a real family on it.
Building the reference implementation as a second, standalone module means:

- Nothing here can accidentally get picked up by the production `Invoke-CaC.ps1` entry point.
- A handful of low-level Graph/JSON helpers are intentionally *duplicated* from
  `IntuneCaC/Private` rather than imported, so this module has zero runtime dependency on the
  deployed code path (see the `.NOTES` block on each duplicated file).
- The whole module can be deleted, or merged in piecemeal per resource kind, without touching a
  single line of the code that is already running.

## Layout

```
IntuneCaC.Extensions.psd1/.psm1   Manifest + loader, same dot-source-all pattern as IntuneCaC
Private/                          Diff strategies, safety rails, duplicated Graph primitives
Public/                           Get/Test-CaCExtendedConfiguration, New/Format/Invoke-CaCExtendedPlan
schemas/policy.extended.schema.json   Draft schema for the five new resource kinds (not wired into CI)
config-samples/                   Illustrative example configs only - not real tenant data
tests/                            Pester suite exercising every Public and Private function
```

## What each of the five resource kinds needed that the production engine doesn't have

| Kind | Gap closed |
| --- | --- |
| Settings Catalog | Update is `PUT` (whole-object replace), not `PATCH`; keyed by `name`, not `displayName`; settings tree diffed by a stable per-setting key rather than by array position. |
| Endpoint Security | Created by instantiating a Graph template (`.../createInstance`), never posted directly; updated via a dedicated `updateSettings` action, never a plain `PATCH`. |
| Conditional Access | Assignment (who it targets) is embedded in the object itself, and per IntuneCD's own source is not safely updatable in place - a hard safety rail blocks that case instead of silently ignoring it. |
| Assignment Filters | Never assigned themselves; referenced *by* other resources' assignment targets. |
| Proactive Remediation | Base64 script bodies diffed separately from metadata, without ever printing script content into a diff message. |

## Running the tests

```powershell
Invoke-Pester -Path ./src/IntuneCaC.Extensions/tests
```

All 27 tests pass against a mocked Graph invoker - nothing in the test suite makes a network call.

## What this module deliberately does not do

- It does not create, reconcile, or delete Entra groups. `Invoke-CaCExtendedPlan` requires a
  `-GroupObjectIds` map (logical group id &rarr; live object id) supplied by the caller. Group
  management stays the production engine's exclusive job.
- It does not default any Conditional Access policy to `state: enabled`. `-AllowEnabledState` must
  be passed explicitly, and a break-glass group exclusion is mandatory before anything is applied.
- It does not attempt to update Conditional Access assignment in place. See `DECISIONS.md`.
- It does not run against, or read from, the real `config/` tree - `Get-CaCExtendedConfiguration`
  defaults to this module's own `config-samples/` folder.
