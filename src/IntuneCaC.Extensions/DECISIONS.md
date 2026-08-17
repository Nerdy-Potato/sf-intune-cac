# Decision points - IntuneCaC.Extensions reference implementation

This module is staged, not deployed (see [`README.md`](README.md)). Nothing below has been decided
yet - it is the list of judgment calls made while building the reference implementation, each of
which needs your explicit sign-off (or a different answer) before any of it is promoted into the
production `IntuneCaC` module, wired into CI, or run against the tenant.

For each item: what was assumed, why, and what the alternative would look like.

## 1. Endpoint Security: Endpoint Detection and Response (EDR) template is unsupported

`Get-CaCExtendedResourceMap`'s `endpointSecurityIntents` entry hard-excludes template id
`e44c2ca3-2f9a-400a-a113-6cc88efd773d` (EDR), matching IntuneCD's own skip of that template.

- **Assumed:** we don't manage EDR intents via this module for now; if you have (or want) an EDR
  policy, it stays a manual/portal object.
- **Alternative:** build explicit support once we've confirmed the EDR template's settings shape
  against this tenant. Not hard, just not done yet - lower priority than the kinds you're actually
  waiting on for the kids' devices.

## 2. Conditional Access default state is report-only, and enabling requires an explicit flag

`Test-CaCConditionalAccessSafety` blocks any policy with `state: enabled` unless the caller passes
`-AllowEnabledState`. The safe default is `enabledForReportingButNotEnforced`.

- **Assumed:** a new or changed Conditional Access policy should always be observable in
  report-only mode first, and never silently flip to enforcing just because it's in a config file.
- **Alternative:** trust the config file's `state` value directly. Given CA's blast radius (a bad
  policy can lock out every admin, including you, at once), I'd keep the explicit opt-in unless you
  disagree.

## 3. Every Conditional Access policy must exclude a break-glass group

`Test-CaCConditionalAccessSafety` refuses to apply any CA policy whose
`conditions.users.excludeGroups` does not contain a configured break-glass group object id.

- **Assumed:** you have (or will create) a dedicated break-glass account/group excluded from every
  CA policy, and its object id gets passed in as `-BreakGlassGroupObjectId`.
- **Open question for you:** does that break-glass group already exist in the tenant? If not, this
  is a prerequisite before any CA policy from this module could ever be applied.

## 4. Conditional Access assignment (`conditions.users`) is create-only, not updatable

If `conditions.users` differs between desired and actual state, `Test-CaCConditionalAccessSafety`
hard-blocks the update entirely (not just a warning) and tells the caller to delete and recreate the
policy instead.

- **Assumed:** matching IntuneCD's own limitation (`handle_assignment = False` in
  `ConditionalAccess.py`) is the right call here, rather than attempting our own in-place update
  logic that IntuneCD's authors apparently decided wasn't safe to build.
- **Alternative:** build real update support for `conditions.users`. Possible, but is real net-new
  work beyond "reference the gap IntuneCD already closed" - flagging as a real decision rather than
  assuming you want it.

## 5. Endpoint Security `settingsDelta` read-shape is unconfirmed

`TreeReadPath` is deliberately `$null` for `endpointSecurityIntents` because the exact Graph
read shape (per-category settings sub-resource vs. a flattened endpoint) was not confirmed against
a live tenant. Until it is, the diff engine falls back to "always treat as Update" (unconditional
resend) rather than risk a wrong diff - the same fallback the production engine already uses
elsewhere for opaque trees it can't safely diff.

- **Needs:** one real read against this tenant's `deviceManagement/intents/{id}` (or its
  sub-resources) to confirm the shape, so real drift detection can replace the always-resend
  fallback.

## 6. Which resource kinds do you actually want first

The module supports all five kinds equally, but you likely only need one or two for the kids'
devices right now.

- **Needs your input:** which of Settings Catalog / Endpoint Security / Conditional Access /
  Assignment Filters / Proactive Remediation are in scope for the kids' Android setup, versus
  "build later when we get to EPM/adult-admin work."

## 7. Naming/namespace conventions for the new kinds

Production config files live under `config/intune/` with a naming convention I didn't want to
guess at by inventing new subfolders without checking with you first.

- **Needs your input:** where new config files for these kinds should live once (if) this gets
  promoted - e.g. `config/intune/settings-catalog/`, `config/intune/conditional-access/`, etc., and
  whether the `managed by sf-intune-cac` marker convention should carry over unchanged.

## 8. Proactive Remediation scripts need a review step before ever touching the kids' devices

`Get-CaCScriptContentDrift` deliberately never prints script content into a diff message (only
line-count deltas), specifically so a script's actual body isn't silently pushed to a kid's device
without a human reading it first.

- **Assumed:** you want to read the full script body yourself (via `git diff`, not the plan output)
  before any Proactive Remediation script is ever assigned to the kids' devices.
- **Needs your input:** is that the right level of caution, or is line-count-only too little detail
  for the plan to be useful in a PR review?

## 9. Assignment Filters are referenced, not self-assigned

Filters don't get their own assignment pass; other resources' assignment targets carry
`assignmentFilterId`/`assignmentFilterType`. This module's own `New-CaCExtendedPlan` doesn't yet
wire filter ids into the other four kinds' assignment targets - it only creates/updates/diffs the
filter object itself.

- **Needs your input:** do you actually need filter-scoped assignment (e.g. "this app only to
  Android devices below a certain OS version") for any of the kids' apps right now, or is a plain
  group assignment enough for the current scenario?

## 10. Groups stay the production engine's job

`Invoke-CaCExtendedPlan` requires a `-GroupObjectIds` map supplied by the caller; it does not create
or reconcile groups itself.

- **Assumed:** this is correct and shouldn't change - group management staying in one place (the
  production engine) avoids two systems fighting over the same Entra groups. Flagging it here only
  so it's an explicit, visible boundary rather than something you discover by accident.
