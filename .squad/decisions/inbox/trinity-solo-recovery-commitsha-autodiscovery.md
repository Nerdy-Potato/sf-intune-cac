### 2026-08-17: Auto-discover reviewed commit sha in Invoke-SoloRecoveryDeploy.ps1
**By:** Trinity (Intune Graph Engineer)
**What:** Fixed `scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1` so that when `-CommitSha` is not
supplied, it auto-discovers the correct reviewed commit (a merged pull request's HEAD sha) instead
of defaulting to `git rev-parse main`. Auto-discovery walks the most recently merged PRs (newest
first, up to 30), skips any whose merge commit hasn't landed on local `main` yet
(`git merge-base --is-ancestor`), and requires a successful `plan.yml` run with a valid, non-expired
`plan` artifact for the candidate's PR head sha, falling back to older PRs until one qualifies. The
existing explicit `-CommitSha` override is unchanged in behavior; its docs now clarify it must be a
PR head sha, not a `main` merge/squash commit. PR: Nerdy-Potato/sf-intune-cac#21.
**Why:** `deploy.yml`'s recovery-mode verify step requires `reviewed_sha` to equal a merged pull
request's `head.sha` (pre-merge branch tip), not the squash-merge commit that lands on `main`. Since
this repo merges via `gh pr merge --squash`, `git rev-parse main` almost never equals any PR's head
sha, so the old default reliably failed with "Commit X is not the merge commit of a pull request."
This blocked the live solo-maintainer recovery redeploy needed after deleting 10 stuck Intune mobile
app objects (`publishingState: 'processing'`). Also documented (not code-fixed) a related plan-
staleness gotcha in the script's `.NOTES`: a Plan run's `plan.json` reflects tenant state only as of
plan time, so redeploys after manual tenant-state changes (like remediation scripts) need a fresh PR
touching `config/**`/`src/**`/`scripts/**` to get a plan reflecting current reality before reusing
this recovery script. That freshness check itself is intentionally out of scope for this fix.
