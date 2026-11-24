# Scan scope and coverage policy

What Spacewise scans, what it leaves out and why, and how it reports what it could not read. The code that
implements this is in `Sources/SpacewiseCore` (`ScanPolicy.swift`, `DriveDiscovery.swift`, `Coverage.swift`,
`ScanRun.swift`); [ARCHITECTURE.md](ARCHITECTURE.md) describes how the pieces fit.

## What a scan covers

Opening Spacewise by itself shows the ready screen. Choosing a scan or opening a folder with Spacewise, including
at launch, requests a scan. A successful Move to Trash refreshes the current scan. A denial does not trigger an
automatic retry.

- **Startup Disk** measures everything readable on the startup drive and presents it as one tree rooted at `/`. That
  includes the home folder with its hidden folders, `Library`, Application Support, developer libraries,
  system-managed files where they can be read, and the volumes macOS mounts under `/System/Volumes` that provably
  live on the same physical drive (the macOS data volume, VM, Preboot, Update and so on). Content is not left out
  just because it is large, hidden or not safe to delete. Volumes on that drive that are not mounted, such as
  Recovery, are listed in Scan Details and not measured: Spacewise mounts nothing. A volume you created on the
  startup drive is treated as another volume and not followed; scan it with Scan Folder.
- **Scan Folder** measures one folder the person picks. The folder must be on the startup drive; its scope is that
  folder only. A mount or subfolder under `/Volumes` is eligible for an explicit scan when Spacewise verifies its
  mount is on the same physical startup drive.

Both scans read names and filesystem metadata only. See [Permissions](#permissions-and-privacy).

### What is left out, and why

Each exclusion is by an explicit rule with a stated reason, and the excluded folder is never opened to size it.

| Left out | Reason |
| --- | --- |
| `/dev` and other pseudo filesystems | Not storage. Only the exact path is excluded: a project folder called `dev` is scanned. |
| External, removable and network volumes | Not the startup drive. Spacewise refuses a chosen folder on one and shows the reason in the scan result and Scan Details. |
| Contents of mounted disk images (simulators, installers) | The image's backing file is already counted where it sits. Counting the mounted contents too would count the bytes twice. |
| Contents of the Preboot volume's `Cryptexes` folder | macOS grafts its cryptex disk images there without mounting them, so no volume boundary marks them. The image files beside them are counted. |
| APFS snapshots | They share blocks with the live volume; there is no per-file size to add. |
| Storage with unresolved startup-disk topology | Missing, unreadable or ambiguous APFS backing-store information leaves the relationship unknown. The scan keeps any verified volumes and reports the gap in the status line and Scan Details. |
| Symbolic links | Recorded as zero-size entries and never followed, so a link cannot pull in another folder or loop. |
| Cloud placeholders | Their local allocation is unknown, and nothing asks the provider to download them. Their reported size stays visible. |

A path rule alone never admits a volume. A volume is admitted by identity: it must be local, not removable, and on
the startup drive according to the system's volume topology, and each directory is re-checked through its open
descriptor (inode, device and filesystem id) before it is listed.

`/Volumes` itself is excluded. A chosen mounted folder must resolve to its own path within the verified mount, and
its contents are inspection-only. Ordinary traversal still treats mount points as boundaries. Startup Disk can
discover and scan verified auxiliary volumes separately.

## Three separate questions about every item

Spacewise keeps these apart, because mixing them produces misleading screens.

1. **Classification:** who manages it. Personal, application-managed (`/Applications`, `/Library`, a home
   `Library`), developer-managed (`/Library/Developer`, a home `Library/Developer`) or system-managed (`/System`,
   `/private`, `/usr`, `/bin`, `/sbin`). Rules match whole path components from the logical root, never substrings
   and never a name list: a folder named `node_modules` or `cache` in your own project stays personal. Classification
   explains ownership. It does not say whether something is safe to remove.
2. **Coverage:** how much of the item was actually read: measured, partly measured, left out by policy, access
   denied, unavailable, or not read yet. A classification never implies complete coverage.
3. **Operation eligibility:** Move to Trash is limited to personal regular files outside excluded areas. It
   requires a complete measurement of the file, a single physical location under the current home and identity
   revalidation after confirmation. Folders, packages and synthetic groups are inspection-only for this action.

System-managed items that can be read are measured and shown as one group, **Managed by macOS**, with their real
paths available in the inspector.

## Unknown is not zero

- A folder that was denied or never opened has an **unknown** size, not a size of zero. Totals above it say "at
  least", and the folder gets no area on the map.
- Unknown propagates upward: a folder holding an unread folder is partly measured.
- "Finished" and "complete" are different. A scan can finish its traversal and still have unread areas; the result
  keeps both facts.
- Volume capacity and free space come from the filesystem and are shown on their own. The app never derives a
  "System Data", "Reserved" or "capacity minus scanned" figure, because snapshots, clones, filesystem metadata,
  unread areas and files that change during the scan all prevent such a figure from being exact.

## Quiet by default, loud when it matters

Limits the scan has on purpose (policy exclusions, volume boundaries, cloud placeholders, unmounted volumes, and
macOS-protected system areas that refuse to be read) are *expected*. A scan whose only limits are expected ends with
a short "Scan complete" and keeps the explanations behind **Scan Details**. Unexpected failures (a folder you chose
that cannot be opened, an item that vanished, a volume that disappeared mid-scan) stay visible and actionable. Denial
is judged per record, with its operation and location, so one kind of failure cannot hide another.

Coverage records keep at most 256 locations. Counts of events are exact; after truncation the count of distinct
locations is unknown and Scan Details says so. Whether a scan needs attention is computed from the exact counters,
never from the retained list, so truncation cannot hide a real denial.

During startup discovery, a backing store identified as external or on another physical disk is quietly excluded.
Unresolved storage counts as an unexpected limit and makes the startup total a lower bound. Cancelling a metadata
query stops discovery without adding a failure for the query that was cancelled. Any earlier findings stay in Scan
Details.

## Permissions and privacy

Scans read names and filesystem metadata only, never file contents. A denial is judged per operation, from what the
system actually returned: the app does not retry, probe other protected folders, or claim to know whether Full Disk
Access is on. [SECURITY.md](../SECURITY.md) is the full statement of what the app reads, what it writes and what it
asks permission for.
