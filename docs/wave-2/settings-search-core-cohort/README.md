# Settings-search Core cohort

This archive contains the two authored production Core files, the unchanged
seven-file dependency slice, and all 16 `ClientSettingsSearchTests` fixtures.
`cohort.json` binds every archive member to its repository source and SHA-256;
`SHA256SUMS` can be checked with `sha256sum -c SHA256SUMS` after extraction.

Run on Linux with an installed Swift 6 toolchain and GNU `timeout`:

```sh
timeout --signal=TERM --kill-after=5s 120s swift build --build-tests --configuration debug --jobs 2
timeout --signal=TERM --kill-after=5s 30s swift test --skip-build --configuration debug --filter ClientSettingsSearchTests
```

The package has no external dependencies. Tests use owned temporary Core files
and an injected synchronized secret backend; they require no UIKit, account,
system Keychain, network, SDK plugin runtime or repository-wide test suite.

Both command exit statuses and the exact 16 discovered/passing method identities
must be retained by the Linux executor. Archive/source checks performed on Windows
do not constitute a Swift build or XCTest pass. This cohort is supplied unexecuted.
