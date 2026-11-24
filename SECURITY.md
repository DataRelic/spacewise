# Security

Spacewise is an early alpha built from source. See the [local development guide](docs/LOCAL-DEVELOPMENT.md) for signing
and what a development signature verifies.

The app includes an offline policy at **Help > Privacy Policy**.

## What Spacewise reads

Spacewise scans when you choose **Scan Startup Disk**, **Scan Folder…**, open a folder with the app, or drop a
folder onto the window or Dock icon. It rescans the same scope after a successful Move to Trash.
It lists directories under your account and records names, allocated and logical sizes, kinds and filesystem metadata
such as volume and hard-link identity and whether an item is a cloud placeholder.

- During enumeration it reads filesystem metadata, follows no symbolic links and does not request cloud downloads.
  A chosen root is resolved and its mount is checked before traversal. Choosing a remote path can involve the
  operating system looking up that location even though Spacewise excludes remote volumes from traversal.
- It runs `/usr/sbin/diskutil` during startup-disk discovery and when checking a selected folder's mount. The output
  stays in memory. The [scan policy](docs/SCAN-POLICY.md) describes which mounts and folders are eligible.
- **Show in Finder** reveals the selected item. **Open** hands it to its default app. Space or ⌘Y asks macOS to preview
  the selected item with Quick Look. The system or the other app can read that item to open or preview it.

## Permissions

Spacewise launches without asking for access. It runs outside the App Sandbox with no special entitlements. macOS
controls which folders the app can list and may show its own prompts for locations such as Desktop, Documents,
Downloads and other apps' data. The bundle's usage descriptions for Desktop, Documents and Downloads appear in the
system prompts. If you decline, the scan continues and marks affected folders as unread. Spacewise does not retry
denied folders automatically, probe unrelated protected folders or escalate privileges.

Full Disk Access is optional. Spacewise does not request it, change privacy settings or claim to know whether access is
enabled. It uses the result of each filesystem operation. After a denial outside the normally protected system areas,
**Open Privacy & Security Settings…** opens the Full Disk Access list. If you grant access there, run the scan again.

## What Spacewise writes

- Move to Trash is limited to one eligible personal regular file under the current user's home from a settled scan.
  The confirmation shows the exact path. Spacewise checks that path and the file's current type, identity and
  metadata before calling the system Trash by URL. The path can change in the interval between validation and the
  system move. Folders, packages and synthetic groups are inspection-only for this action. Finder handles
  restoring files and emptying the Trash.
- Scan results and their paths stay in memory and are discarded when you quit. The app saves layout in the standard
  preferences for `local.spacewise.app`: the main, Help, Privacy Policy and Scan Details window frames, and the item list's columns and
  sort order. The macOS folder chooser keeps its own state in the same preferences, including the folder it last
  showed and its panel size.
- **Copy Path** or ⌘C on a selected item writes its path to the clipboard.
- The macOS unified log records scan starts, finishes and stops, volume discovery, quit timeouts and failures using
  counts, durations, fixed labels and error codes. It never includes file names, folder names, volume names or paths.
- Spacewise makes no network connections. There is no update check, telemetry, diagnostic upload or account.

## Builds

Spacewise is distributed as source; there are no published builds. A build made without a certificate is signed ad-hoc,
which proves the bundle is intact but not who made it, so build from a copy of the source you trust.

## Reporting a problem

Report a vulnerability privately and keep it out of public issues. On the repository's
[Security tab](https://github.com/DataRelic/spacewise/security), choose **Report a vulnerability**.

Include your macOS version, Spacewise version and build, and steps using a disposable example. Keep personal
paths, scan results, screenshots showing your files and raw logs out of reports. You can edit or delete your own
issues and comments on GitHub. To have something removed from a private report, ask in that report.

Report any way to make Spacewise read file contents, make unauthorised writes, contact a network, act on an item without
being asked or follow a link out of the folder it was given.
