# Client UI acceptance harness

Read `../../AGENTS.md`, `../../CLAUDE.md` and the complete operating/expectation
contract at [`../../../docs/wave-2/ui-harness.md`](../../../docs/wave-2/ui-harness.md).

This is the bounded **implementer** harness, not an independent visual review.
Build the top-level `:ClientUIHarness` with the normal app graph through
`tools/runtime/client_ui_harness_build.py`, then use `client_ui_harness.py`.
The manual workflow is `.github/workflows/client-ui-harness.yml`.
It uses the `xcode-27` app runner and derives Xcode from `versions.json`. The CI
source copy is guarded by `client_ui_harness_workspace.py` (sentinel, OS lock and
run/attempt generation) under `/Users/Shared/exteraless-client-ui-harness`, with
the normal app's canonical source directory kept separate.

Never substitute a model/painted canvas for the actual UIKit controllers, return
plausible constants from missing AccountContext services, use an existing
simulator/account, or claim visual success without reading recorded frames.
Generated protocol traps are produced by the `ContextStubs` genrule. The compiler
must still check those conformances and the entire production graph.

The one bundled plugin is `Fixtures/client_ui_fixture.plugin`; no command accepts
an arbitrary plugin, user account path or simulator UUID. Each fresh process is
limited to 30 seconds by both the native main and the host driver. Do not replace
the real NativeBridgeBinding/CPython engine or weaken the final zero-lease/epoch
checks to make a UI run pass.

Input delivery is scripted **UIKit target/action**, not an XCUITest touch-path
claim. The ordinary production controls, table selection delegates and text
inputs perform the mutations; semantic probes observe the real resulting stores.
Frame timing comes from ffprobe, via the existing animation_sheet.py.
