# Tests

```
swift test                      # the normal suite: fast, small, no benchmarks
swift test --filter ScannerTests
```

The default suite includes filesystem integration tests. Scanner tests use temporary folders. Some tests inspect
the host's volume identity and firmlinks. Routine Trash tests create a disposable folder under the current home
to exercise the real eligibility policy and use an injected mover for confirmed operations. Scans stay inside
their fixtures. Scale regressions use work counters and reference results. `ScanCadenceTests` checks the live map
update cadence with an injected clock.

## Layout

- `SpacewiseCoreTests/`: one test target for the core library, grouped by behaviour (scanner, coverage, namespace
  merging, treemap, presentation). `DriveDiscoveryAndMetadataProcessTests.swift` covers drive discovery and its
  bounded metadata subprocess.
- `SpacewiseCoreTests/Support/`: helpers shared by several files: `Fixture` (temporary directory), `Tree` and the
  functions that feed it to the index and namespace the way the scanner does, `CountingSource`, `IndexWorkCounter`,
  `SteppingClock`, and the logical namespace test helpers in `LogicalNamespaceTestSupport.swift`.
- `SpacewiseFixtures/` holds the made-up scan results shared by the test targets.
- `SpacewiseCoreTests/Benchmarks/` contains the opt-in scale and rendering benchmarks described below.
- `SpacewiseAppModelTests/` exercises commands, navigation, filters, sorting, status, layout and quit handling.
- `SpacewiseAppTests/` exercises Stop and settlement with fixture results. The map tests resize an AppKit
  window, sample its drawing, send pointer and keyboard events, and invoke accessibility actions.

## Benchmarks

Million-entry runs and tests that only print numbers are skipped in a normal run. Run them in release mode:

```
SPACEWISE_BENCH=1 swift test -c release --filter ScaleBenchmarks
```

This prints `BENCH ...` lines: append work and time for a million-entry namespace, cancellation latency during a
build, and weighted-category construction. The numbers are observations; the assertions are the same counters the
small runs in the normal suite check.

The storage map's layout, raster and image hand-off have their own timing benchmark:

```
SPACEWISE_BENCH=1 swift test -c release --filter TreemapRenderBenchmark
```

The index benchmark runs one cell per process, so its peak memory is that cell's own:

```
SPACEWISE_BENCH_CELL=1000000-merged swift test -c release --filter indexScaleBenchmark
```

Cells are `{100000, 1000000}` entries by `{broad, merged}`. Add `SPACEWISE_BENCH_CONTROL=rebuild` to run the same
engine with a forced namespace rebuild at every checkpoint, for comparison.

## System Trash integration

Use a disposable local standard account with the short name `spacewise-trash-test` and its own home directory.
Sign in to that account and use a checkout it owns. Initialize the home Trash through Finder if needed, and use
a terminal that can inspect and write that account's `~/.Trash`. The home and Trash must be on the same volume.
Run the opted-in integration in that account.

```sh
SPACEWISE_SYSTEM_TRASH_TEST=1 swift test --filter SystemTrashIntegrationTests
```

The test moves one uniquely named regular file and checks the returned Trash path, file identity and contents.
It rescans the fixture, restores the file, and checks that both the Trash entry and fixture directory are gone.
Restoration is registered before the move and falls back to the preflighted Trash path if the OS returns no URL.
On failure, retain the test output and check the reported fixture and Trash paths before disposing of the account.
To check the installed app, confirm that dismissing a successful Trash report rescans the original folder.
Use Finder’s Put Back to restore the disposable file and compare its contents.

## Native handoffs and wide-folder interaction

Run the Open and Quick Look acceptance test in a graphical login on macOS. It asks Launch Services to open
a disposable empty app bundle and drives the shared Quick Look panel on disposable text files.

```sh
SPACEWISE_NATIVE_HANDOFF_TEST=1 swift test --filter ItemHandoffTests
```

Run each million-row interaction fixture in its own release test process. Both exercise AppKit navigation,
filter and sort handlers, superseded requests and process memory sampling. Timing includes polling for rows.

```sh
SPACEWISE_WIDE_QUERY=1000000-plain swift test -c release --filter wideListInteractionBenchmark
SPACEWISE_WIDE_QUERY=1000000-merged swift test -c release --filter wideListInteractionBenchmark
```
