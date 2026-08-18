# Squad Decisions

## Active Decisions

### 2026-08-16T23:15:16.465-05:00: PR #13 merge was unblocked without relaxing deploy safety gates
**By:** Scribe
**What:** Switch fixed the CI-only strict-mode Pester failure in `tests/Plan.Tests.ps1`, unblocking PR #13 and merge commit `ced3668745b8c96e885cd89529925e3d1dc6b115`. The main deploy run then correctly stopped at the reviewed-commit approval gate, so only the child-tier app/adoption work from the merged PR was advanced and Microsoft Authenticator adoption remains skipped fail-closed pending tenant-owner verification.
**Why:** The team needed the test fix merged while preserving the requirement for a human approval on the reviewed PR head SHA and the separate production environment reviewer gate before any tenant write can run.

### 2026-08-16: Unblock child Android/iOS app deployment by removing non-deployable extras
**By:** Trinity
**What:** Removed the one-time Microsoft Authenticator adoption entries from `config/tenant.json` and removed the child-tier Windows `existing` app entries from `config/apps/approved-child-apps.json`.
**Why:** The Authenticator adoption entries are fail-closed because the tenant's immutable app identities do not match the configured adoption identities, so leaving them configured blocks deployment without changing the existing tenant apps. The Windows entries require manual tenant-side app creation that this pipeline cannot safely perform, and they are unrelated to the immediate child mobile M365 rollout.

### 2026-08-16: Remove child Authenticator management and document solo recovery deploy
**By:** Trinity
**What:** Removed the `android-authenticator` and `ios-authenticator` child app catalog entries, updated the offline tests and docs to match, and added `scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1` for the reviewed-commit recovery dispatch path.
**Why:** The tenant already has an unmanaged Microsoft Authenticator app object, so keeping Authenticator in desired state leaves PR #14 permanently blocked on a fail-closed Skip. Removing those entries keeps Authenticator untouched while letting the plan reach `Ready`, and the new script documents the repository's intended deployment path for a solo maintainer who cannot satisfy GitHub's self-approval review rule.

### 2026-08-16: Stuck app remediation workflow
**By:** Trinity
**Context:** Ten Intune store app objects were confirmed stuck in Microsoft Graph `publishingState: processing` for over an hour, and every assignment attempt was already failing because the apps never reached `Published`.
**Decision:** Add a manual-only remediation workflow plus `scripts/bootstrap/Remove-CaCStuckApp.ps1` to delete specific stuck `deviceAppManagement/mobileApps/{id}` objects through the existing GitHub Actions OIDC Graph identity path.
**Why:** This keeps the remediation consistent with the repository's CI/CD-first model, preserves `-WhatIf` safety for the destructive delete, and documents the approved delete/recreate recovery path without weakening the normal deployment workflow.

### 2026-08-16: Pass -Confirm:$false to the stuck-app remediation script from the workflow
**By:** Trinity
**Context:** Run `32001218924` of `remediate-stuck-app.yml` failed with `Exception calling "ShouldProcess" with "2" argument(s): "Object reference not set to an instance of an object."`. `Remove-CaCStuckApp.ps1` declares `[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]`, and with the default `$ConfirmPreference` also `High`, `$PSCmdlet.ShouldProcess(...)` tries to prompt interactively for confirmation on every delete. The GitHub Actions runner has no interactive host, so the prompting machinery throws a null-reference exception instead of failing cleanly.
**Decision:** Keep `SupportsShouldProcess` on the script (so `-WhatIf` still works for manual/local dry runs), but invoke it from the workflow's "Delete stuck app objects" step with `-Confirm:$false`, added a matching Pester assertion, and opened PR #20 (`squad/fix-remediation-confirm-noninteractive`) against `main`.
**Why:** The workflow already gates execution behind an explicit `confirm: true` boolean input (the "Require explicit confirmation" step) — that is the real authorization control for this solo-maintainer, no-PR-review production remediation tool. The script's own interactive `ShouldProcess` prompt is redundant in CI and was what crashed the run. `-Confirm:$false` is the standard PowerShell pattern to disable interactive prompting for an already-authorized automated caller while keeping `-WhatIf`/`ShouldProcess` support intact for humans running it locally.
**Verification:** Full Pester suite passed (88/0 failed). Confirmed locally that the script parses cleanly, `Get-Help -Full` shows `-WhatIf`/`-Confirm` bound correctly, and a `-WhatIf` dry run with a fake AppId fails only at the expected `TenantId`/`ClientId` guard (no parse error, no ShouldProcess crash).

### 2026-08-17: Auto-discover reviewed commit sha in Invoke-SoloRecoveryDeploy.ps1
**By:** Trinity (Intune Graph Engineer)
**What:** Fixed `scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1` so that when `-CommitSha` is not supplied, it auto-discovers the correct reviewed commit (a merged pull request's HEAD sha) instead of defaulting to `git rev-parse main`. Auto-discovery walks the most recently merged PRs (newest first, up to 30), skips any whose merge commit hasn't landed on local `main` yet (`git merge-base --is-ancestor`), and requires a successful `plan.yml` run with a valid, non-expired `plan` artifact for the candidate's PR head sha, falling back to older PRs until one qualifies. The existing explicit `-CommitSha` override is unchanged in behavior; its docs now clarify it must be a PR head sha, not a `main` merge/squash commit.
**Why:** `deploy.yml`'s recovery-mode verify step requires `reviewed_sha` to equal a merged pull request's `head.sha` (pre-merge branch tip), not the squash-merge commit that lands on `main`. Since this repo merges via `gh pr merge --squash`, `git rev-parse main` almost never equals any PR's head sha, so the old default reliably failed with "Commit X is not the merge commit of a pull request." This blocked the live solo-maintainer recovery redeploy needed after deleting 10 stuck Intune mobile app objects (`publishingState: 'processing'`).
**Future note:** Documented (not code-fixed) a related plan-staleness gotcha in the script's `.NOTES`: a Plan run's `plan.json` reflects tenant state only as of plan time, so redeploys after manual tenant-state changes (like remediation scripts) need a fresh PR touching `config/**`/`src/**`/`scripts/**` to get a plan reflecting current reality before reusing this recovery script.

### 2026-08-17: IntuneCD evaluation — no full migration, selective adoption only
**By:** Copilot (GitHub Copilot CLI, direct session with @x3nc0n)
**What:** Evaluated switching this repo's engine to IntuneCD (github.com/almenscorner/IntuneCD, MIT).
Decision: do **not** replace the custom PowerShell plan/apply engine. Instead:
  1. Adopt IntuneCD read-only as an additive nightly documentation/backup job (`IntuneCD-startbackup`
     + `IntuneCD-startdocumentation`) for as-built visibility across the whole tenant, including
     resource types we don't manage yet. Zero risk to the existing apply pipeline.
  2. For new resource types (Settings Catalog next, per docs/architecture.md's own stated roadmap;
     then Conditional Access, Proactive Remediation, Notification Templates, Filters, Endpoint
     Security intents as needed), extend `Get-CaCResourceMap` / add new Kinds to our own engine.
     Use IntuneCD's Python source (MIT-licensed, freely referenceable) as a spec for exact Graph
     endpoints, HTTP verbs/status codes, and `exclude_paths`-equivalent gotchas per resource type,
     rather than importing the Python runtime.
  3. Do not run a second (Python) apply engine in parallel with the PowerShell one for any
     production write path — avoids split-brain ownership of the same resources and a second
     credential/permission surface.

**Why:**
- IntuneCD has **no update/push support for `mobileApps`** (backup/read-only only — confirmed by
  inspecting `src/IntuneCD/update/Intune/` vs `backup/Intune/Applications.py` on GitHub). The
  Android child-app adopt/update/assign logic this repo just spent an entire session hardening
  (PRs #33, #35, #36, #37) is *not* redundant with IntuneCD at all — it is exactly the gap IntuneCD
  leaves unsolved. A full migration would not have removed today's hardest problem.
- IntuneCD's core model is DEV-tenant-backup → git → PROD-tenant-push (see its Azure DevOps pipeline
  template in the wiki). This repo has one tenant and hand-authored desired-state JSON, not a
  separate DEV tenant to snapshot from — a structural mismatch with IntuneCD's primary workflow.
- This repo's own `docs/architecture.md` already documented and rejected "a full desired-state
  framework" as an alternative for this exact reason: "it pulls in a large dependency surface and
  wants broad permissions. For a tenant this size the cost is all downside." This evaluation
  independently reached the same conclusion before finding that prior architectural note.
- `Get-CaCResourceMap` already makes new-resource-type support "a data change, not a code change"
  for any Graph resource following the standard CRUD+assign pattern — the same value proposition
  IntuneCD offers, without adding a second language runtime (Python) and dependency tree to a
  PowerShell/GitHub Actions CI that was just heavily tested and hardened this session.
- Confirmed IntuneCD is MIT-licensed, so referencing/porting endpoint knowledge (e.g. its
  `SettingsCatalog.py` update module: `PUT` + `204` against
  `/beta/deviceManagement/configurationPolicies/`, settings fetched via a separate
  `/settings?&top=1000` batched call, `exclude_paths: ["root['assignments']"]`) is unproblematic.

**Not acted on:** the earlier-discussed "10 failed non-outage PRs → nuke and start over with
IntuneCD" contingency never triggered (all PR-creation/merge failures this session were confirmed
GitHub-wide outages), so no rewrite was warranted on that basis either.

### 2026-08-18T10:15:51.432-05:00: Add missing teen-tier Android enrollment restrictions
**By:** Mouse (Security & Policy Engineer)
**Bug:** Adalynn (tier=teen) was being prompted/forced by Company Portal to set up an Android
Enterprise Work Profile on her personal Android device.
**Root cause:** `config/intune/enrollment/` had explicit `platformBlocked: true` restrictions for
`sg-tier-adult` and `sg-tier-child` covering both the legacy Android device-admin path
(`platformType: "android"`) and the Android Enterprise/Work Profile path
(`platformType: "androidForWork"`), but no equivalent restriction existed for `sg-tier-teen`.
Teens are assigned `android-app-protection-baseline.json` (MAM-only, `deviceComplianceRequired:
false`) via `sg-productivity-all`, identical to adults, so they should never be offered device
enrollment. Without a teen-tier restriction, Intune's default enrollment behavior left the
Android Enterprise Work Profile path open, and Company Portal offered/forced it on first sign-in.
**Fix:** Added two new files mirroring the adult pair exactly:
- `config/intune/enrollment/teen-enrollment-restriction-android.json`
- `config/intune/enrollment/teen-enrollment-restriction-android-for-work.json`

Both assign `sg-tier-teen`, set `platformBlocked: true` and `personalDeviceEnrollmentBlocked:
true`, matching the adult tier's personal-device treatment (as opposed to the child tier's
corporate-owned, `platformBlocked: false` treatment).
**Deviation from the literal ask — priority value:** The task asked for `priority: 2` (same
literal value as the adult files) since teens conceptually get the same personal-device
treatment as adults. I did not do that: Microsoft Graph's `priority` on
`deviceEnrollmentPlatformRestrictionConfiguration` must be unique **per platformType** across the
tenant (confirmed empirically from this repo's existing live data - child holds priority 1 and
adult holds priority 2 for both `android` and `androidForWork` platformTypes, with no collisions
anywhere else in the enrollment folder). Reusing priority 2 for the teen tier would collide with
the adult-tier objects on the same platformType and risk a Graph rejection or an unintended
priority reassignment against a production tenant. Used `priority: 3` for both new teen files
instead (next free slot per platformType) and documented the reasoning inline in each file's
`comment` block.
**Verification:** Full Pester suite passed (96/0 failed), including the generic
`Test-CaCConfiguration` schema/safety pass and `New-CaCPlan`'s `-WhatIf` dry run, which shows both
new policies ("CaC - Enrollment - Teen Personal Devices (Android)" and "... (Android for Work)")
being picked up automatically for creation - confirming the config loader and existing Pester
tests are generic/data-driven over the enrollment directory and required no test changes.
**Not touched:** `config/identity/groups.json` / `users.json` - `sg-tier-teen` already existed;
no group changes were needed.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
