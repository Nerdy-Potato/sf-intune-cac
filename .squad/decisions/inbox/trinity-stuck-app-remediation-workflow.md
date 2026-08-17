# Trinity decision: stuck app remediation workflow

- **Context:** Ten Intune store app objects were confirmed stuck in Microsoft Graph `publishingState:
  processing` for over an hour, and every assignment attempt was already failing because the apps
  never reached `Published`.
- **Decision:** Add a manual-only remediation workflow plus `scripts/bootstrap/Remove-CaCStuckApp.ps1`
  to delete specific stuck `deviceAppManagement/mobileApps/{id}` objects through the existing GitHub
  Actions OIDC Graph identity path.
- **Why:** This keeps the remediation consistent with the repository's CI/CD-first model, preserves
  `-WhatIf` safety for the destructive delete, and documents the approved delete/recreate recovery
  path without weakening the normal deployment workflow.
