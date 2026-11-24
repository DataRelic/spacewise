# Contributing

Use macOS 15 or later and Swift 6.2 or later. From the repository root, run:

```sh
./scripts/doctor.sh
swift build
swift test
python3 scripts/test_scripts.py
swift format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
```

Add or update tests for behaviour changes, and format Swift changes with the checked-in rules. Explain why any new
dependency is needed. Keep scans metadata-only, keep app logic local and use the system Trash for confirmed moves.

The default Swift suite uses an injected Trash mover. The [test guide](Tests/README.md) documents the separate
opt-in system Trash integration for a disposable local account. See the [local development guide](docs/LOCAL-DEVELOPMENT.md)
for app bundles, signing and installer tests.

Report bugs and suggest features in the [issue tracker](https://github.com/DataRelic/spacewise/issues). Report
vulnerabilities privately as described in [Security](SECURITY.md).
