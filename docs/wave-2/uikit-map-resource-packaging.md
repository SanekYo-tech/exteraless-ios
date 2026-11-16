# UIKit Map resource packaging — 43805552582 / 7c927d91

Both full Telegram and ClientUIHarness compiled and linked. The subsequent IPA
verification rejected the Map tile because bundled PNG bytes differed from the
owned source. The build log records `CopyPng` for `map-attribution-grid.png`.

The pinned rules_apple `resource_actions/png.bzl` invokes iOS `pngcrush -iphone`
for ordinary PNG resources. Its resource aspect explicitly leaves structured
PNG resources unprocessed. The Harness now uses an `apple_resource_group` with
`structured_resources` and strips only the `Fixtures` prefix, retaining the same
bundle-root filename and source fingerprint.

Both the IPA verifier's byte equality and the runtime fixture's SHA-256 check
remain strict. No expected hash or image is substituted. The next Apple gate must
confirm packaging before native tests and recorded-frame acceptance.
