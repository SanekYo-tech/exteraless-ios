# Plugin trust-level remediation

## APPLIED — 2026-11-15

All seven trust integration payloads have been applied with `functions.patch` to
the current coordinated source. The 21 shared/new paths plus
`PluginDeveloperBridgeExtension.swift` are ready for cohort source freeze.

* Install consent uses the authoritative **post-staging `plugin`**, after old-owner
  retirement and before file replacement/bootstrap. New installs remain DEFAULT 0;
  existing explicit native consent and legacy grant migration are retained.
* Developer start/stop captures a required settings-permission predicate **before
  queue admission**, carries it into `PluginConfigAuthority`, and retires denied
  pending commands. Regrant cannot revive an earlier queued command. Native
  developer opt-in, readiness projection and provider order are preserved.
* Source checks passed: **167 assertions**, including 39 unchanged coordinated
  files, 32 unchanged existing method bodies, and 34 throwing consent call sites.
  `git diff --check` passed for the integration scope.
* The **13 Swift + 2 UI contract cases** and UI BUILD entries are present. The Host
  install case additionally checks staged archive metadata against a stale preview.
  Native Swift/XCTest, UIKit frames and CI were not executed or queried here.

[Full report](wave-2/plugin-trust-level-remediation.md#applied--cohort-freeze-receipt)
and [actual-source SHA-256 manifest](wave-2/plugin-trust-level-applied-manifest.json).
The manifest covers 21 integration paths, one extra Developer path and six owned
policy/test paths, with raw-byte and LF-normalized hashes.
