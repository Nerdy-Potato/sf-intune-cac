# Squad Decisions

## Active Decisions

### 2026-08-16T23:15:16.465-05:00: PR #13 merge was unblocked without relaxing deploy safety gates
**By:** Scribe
**What:** Switch fixed the CI-only strict-mode Pester failure in `tests/Plan.Tests.ps1`, unblocking PR #13 and merge commit `ced3668745b8c96e885cd89529925e3d1dc6b115`. The main deploy run then correctly stopped at the reviewed-commit approval gate, so only the child-tier app/adoption work from the merged PR was advanced and Microsoft Authenticator adoption remains skipped fail-closed pending tenant-owner verification.
**Why:** The team needed the test fix merged while preserving the requirement for a human approval on the reviewed PR head SHA and the separate production environment reviewer gate before any tenant write can run.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
