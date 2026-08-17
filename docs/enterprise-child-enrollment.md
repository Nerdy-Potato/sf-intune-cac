# Enterprise child enrollment

Emmerick, Broderick, and Cullen are members of the explicit `CaC-Youngest-Children` security group. That group receives the corporate
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

Enrollment tokens, Apple server tokens, and Windows hardware hashes are tenant/device secrets and
are deliberately not stored in this public repository.

## Approved applications

`config/apps/approved-child-apps.json` is the allowlist. Microsoft Defender, Authenticator, Microsoft
365 Copilot, Word, Excel, PowerPoint, OneNote, Outlook, Teams, and OneDrive are required. Edge remains
available for self-service installation. Public stores and unknown-source installation remain blocked.

Android and iOS store objects are created and assigned by the deployment engine. Two Windows
packages are explicit prerequisites because Microsoft doesn't expose tenant-specific installers as
stable public packages:

- Add **Microsoft 365 Apps for Windows** in Intune using the Microsoft 365 Apps app type.
- Download the Windows GSA client from the tenant's Global Secure Access client-download page,
  package it as a Win32 app, and name it **Global Secure Access Client**.

The plan reports either package as `Prerequisite` until it exists, and never pretends it was deployed.

## MDE and Global Secure Access

On Android, Defender is required and its managed-device app configuration sets `Global Secure Access`
and `GlobalSecureAccessPrivateChannel` to `3`, which turns them on and prevents user disablement.

On iOS/iPadOS, Defender is required and the on-demand custom VPN profile uses the Defender bundle
identifier, silently onboards, connects for all domains, disables split tunneling, and blocks user
override.

On Windows, the GSA Win32 package is required. The tenant must also have the Internet Access traffic
forwarding profile enabled and assigned to `CaC-Youngest-Children`; traffic forwarding profiles are Entra
Global Secure Access objects rather than Intune objects.

## Scheduled device lock

The requested 8:30 PM school-night and 10:00 PM weekend full-device lock is not represented as an
Intune policy because Intune exposes inactivity locks but no cross-platform time-of-day device lock.
Applying and removing kiosk profiles on a timer would depend on nondeterministic device check-in and
could strand a device offline. Do not describe that workaround as enforced screen time.
