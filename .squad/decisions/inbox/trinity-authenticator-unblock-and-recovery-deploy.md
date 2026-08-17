### 2026-08-16: Remove child Authenticator management and document solo recovery deploy
**By:** Trinity
**What:** Removed the `android-authenticator` and `ios-authenticator` child app catalog entries, updated the offline tests and docs to match, and added `scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1` for the reviewed-commit recovery dispatch path.
**Why:** The tenant already has an unmanaged Microsoft Authenticator app object, so keeping Authenticator in desired state leaves PR #14 permanently blocked on a fail-closed Skip. Removing those entries keeps Authenticator untouched while letting the plan reach `Ready`, and the new script documents the repository's intended deployment path for a solo maintainer who cannot satisfy GitHub's self-approval review rule.
