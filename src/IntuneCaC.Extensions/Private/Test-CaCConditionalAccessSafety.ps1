function Test-CaCConditionalAccessSafety {
    <#
    .SYNOPSIS
        Mandatory safety rail evaluated before any Conditional Access create or update.
    .DESCRIPTION
        Conditional Access has the highest blast radius of anything in this repository: a bad
        policy can lock every admin, including John, out of the tenant simultaneously. This
        reference implementation therefore refuses to apply a policy at all unless:

          1. A break-glass account/group is explicitly excluded (conditions.users.excludeGroups
             must contain the configured break-glass group object id).
          2. The policy's state is 'enabledForReportingButNotEnforced' (report-only) unless the
             caller explicitly passes -AllowEnabledState, so a new or changed policy is always
             observed in report-only mode before it can ever block a sign-in.
          3. On update, conditions.users (who the policy targets) has not changed. IntuneCD's own
             ConditionalAccess.py does not support updating assignment either
             ("handle_assignment = False") - this reference implementation makes that limitation an
             explicit, loud block rather than a silent no-op, and tells the caller to delete and
             recreate the policy instead.

        These are DECISION POINTS, not settled defaults - see DECISIONS.md. Returns an array of
        human-readable problem strings; an empty array means the policy is safe to apply.
    .EXAMPLE
        Test-CaCConditionalAccessSafety -Desired $policy -Actual $remote -BreakGlassGroupObjectId $id
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Desired,

        [Parameter()]
        [AllowNull()]
        $Actual,

        [Parameter(Mandatory)]
        [string] $BreakGlassGroupObjectId,

        [Parameter()]
        [switch] $AllowEnabledState
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    $conditions = Get-CaCProperty -InputObject $Desired -Name 'conditions'
    $users = Get-CaCProperty -InputObject $conditions -Name 'users'
    $excludeGroups = @(Get-CaCProperty -InputObject $users -Name 'excludeGroups')

    if ([string]::IsNullOrWhiteSpace($BreakGlassGroupObjectId) -or $BreakGlassGroupObjectId -notin $excludeGroups) {
        $problems.Add(
            "conditions.users.excludeGroups must include the break-glass group ($BreakGlassGroupObjectId); " +
            'refusing to apply a Conditional Access policy without a guaranteed way back into the tenant.'
        )
    }

    $state = Get-CaCProperty -InputObject $Desired -Name 'state'
    if ($state -eq 'enabled' -and -not $AllowEnabledState) {
        $problems.Add(
            "state 'enabled' requires -AllowEnabledState to be passed explicitly. The safe default is " +
            "'enabledForReportingButNotEnforced' so a new or changed policy is always observed before " +
            'it can ever block a sign-in. See DECISIONS.md.'
        )
    }

    if ($null -ne $Actual) {
        $actualConditions = Get-CaCProperty -InputObject $Actual -Name 'conditions'
        $actualUsers = Get-CaCProperty -InputObject $actualConditions -Name 'users'
        $desiredUsersJson = ConvertTo-CaCCanonicalJson -InputObject $users
        $actualUsersJson = ConvertTo-CaCCanonicalJson -InputObject $actualUsers

        if ($desiredUsersJson -ne $actualUsersJson) {
            $problems.Add(
                'conditions.users differs from the tenant, but updating who a Conditional Access policy ' +
                'targets is not supported by this reference implementation (matching a documented ' +
                'IntuneCD limitation). Delete and recreate the policy instead of updating it in place. ' +
                'See DECISIONS.md.'
            )
        }
    }

    return $problems.ToArray()
}
