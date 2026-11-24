# Changelog

## 0.1 (unreleased)

The first public source release. Spacewise is an early alpha.

- Scan the startup disk, or one folder on the startup drive. Scans read names, sizes and filesystem metadata only.
  Choose a folder, drop one on the window or the Dock icon, or open one with the app.
- Explore live results while a scan runs in a zoomable storage map, a file-type list, a sortable item list and an
  inspector. Stop keeps the results found so far.
- See allocated and logical sizes separately. Hard-linked files are counted once, and a folder that could not be
  read is shown as unknown rather than empty.
- Filter the open folder by name and sort the item list. Wide folders filter and sort in the background.
- Scan Details lists what could not be read and why. After a denial you can open Privacy & Security settings and
  rescan.
- Reveal an item in Finder, copy its path, open it or preview it with Quick Look. Open and Quick Look check that the
  item still matches the scan first.
- Move one eligible personal file to the system Trash after confirming its path. Spacewise rechecks the file before
  the move and rescans afterwards.
- Help includes an offline Privacy Policy. The app has no account, analytics, update check or network client.
- Build, sign, install and open the app from source with `./scripts/setup.sh`, signed ad-hoc or with an existing
  certificate. The installer keeps the previous build for rollback.
