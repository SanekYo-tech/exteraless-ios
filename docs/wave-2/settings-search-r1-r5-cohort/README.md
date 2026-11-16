# R1–R5 settings-search cohort

The adjacent receipt pins **16 existing + 6 delta Core tests**, both authored
search sources, the narrow `ClientSettings` metadata change and six unchanged
dependency files (nine production Swift files total). The stager copies their
actual bytes and checks hashes before creating any output. It does not run Swift.

From the checkout, choose a new owned scratch directory on the Linux executor:

```sh
python3 -B docs/wave-2/settings-search-r1-r5-cohort/stage.py --output "$HOME/settings-search-closure-cohort"
```

In that output directory, with Swift 6 and GNU timeout already installed:

```sh
sha256sum -c SHA256SUMS
timeout --signal=TERM --kill-after=5s 120s swift build --build-tests --configuration debug --jobs 2
timeout --signal=TERM --kill-after=5s 30s swift test --skip-build --configuration debug --filter 'ClientSettingsSearch(Closure)?Tests'
```

Retain both command exit statuses and all **22** discovered method identities.
No external package, account, system Keychain or network is required. The existing
16-test archive is historical; this source-only cohort has separate pins.

Native checks remain on `ClientUIHarness`'s real `core-light` / `core-dark` paths:
`SettingsSearchUIViewRouteChecks.exerciseClosureChecks` is awaited before the
existing secret-availability segment. It returns `facts.settingsSearchClosure`
only after real default Root/editor checks, actual-store ABA, pending cancellation,
fresh copied-link navigation and native denial checks succeed. The **13 probes**,
**30-second process bound**, and **3+3+2** recording groups remain in force.

The six extra 650ms transitions add 3.9s; three polls allow up to 500ms each and
one queue-drain delay is 50ms. Timing and frame acceptance require native execution.
The appended remediation section specifies the expected frames and the separate
full-application launch/notification ingress check. Staging/static checks are not
Swift, XCTest, UIKit, launch-ingress or frame evidence.
