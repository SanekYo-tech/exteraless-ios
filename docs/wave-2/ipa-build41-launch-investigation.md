# Build 41 — artifact inspection and black-screen investigation

User report: signed IPA opens to a persistent black screen on **iOS 27.0.1**;
Bundle ID was not intentionally changed. A successful package build does not
establish that the app reaches its first screen. **Device launch acceptance is
blocked by this report.**

## Artifact inspected

- Run43912353956: completed **success**, release build41.
- Git source: `79fedf4f4324bc5f8f65b573370bd03fda3daa57`.
- Release artifact14259546388:275026000 bytes,
  SHA-256 `cda0c6f6b3063024457abb1357dc24478f15fd49c62ac1d05ea3976cb9a87d26`.
- Preflight artifact14258706823:280348 bytes,
  SHA-256 `b6f67a5c2bce1efdcd06adc25523d61acf5323eb495cca6a7cd8fc5a53e370c0`.
- Both downloaded ZIP hashes match GitHub metadata and pass ZIP CRC verification.
- Actual `Telegram.ipa`: **98669864 bytes**,
  SHA-256 `d3fe5fed758d6d374b44719fa8514473fee03dcd2784d0acb2165c3cd876e8ed`.

Files: `build/artifacts/telegram-43912353956/`; local machine-readable packaging
inspection is `local-verification.json` there.

## Independently checked packaging

`verify_unsigned_ipa` and `RuntimePackaging.verify_runtime_ipa` passed on the
downloaded IPA. It has67 unsigned arm64 device Mach-O binaries, six extensions,
55 runtime frameworks and1413 required runtime/resource placements; CPython is
3.12.16. Application/extension dependency and rpath chains resolve.

The bundle is `ph.telegra.Telegraph`, version13.1.1/build41, minimum iOS15,
built with SDK27.1. Its scene manifest selects `SceneDelegate`; the real linked
TelegramUI binary contains the `Application`, `AppDelegate` and `SceneDelegate`
class names. The launch resource is `Base.lproj/LaunchScreen.nib`, generated from
the existing XIB, not a missing Python/SDK resource. Both pinned Roboto fonts
have their expected lengths and pass runtime resource hashing.

436/439 staging source hashes match the named outer Git revision; the remaining
three are nested Rust files and match the applied, pinned patch postimages in
the nested worktree. These are distinct provenance checks, not439 outer Git blobs.

## Concrete source defect: unpresented pre-scene failure

`AppDelegate.application(_:didFinishLaunchingWithOptions:)` creates the native
window before attaching a UIWindowScene. It derives the required group as
`group.` + actual Bundle ID. If `containerURL` returns nil, the shipped build
attempts to present `Error 2` immediately and returns before settings or Account
construction. The window is attached only in the later `SceneDelegate` callback.
Thus the early failure can leave an empty window without a visible diagnostic.

The local correction retains this failure until scene attachment, then installs
a plain, readable UIKit diagnostic root in that real window. It does not create
another account store, switch containers, discard data or bypass storage admission.
Two source-order regression checks pass. Native rendering of this correction is
still pending; this is not proof that absent App Group caused the user's instance.

## Signing boundary still to measure

The original artifact is unsigned and has no embedded provisioning profile. Its
external entitlement template requests **`group.ph.telegra.Telegraph`** and has
the build-time application identifier `C67CF9S4VU.ph.telegra.Telegraph`.
These are requested entitlements, not the effective permissions on the user's
installed copy. Preserving Bundle ID during re-signing alone cannot establish
the installed App Group capability. The signed copy/profile or device launch log
is needed to confirm this branch on the user's phone.

A separate normal-Telegram first-launch simulator recording is being prepared
from the exact build41 source; this explicitly launches the real app, not the
loginless ClientUIHarness. Main-app screen evidence, not the existing runtime33
component receipt, will determine whether correctly provisioned startup progresses.

## Independent startup review

`reviews/build41-launch-source-review.md` checked the actual startup chain and
did not establish the physical-device cause. It found additional concrete paths:
Client API account producers may complete without a value; Passcode's file lock
can block main before scene attachment; settings file locks can hold the settings
worker while main remains responsive; the startup write-probe failure also
attempted a pre-scene alert and returned.

The current small follow-up retains write-probe failure for the same diagnostic
root and makes Client API errors scene-aware, storing them even if settings are
not ready yet and replaying after readiness/scene attachment. Ten source/tooling
checks passed. Client API factory resumption and lock-contention diagnoses are
not claimed closed by these presentation changes.

Baseline normal-app capture is run44110646483, snapshot5b16fb66 with production
source79fedf4f. Its watcher belongs to the launch-smoke owner. The baseline does
not include the new AppDelegate diagnostics, allowing original startup behavior
to be observed independently.
