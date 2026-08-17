### 2026-08-16: Unblock child Android/iOS app deployment by removing non-deployable extras
**By:** Trinity
**What:** Removed the one-time Microsoft Authenticator adoption entries from `config/tenant.json` and removed the child-tier Windows `existing` app entries from `config/apps/approved-child-apps.json`.
**Why:** The Authenticator adoption entries are fail-closed because the tenant's immutable app identities do not match the configured adoption identities, so leaving them configured blocks deployment without changing the existing tenant apps. The Windows entries require manual tenant-side app creation that this pipeline cannot safely perform, and they are unrelated to the immediate child mobile M365 rollout.
