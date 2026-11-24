# Architecture

How a scan turns into what the window shows, and the guarantees each layer gives the next. Read
[SCAN-POLICY.md](SCAN-POLICY.md) first for what is scanned and why. Everything here is in `Sources/`; the names
below are the real file names.

## The pieces

| Target | What it holds |
| --- | --- |
| `SpacewiseCore` | The scanner, the data it produces, and every rule about presenting it. No AppKit. |
| `SpacewiseAppModel` | The app's decisions as plain values (which commands are enabled, where navigation goes, what each panel shows), so they can be tested without a window. |
| `SpacewiseApp` | The AppKit app. It lays out what the other two decide. |
| `SpacewiseControl` | A development helper the scripts use to find and quit the installed app. Not shipped. |

`Tests/SpacewiseFixtures` holds made-up scan results shared by the core, app-model and native AppKit tests. The app
reads no launch arguments.

Inside `SpacewiseCore`:

- **Scanning:** `Scanner.swift` is the entry point, `Scanner.scan(plan:…)`. `ScanRun.swift` holds the state of one
  scan and advances it in steps: record why discovery left things out, validate the roots, enumerate one directory at
  a time, then finalize. `DriveDiscovery.swift` and `MetadataProcess.swift` decide which volumes belong to the
  startup drive (bounded runs of `diskutil info -plist`, `diskutil apfs list -plist` and, when the system boots from a
  snapshot, `diskutil apfs listSnapshots` and `diskutil list -plist`, on the scanner's worker). `apfs list` names
  each container's volumes; where a volume is mounted comes from `info` for its device. One pass makes about forty
  queries and shares a 20-second deadline. A chosen-folder scan verifies the selected
  mount against the startup disk using bounded metadata queries for that mount and the boot volume. It scans only
  the selected folder. Under `/Volumes`, the selection must be at or below the verified mount and resolve to its
  own path. The traversal exception is limited to that selected subtree and preserves mount boundaries and
  inspection-only eligibility.
  `ScanPolicy.swift` and `MetadataPolicy.swift` hold the path and placeholder rules. `Coverage.swift` holds the
  coverage records.
- **Results:** `ScanContract.swift` (the node, progress and plan types), `ScanResult.swift` (the settled result and
  its index), `ProgressiveIndex.swift` and `ScopeSnapshot.swift` (the live view of a running scan).
- **One drive:** `LogicalNamespace.swift`, `NamespaceBuilder.swift` and `SlotList.swift` present the startup drive
  as a single tree.
- **The map:** `Treemap*.swift`.
- **Wording and numbers:** `Presentation.swift`, `ProductCopy*.swift`, `ScanDetails.swift`, `Formatting.swift`.

## Measuring

One worker owns the scan: one directory open at a time, cancellation checked between entries. Every directory is
`lstat`ed, opened with `O_NOFOLLOW | O_DIRECTORY`, and checked again through its descriptor before it is listed.
Entries are read with `fstatat` relative to that descriptor. Regular files are never opened.

- **Allocated size** (shown as Size) is the reported `st_blocks × 512`. **Logical size** (shown as Logical Size) is
  `st_size`. A directory has no size of its own; its totals are the sum of what is inside.
- **Hard links** share an identity (device and inode). The bytes are counted once, on the link with the lowest path
  (compared as raw UTF-8); the others stay visible and say where their bytes are counted. Which link owns the bytes
  can change until enumeration ends.
- **Cloned files** (APFS) report their full allocation each time, so clones are counted in full for every copy.
  Allocated bytes are what files report. They are not unique physical blocks and not a promise of space freed.
- **Packages** (`.app`, `.framework`, `.bundle`, `.photoslibrary` and a few more, by extension) count as one
  navigable item whose contents are included once. This is a name rule, not a Launch Services lookup.
- **Symbolic links** and special files are listed with zero size. **Cloud placeholders** (`SF_DATALESS`) keep their
  logical size and have unknown allocation.
- **Which volume a path is on** comes from `statfs.f_fsid`, not `st_dev`. On a current Mac the system and data
  volumes share `st_dev` but have different `f_fsid`, and the data volume is also reachable through firm links under
  `/`. The scanner traverses each root once and treats every cross-volume firm-link as a boundary, so nothing is
  counted twice.
- The result carries a start and end time. It is not an atomic snapshot of the filesystem.

Every folder ends in one state. It is listed to the end, or stopped by cancellation, or ends in one of three terminal
states that always come with an issue on the node and are never retried: `skipped` (deliberately not opened: excluded
by policy, on another volume, or a cloud placeholder), `openFailed` (could not be opened, or was no longer the folder
that was discovered) or `listingFailed` (opened, but reading its entries failed part-way). The states are
`DirectoryEnumeration` in `Coverage.swift`.

## Live results

A scan publishes aggregate progress at most every 200 ms. The callback is awaited, so the worker never runs ahead of
its consumer; there is no queue of updates. While a scan runs, the window can navigate and page through what has been
found so far:

- The window asks for a folder and a page offset. The worker answers at its next checkpoint with a `ScopeSnapshot`:
  at most 256 rows (`ScopeSnapshot.pageSize`), a scan id, a revision number and the request it answers. The app keeps
  only the latest request and drops any snapshot whose scan, request or revision is out of date (`isCurrent`). The
  full node array is never copied out of the worker.
- Live snapshots page in discovery order. The item list sorts each live page in the requested direction. A measured zero
  has a numeric sort key. A positive partial folder total sorts by the displayed lower bound. Unknown and uncounted
  sizes sort last in both directions. The worker tracks unresolved children so a fully measured empty subtree can
  show zero during a scan. When the scan settles, sorting covers the entire folder.
- Pages cost O(rows), not O(folder). Final indexing size-ranks each folder’s range on the worker, with one integer
  per entry plus a range per folder. The worker polls cancellation during ranking and namespace construction.
  Stopping can leave unranked ranges. The list orders a retained range when its folder opens. For a range larger
  than one live page, that work runs off the main actor and navigation cancels it. The map selects the heaviest
  children within its usual work budget. Totals and coverage still need a linear pass over the retained nodes.
- A ranked physical folder shares its existing row order. Merged ordering, filters and custom sorts on settled
  folders wider than 256 rows use background work on the immutable scan result. The session checks result
  and scope before installing an order. The query cache checks row-source identity and query before publishing
  a filtered or sorted list. Equal keys keep their source order.
- The scanner commits the result and its topology before sending terminal callbacks. The terminal snapshot uses
  that result’s topology. The AppKit session installs the result in one main-actor step and honors Stop until
  that step runs.

## One drive, rooted at `/`

The scanner produces separate roots (the system volume as `/`, the data volume, and any admitted auxiliary
volume). `LogicalNamespace` overlays them as one tree so people see their disk, not its implementation:

- A folder that is a real directory on two volumes (`/System`, `/usr`, `/private` and so on) merges recursively into
  one folder whose totals are the sum of its members. A firm-link stub (an empty directory on one side) is absorbed by
  the real folder on the other. Files that share a name never merge and both stay visible.
- A merged folder keeps its lowest member id, so ids never change as the scan grows. Every physical location stays
  available to the inspector.
- The system-managed items (`/System`, `/usr`, `/private`, `/bin`, `/sbin`) and the auxiliary volumes form one
  synthetic group whose total is cached and updated by signed deltas, so asking for it costs the same however large
  it is.
- A growing merged namespace is admitted incrementally, one name group at a time, with cancellation checked per
  group, instead of being rebuilt at every checkpoint. In a synthetic test at one million entries this was about ten
  times less checkpoint work than rebuilding each time, with identical results.
- Folder scans use the identity namespace: nothing is merged.
- A stopped drive scan without a settled unified namespace opens at the retained volume roots. The old managed
  group or merged-folder view is cleared with its selection and map. Each retained volume can be browsed from
  this root list. If the worker already finished the unified namespace when Stop reached the session, the
  session can keep that topology and the current scope.

## The map

`TreemapModel` is an immutable, bounded value of at most `TreemapLimits.maxTiles` tiles (8,000 for a settled scan,
4,000 while scanning), however large the scan.

- Tile area is allocated size; colour is file type, from the name and extension only, in ten saturated types plus
  structural groups.
- **Largest first.** A heap of per-folder cursors always draws the heaviest item not yet drawn whose parent is drawn,
  so a very large file five folders deep gets its own tile.
- **Exact remainder.** What is left in an expanded folder becomes one "N smaller items" tile weighing exactly the
  parent minus what was drawn, so every level adds up. Folders not expanded before the budget ran out are drawn as
  hatched blocks. Items with no known size (denied, unread, placeholders, hard-link aliases) have no area and are
  never shown as zero.
- **One cost budget.** Every read a build makes (choosing children, building rows, sampling a block to tint it) is
  charged to a single ledger of 1,500,000 (`maxCost`). A refused expansion keeps the folder's exact weight as a
  block rather than losing area.
- Built off the main thread, cancelled on navigation; a result for a stale scope is dropped. While scanning, a new
  map is held back behind an "Update Map" chip if the person is pointing at a tile or has one selected, so tiles
  do not move under the pointer.

## Coverage and status

Items and rows carry a coverage reason and, for failures, the raw `errno`. `Coverage.swift` keeps counts exactly and
at most 256 location records (see [SCAN-POLICY.md](SCAN-POLICY.md)). `ScanDetails.swift` groups them as "Needs
attention" and "Expected limits"; locations are one further disclosure. Presentation rules (wording, one status line,
plural and share formats) live in `Presentation.swift` and `ProductCopy*.swift`, which the tests check, including a
scan of every string for forbidden claims.

## Cost and limits

Measured with the installed app on one machine (Apple M3 Max, internal SSD), scanning real folders; indicative, not
a promise:

| Folder scanned | Entries | Scan time | Peak memory |
| --- | --- | --- | --- |
| An applications folder | 406,000 | 5 seconds | about 280 MB |
| A package manager's tree, with 320,000 hard links | 2,115,000 | 28 seconds | about 900 MB |

Those times are with the filesystem's metadata already cached. The first scan after a restart reads it from disk and
took 74 seconds for the smaller folder. In both folders the entry count matched `find` and the total size matched
`du` to the kilobyte.

Memory grows with the number of entries, at roughly 0.4 GB per million, and the result stays in memory while it is
shown. A startup disk holding ten million files therefore needs several gigabytes. Peak memory is the main known
limit. Benchmarks are opt-in and described in `Tests/README.md`; the normal `swift test` stays fast and small.

Not yet tried: real cloud providers, a volume disappearing mid-scan, and trees of tens of millions of entries
(cancellation during final indexing has no measured bound there).
