# Local development

Build, test and run Spacewise from source. See the [command reference](../scripts/README.md) for options and state
paths.

## Requirements

- macOS 15 or later on Apple silicon or Intel.
- Swift 6.2 or later, available with Xcode 26 or its command-line tools. The scripts use `/usr/bin/python3`.
- The Swift package is the project. Open `Package.swift` in Xcode or use Swift on the command line.

`./scripts/doctor.sh` works with only the command-line tools installed. It fails with a clear message if macOS is
older than 15 or Swift is older than 6.2.

## Build and test

Run the examples from the repository root.

```sh
swift build
swift test
python3 scripts/test_scripts.py
swift format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
```

`swift build` makes a SwiftPM debug build. `swift test` scans only its own fixtures and uses an injected Trash mover.
The [test guide](../Tests/README.md) documents opt-in benchmarks and the disposable-account system Trash integration.
The script unit tests mock external commands, use temporary directories and need no certificate.

`python3 scripts/test_install.py` needs only a built and signed staged bundle. It makes its own previous bundle in a
temporary directory and never reads or writes `~/Applications`.

Local verification includes strict Swift formatting. To apply the checked-in formatting rules:

```sh
swift format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests
```

## Run the app

To install and open the app in one step:

```sh
./scripts/setup.sh
```

`setup.sh` runs `doctor`, then builds, signs, verifies and installs a release bundle at
`~/Applications/Spacewise.app` and launches it. It signs ad-hoc unless you select an identity, so it behaves the same
whatever the keychain holds. To build and run from the checkout without installing:

```sh
./scripts/doctor.sh
./scripts/build.sh
./scripts/sign.sh --adhoc
open .spacewise/Spacewise.app
```

### Signing

| | Ad-hoc | Certificate |
| --- | --- | --- |
| Needs | No certificate | An existing Apple Development or Developer ID Application certificate and unlocked private key |
| Verification | Checks the bundle seal, signing identifier and ad-hoc signature | Checks the seal and signing identifier, and pins the leaf certificate: the selected one, or the one suitable certificate in the keychain |
| Across updates | Each build has a different code hash and Full Disk Access must be granted again | Replacement requires the same designated requirement, so installs should keep their permissions (to be confirmed on your macOS) |
| Who made it | Anyone can re-sign a modified bundle ad-hoc | The signature is tied to the certificate |

For `sign.sh` and `dev.sh`, select a signing identity in this order: `--identity <SHA-1>`,
`SPACEWISE_SIGNING_IDENTITY`, ignored `.spacewise.local.json` (copy the
[example configuration](../scripts/local-config.example.json)), or the sole suitable certificate in the keychain.
Keep private keys and passwords out of configuration. `--adhoc` overrides configured identities and cannot be
combined with `--identity`. The value `adhoc` also works via the flag `--identity`, the environment or the config.
Explicit ad-hoc signing skips the keychain lookup. With no selection and no suitable certificate, signing falls
back to ad-hoc and says so. A missing selected identity or multiple suitable certificates without a selection
stops signing.

Only signing needs the choice. With nothing selected, `verify`, `install`, `relaunch` and `rollback` take the signing
mode from the bundle's own signature, so an ad-hoc build needs no flag after `sign.sh --adhoc` and no keychain lookup.
A certificate-signed bundle is checked against the one suitable certificate in the keychain, and refused when there is
none or several: select one as for signing. On those commands `--adhoc` or `--identity` asserts the expected mode. An
install refuses to switch an installed app between ad-hoc and certificate signing; move the installed app to the Trash
first if you mean to switch. The same transition applies when moving from a local certificate to a release
signature whose designated requirement differs. Verify the delivered release through its distribution flow
and check privacy grants for that identity on macOS.

Both modes verify the bundle structure, native architecture, macOS deployment metadata, empty entitlements and
signed build manifest. Verification uses `codesign --verify --strict`. An ad-hoc designated requirement changes
with the build's hash, so replacement skips the designated requirement comparison for ad-hoc builds.

These steps verify a local development bundle. A downloadable beta needs its own signing, notarisation and
Gatekeeper checks on the delivered artifact.

## The development loop

`./scripts/dev.sh --adhoc` builds, signs, verifies and installs a release bundle at
`~/Applications/Spacewise.app`, then launches that exact copy. It is `setup.sh` without the host check, and it uses
the signing choice described above rather than defaulting to ad-hoc. It holds the checkout's workspace lock and the install
lock for the sequence. Use the individual commands to stop after a stage. A failed build prints the last 30 lines of
the compiler output, and the last 200,000 bytes are saved in `.spacewise/last-error.log`.

Replacement copies the signed bundle to hidden staging on the destination filesystem and verifies it there. The
installer requests a normal quit and waits up to 15 seconds. Refusing to stop an active scan, leaving its
confirmation unanswered or having a conflicting copy running can prevent replacement. The installer writes and
flushes a recovery journal, swaps existing bundles atomically using Darwin's `renameatx_np(RENAME_SWAP)`, and
verifies the installed copy. A verification failure after the swap restores the old verified bundle, leaving any
existing rollback copy available. A failed first install leaves the install path empty. Recovery keeps rejected
candidates and candidates abandoned before an update swap under `stage-<id>.rejected` in the development state
directory for inspection. The next `setup`, `install`, `relaunch`, `dev`, `rollback` or `quit` reconciles an
interrupted journal. Recovery covers process interruption. Power-loss durability is unverified. Leave journal
and active staging paths to the tooling and inspect abandoned copies manually.

The immediately previous verified bundle is available for rollback. An older retired copy can remain until a
successful relaunch. The OS releases the advisory install lock when the command exits.

`SpacewiseControl` is a development CLI with `status` and `quit` commands. It checks the bundle URL against the
canonical install path and refuses to quit a conflicting copy. It runs on demand without privileges. Build refreshes the
helper. If it is absent when needed, the scripts build it and announce that on stderr. The helper also reports failures
on stderr, and `status.sh` reserves stdout for JSON.

## Version and icon

`VERSION` supplies `CFBundleShortVersionString`, with one to three dot-separated integers such as `0.1`. The build
number is generated and monotonic within a checkout. The signed manifest records the build number, release
configuration, SDK, timestamp, deployment target, git revision and dirty state. A source archive, including one unpacked
inside another repository, records revision `unknown` and a null dirty state.

The bundle includes the committed `assets/AppIcon.icns` for Finder, the Dock and the app’s ready screen.
Regenerate it with `swift scripts/make-icon.swift` after changing the artwork, and update `assets/icon.svg` for the README.
The bundle declares `public.folder`
as a viewer with rank Alternate so the Dock accepts folder drops and Finder remains the default. The generated
`Info.plist` also includes a copyright line and an app category.

## Testing the app by hand

The app reads no launch arguments, so test it as a person would: open it and scan.

- Closing the window leaves the app running. The Dock icon reopens it with the results still in memory. Closing
  or quitting during a scan asks first, as does starting a scan that would replace results. Pressing Stop requests
  cancellation without a confirmation.
- After you agree to stop a scan and quit, the app waits up to 4 seconds for the scan to settle, then quits anyway.
- Dropping a folder on the window or the Dock icon scans it; `open -a Spacewise <folder>` does the same from a shell.
- [Security](../SECURITY.md) lists what the app stores and logs. To watch the app log:

```sh
log stream --predicate 'subsystem == "local.spacewise"'
```

OS-owned crash reports are available in Console or `~/Library/Logs/DiagnosticReports`. Script cleanup leaves them in
place. Inspect development logs locally before sharing them.

## Uninstall

Quit Spacewise and move `~/Applications/Spacewise.app` to the Trash in Finder. For optional development cleanup,
quit all tooling and remove this checkout's ignored build directories and the exact hidden
`~/Applications/.SpacewiseDevelopment` directory. The app's preferences are at
`~/Library/Preferences/local.spacewise.app.plist`. Removing preferences or the System Settings privacy entry is a
separate manual choice. Leave shared signing certificates in place.
