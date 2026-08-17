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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
