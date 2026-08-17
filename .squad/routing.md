# Work Routing

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|---------|
| Scope, architecture, review | Morpheus | Deployment design, resource lifecycle, cross-cutting decisions |
| Graph and PowerShell engine | Trinity | Microsoft Graph requests, payloads, plan/apply behavior |
| GitHub Actions and deployment | Tank | Workflow permissions, environments, secrets, deployment gates |
| Testing and validation | Switch | Pester coverage, schema validation, regression checks |
| Security and tenant policy | Mouse | Safety rules, identity boundaries, delete protection |
| Session logging | Scribe | Decisions and session records |
| Work monitoring | Ralph | Backlog and follow-through |
| RAI review | Rai | Content safety and privacy |
| Claim verification | Fact Checker | Verify APIs, action behavior, and dependencies |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Morpheus |
| `squad:{name}` | Pick up issue and complete the work | Named member |

## Rules

1. Morpheus owns cross-cutting deployment decisions.
2. Trinity and Tank coordinate engine behavior with workflow wiring.
3. Mouse reviews every change that can write to the production tenant.
4. Switch may reject fixes without regression coverage.
5. Scribe records decisions; agents use the decisions inbox rather than editing decisions.md directly.
