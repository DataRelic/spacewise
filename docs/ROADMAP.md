# Roadmap

Spacewise answers one question: what is taking up space on this Mac, and where is it? It is a native macOS take on
WinDirStat. This page says where the project stands and what comes next. The documents it refers to describe how
things work today:

- [SCAN-POLICY.md](SCAN-POLICY.md): what is scanned, what is left out, how coverage is reported.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the scanner, the data model and the map fit together.
- [LOCAL-DEVELOPMENT.md](LOCAL-DEVELOPMENT.md): building, signing and running from source.

## Where it stands: early alpha

A scan of the startup disk or of one folder, shown as a zoomable storage map, a file-type list, a sortable item list
and an inspector, with live results while the scan runs. Eligible personal regular files can be moved to the system
Trash after confirmation.

Known limits of the alpha:

- Sizes are what files report. Cloned files count in full for each copy, so a total can exceed the space in use, and
  the app does not try to reconcile its total with the disk's free space.
- A folder that could not be read is unknown, not empty. The Modified column is not offered, because the scanner does
  not record modification times.
- Memory grows with the number of files, at roughly 0.4 GB per million, so a startup disk holding ten million files
  needs several gigabytes.
- A folder to scan must be on the startup drive. External and network volumes are excluded. An explicitly chosen
  mount or subfolder under `/Volumes` must have verified startup-drive topology and is inspection-only.
- A Mac that starts up from an external disk or a Fusion Drive cannot be scanned. Startup Disk does not include
  extra volumes you created on the startup drive; scan those with Scan Folder.
- Not yet tried on real input: cloud placeholders from a real provider, a volume disappearing mid-scan, and trees of
  tens of millions of entries. VoiceOver has not been checked by a person.

## Next

1. **More ways to find the big things.** A Largest Files list and an Issues list (what could not be read, and why),
   search across the whole scan, rescanning just the selected folder, multiple selection, a logical-size toggle,
   export and a Modified column.
2. **Scale.** Lower peak memory (chunked node storage is the likely route) and cheaper live updates on very large
   folders.
3. **Settings.** A small Settings window (for example, whether a scan starts when the app opens, which stays off by
   default).

## Implemented protections for Move to Trash

- One eligible personal regular file in the current user's home per confirmation. Scan-time checks exclude
  links, placeholders and managed areas. Folders and packages remain available to browse and show in Finder.
- The sheet shows the selected path and has no default button. After confirmation, Spacewise checks that path,
  the selected file's identity, type and protected metadata immediately before calling the system Trash by URL.
  The path can change between validation and the system move.
- Spacewise reports the outcome and starts a fresh scan after a successful move. It has no permanent-delete
  fallback or empty-Trash action. Finder handles recovery of a trashed item.
- Moving to the Trash does not free space, and the app never subtracts those bytes from what it shows as used.

## Not planned

Accounts, telemetry, a background service or menu-bar mode, duplicate finding, cache recognition, scheduled scans,
and anything that reads file contents.

## Background

- [About Apple File System](https://developer.apple.com/documentation/foundation/about-apple-file-system): clones,
  sparse files, snapshots and shared storage.
- Allocated-size metadata in [Foundation](https://developer.apple.com/documentation/foundation/urlresourcevalues/totalfileallocatedsize).
- [Apple Platform Security: Role of APFS](https://support.apple.com/en-gb/guide/security/seca6147599e/web): shared
  container capacity, volumes and snapshots.
- [Time Machine local snapshots](https://support.apple.com/en-gb/102154): why snapshots hold space.
