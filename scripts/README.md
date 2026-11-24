# Development command reference

Each `<command>.sh` is a symlink to `spacewise.sh`. Run it by path from any directory, or use
`spacewise.sh <command>`. The dispatcher maps the name and [tool.py](tool.py) handles the options and work.
See the [local development guide](../docs/LOCAL-DEVELOPMENT.md) for the workflow and signing.

Every command accepts `--dry-run` to describe its work without changes.

| Command | What it does | Other options |
| --- | --- | --- |
| `setup` | Check the host, then build, sign, install and launch. Signs ad-hoc unless an identity is selected. | `--identity <SHA-1>` |
| `doctor` | Check for macOS 15 and Swift 6.2 or later, and report the SDK and signing choice. | |
| `build` | Stage a release app and build the control helper. | |
| `sign` | Sign and verify the staged app. | `--adhoc` or `--identity <SHA-1>` |
| `verify` | Verify the staged app and print the build number as JSON. | `--adhoc` or `--identity <SHA-1>` |
| `install` | Install the staged app without launching it. | `--adhoc` or `--identity <SHA-1>` |
| `relaunch` | Quit and launch the canonical installed app. | `--adhoc` or `--identity <SHA-1>` |
| `dev` | Build, sign, verify, install and launch. | `--adhoc` or `--identity <SHA-1>` |
| `rollback` | Install and launch the retained previous bundle. | `--adhoc` or `--identity <SHA-1>` |
| `clean` | Remove SwiftPM output, the staged bundle and known local build stages. | `--logs` also removes local logs |
| `quit` | Ask the canonical installed app to quit. | |
| `status` | Print running Spacewise processes as JSON. | |

## State

- `build`, `sign`, `verify`, `clean` and `doctor` write only inside the checkout: `.build/` for SwiftPM output, and
  `.spacewise/` for the staged `Spacewise.app`, temporary build stages,
  the control helper, diagnostics, the build counter, SwiftPM's cache and configuration for script builds, and
  `workspace.lock`.
- Only `setup`, `install`, `dev`, `relaunch`, `rollback`, `quit` and `status` create or use
  `~/Applications/.SpacewiseDevelopment/`. It holds `install.lock`, the transaction journal, installation stages and
  `previous.app` for rollback. The installed app is `~/Applications/Spacewise.app`.
- Recovery keeps a rejected or uninstalled candidate at its transaction's `stage-<id>.rejected` path.
  Treat it as evidence for inspection. The tooling leaves these copies for manual cleanup. An interruption
  during old archive cleanup can also leave a detached `discarded-<id>` directory for manual cleanup.
- Local diagnostics live under ignored `.spacewise/`. The log retention policy removes logs older than seven days
  and trims retained logs to 200,000 bytes.

## Safety

- The tooling uses normal termination and never force-quits a running app.
- Cleanup preserves the installed app, rollback copy, preferences, certificates, permissions and scanned files.
- The scripts never generate certificates, change trust, elevate privileges, edit macOS privacy settings, remove
  quarantine or send data over the network.


## Installer verification

Run `python3 scripts/test_scripts.py` for the mocked script suite. Build and sign a staged app with
`./scripts/build.sh && ./scripts/sign.sh --adhoc`, then run `python3 scripts/test_install.py` for real
signature verification and atomic swaps in temporary directories. The installer suite simulates
interruptions at filesystem transitions and repeats recovery to check installed and previous builds,
journal removal, and the disposition of stage and rejected directories.

In an interactive macOS session, run `SPACEWISE_TEST_LAUNCH=1 python3 scripts/test_install.py` to also
exercise Launch Services, normal quit, rollback and relaunch. The test uses ad-hoc signed copies under
a unique bundle identifier and a helper scoped to its temporary install path. This covers local
launch and replacement. Certificate continuity, Gatekeeper acceptance of a distributed artifact and
macOS privacy grants require separate acceptance.
