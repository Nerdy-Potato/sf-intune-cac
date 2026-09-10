# Enterprise child enrollment

Emmerick, Broderick, and Cullen are members of `CaC-Tier-Child`. That group receives the corporate
enrollment restriction, platform security profiles, approved app catalog, MDE, and GSA policies.

## Enrollment posture

| Platform | Required enrollment | Result |
| --- | --- | --- |
| Android | Corporate-owned fully managed (Device Owner), Android 11+ | No personal profile, no unmanaged app sources, MDE required |
| iPhone/iPad | Apple Automated Device Enrollment with supervision, iOS/iPadOS 16+ | Enrollment cannot be removed and the forced GSA VPN profile applies |
| Windows | Windows Autopilot, Entra joined, standard user | Store remains blocked; software arrives through Intune |

The child enrollment restriction blocks personally owned enrollment on all three platforms. It does
not turn an arbitrary BYOD enrollment into a corporate device. Before a device is handed over:

1. Assign Apple serials to the Intune MDM server in Apple Business Manager and use an ADE profile
   with supervision, user affinity, modern authentication, and locked enrollment.
2. Use an Android corporate-owned fully managed enrollment token. Do not use work profile or Device
   Administrator enrollment.
3. Register Windows hardware hashes with Autopilot and assign a user-driven Entra join profile that
   creates a standard user. Run `bootstrap/Initialize-CaCAutopilotDevicePreparation.ps1` first; it
   makes the Intune Provisioning Client service principal the owner of the assigned child device group.
   The same script also supports `-Tier adult` and `-Tier teen` (default remains `child` for backward
   compatibility) to create/own the equivalent `CaC-Autopilot-DevicePreparation-Adult`/`-Teen` groups
   for those tiers. As with the child tier, this repository only automates the group and service
   principal ownership prerequisite - the Autopilot Device Preparation enrollment policy objects
   themselves (one pointed at each of the three groups) must still be created manually in the Intune
   portal.

Enrollment tokens, Apple server tokens, and Windows hardware hashes are tenant/device secrets and
are deliberately not stored in this public repository.

## Approved applications

`config/apps/approved-child-apps.json` is the allowlist. Microsoft Defender, Microsoft Copilot,
Word, Excel, PowerPoint, OneNote, Outlook, Teams, and OneDrive are required. Edge remains available
for self-service installation. Public stores and unknown-source installation remain blocked.

Android and iOS store objects are created and assigned by the deployment engine. Two Windows
packages are explicit prerequisites because Microsoft doesn't expose tenant-specific installers as
stable public packages:

- Add **Microsoft 365 Apps for Windows** in Intune using the Microsoft 365 Apps app type.
- Download the Windows GSA client from the tenant's Global Secure Access client-download page,
  package it as a Win32 app, and name it **Global Secure Access Client**.

The plan reports either package as `Prerequisite` until it exists, and never pretends it was deployed.

## MDE and Global Secure Access

On Android, Defender is required and its managed-device app configuration sets `Global Secure Access`
and `GlobalSecureAccessPrivateChannel` to `3`, which turns them on and prevents user disablement. That
app-config setting only stops the user from disabling GSA inside Defender; it doesn't force every
other app's traffic through the tunnel. `android-fully-managed-restrictions-child.json` also sets
`vpnAlwaysOnPackageIdentifier` to the Defender package (`com.microsoft.scmx`) with
`vpnAlwaysOnLockdownMode: true`, so the device has no network connectivity at all unless the GSA
tunnel is connected - closing the gap where another app could bypass Global Secure Access entirely.

On iOS/iPadOS, Defender is required and the on-demand custom VPN profile uses the Defender bundle
identifier, silently onboards, connects for all domains, disables split tunneling, and blocks user
override.

On Windows, the GSA Win32 package is required. The tenant must also have the Internet Access traffic
forwarding profile enabled and assigned to `CaC-Tier-Child`; traffic forwarding profiles are Entra
Global Secure Access objects rather than Intune objects.

The web content filtering policy, security profile, and the Conditional Access policy that links them
to Global Secure Access are Entra objects, not Intune objects, and are configured manually - the same
as the traffic forwarding profile above. This repository does not create or validate them.

## Windows local admin and LAPS

Adult and teen productivity accounts do not need Entra ID or other cloud administrator roles to be
local administrators on enrolled Windows devices. Local administrator membership is assigned by the
device-scoped local users and groups Settings Catalog policies:

- Adults: `CaC-Tier-Adult` is added to Administrators on adult, teen, and child device groups.
- Teens: `CaC-Tier-Teen` is added to Administrators on teen and child device groups.
- Children: no child tier group is added to local Administrators.

`LAPS-Shell` configures Windows LAPS to rotate the password for the local administrator account named
`x3nc0n`, but that setting alone does not create a custom local account in default/manual LAPS mode.
The companion `CaC - Windows LAPS - Shell Account Management` custom device configuration enables
Windows LAPS Automatic Account Management using documented LAPS CSP OMA-URI nodes so supported
devices create and manage the `x3nc0n` custom local administrator account automatically. Automatic
Account Management requires Windows 11 24H2 or later (or Windows Server 2025+); older Windows builds
still need the account created by another supported mechanism before LAPS can manage its password.
No local administrator password is stored in this repository.

### Known limitation: Android Private DNS

Android's system-wide Private DNS (DNS-over-TLS) setting isn't exposed by Intune for Android
Enterprise device owner devices - not through `deviceConfigurations`
(`androidDeviceOwnerGeneralDeviceConfiguration` has no such property) and not through the settings
catalog. If a child device operator manually turns on Private DNS, it can bypass Global Secure
Access's DNS-based visibility even with Always-on VPN lockdown enforced (lockdown blocks all
non-tunneled traffic, but doesn't change what DNS resolution path the OS chooses inside the tunnel).
The only documented way to enforce this is OEM-specific OEMConfig (for example, Samsung Knox Service
Plugin), which isn't portable across device manufacturers, so it isn't implemented here.

### QUIC/HTTP-3 bypass mitigation

Global Secure Access web content filtering can't inspect QUIC (UDP 443): matching traffic bypasses
the filtering policy entirely instead of falling through to the policy's default action. Both Chrome
and Edge enable QUIC by default, and Android has no OS-level firewall rule (unlike Windows'
`New-NetFirewallRule` block) to force a fallback to inspectable TCP. The only two browsers permitted
on the corporate-owned child devices are Chrome (preinstalled, not a Play Store deployment - see the
`android-chrome` app entry note) and Edge, so `android-chrome-quic-child.json` and
`android-edge-quic-child.json` push the Chromium `QuicAllowed: false` managed configuration to both,
forcing them onto TCP/443 so Global Secure Access can evaluate the SNI against the filtering policy.
Edge's support for this key isn't exhaustively documented by Microsoft (it's inherited from Chromium)
- verify with a traffic log check after rollout.

## Scheduled device lock

The requested 8:30 PM school-night and 10:00 PM weekend full-device lock is not represented as an
Intune policy because Intune exposes inactivity locks but no cross-platform time-of-day device lock.
Applying and removing kiosk profiles on a timer would depend on nondeterministic device check-in and
could strand a device offline. Do not describe that workaround as enforced screen time.
