# Native SDK probe handoff

Final SDK02/03/04 and HNS-F03/F04 source/readiness update: `sdk-adapters-final.md`.
Current source fingerprint: `sdk-final-source-inventory.json`.
TLN-F01/F02 post-validator delta is frozen in `tl-review-remediation.md`:
post-hook normalization uses shipping `ExteralessTLTransformCodec.response`, and
the Mac compile/input list includes `TLTransformCodec.swift` + `TLUpdatePolicy.swift`.
Native execution of this delta is pending.
Latest TBF05 alignment preserves 272/4/32 and passes the four receipt/registration
checks on both interpreters. Java SDK06–09 source inputs are staged and fingerprinted
under `java-sdk-cohort/`; its optional native-codec instructions remain in the
included `sdk-java-remediation.md`.

## Entry point

```sh
python tools/runtime/check_swift_plugin_embedding.py \
  --python <matching-CPython-3.12> \
  --output <empty-absolute-directory> \
  --python-root <repo-or-staged-python-root>
```

Requires macOS/Xcode, matching 3.12 headers/library, and an already sealed vendor
bundle. The driver verifies its dependency inventory and hashes all C/Swift/SDK
inputs. TL metadata resolves from `python/tl-schema.json`, with source fallback
`python/runtime/tl-schema.json`. All three fresh native children have independent
hard **30-second** timeouts. The second child also requires generated hookNames and
matching source/layout pins for the compiled native TL codec.

SDK-owned sources:

- `tools/runtime/check_swift_plugin_embedding.py`
- `python/runtime/smoke/swift_plugin_probe.swift`
- `python/runtime/smoke/swift_sdk_fixture.swift`
- `python/runtime/smoke/native_plugin_probe.py`
- `python/runtime/smoke/plugins/native_wave_probe.plugin`
- `python/runtime/smoke/swift_sdk_tl_probe.swift`
- `python/runtime/smoke/native_tl_probe.py`
- `python/runtime/smoke/plugins/native_tl_first.plugin`
- `python/runtime/smoke/plugins/native_tl_second.plugin`
- `python/runtime/smoke/swift_sdk_tl_fixture.swift`
- `python/runtime/smoke/swift_sdk_config_root_fixture.swift`
- `python/runtime/smoke/swift_sdk_hns_fixture.swift`
- `python/runtime/smoke/swift_sdk_hns_probe.swift`
- `python/runtime/smoke/native_hns_probe.py`
- `python/runtime/smoke/plugins/native_hns_probe.plugin`

The existing C engine, bridge and current Host/dispatcher sources are compiled
directly. C reentrant-clear P2 and Host maintenance/gates remain with their owners;
run this driver against their integrated current sources.

## New checks

- Actual Host random epoch equals C injection and SDK binding; a caller-authored
  token cannot replace it, and rebinding fails. Reload creates a distinct epoch;
  the retired CallbackOwner cannot enter the replacement interpreter.
- Runtime exportedMethods discovery changes on provider removal. The actual
  invocation through jclass(Runtime) is observed as a **C BridgeBackend.call**.
- Opaque bulk settings preserve literal transport-marker keys, Unicode/NUL and
  existing values; replace deletes the temporary key.
- Foundation UI DTO admission, action/dismiss/closed FIFO and terminal lease release.
- Exact widget padding/layout/font/image models, live Builder/item/button updates,
  captured text before callbacks, stable wrapper handles and unchanged C backend
  (`ui_live_models`).
- Owner-queue Runnable runs in the original account scope and returns void even
  when the user function returns an arbitrary non-JSON object.
- A separate Host async result callback returns actual JSON, including NUL.
- TL request DTO and decoded response/error callback preserve account scope;
  RequestDelegate's ignored Python return does not export a C handle.
- Dispatcher result fences follow native releases. Exactly the reusable checks
  handle remains after transients; final unload leaves zero handles/SDK leases.

The existing AST-only inspector, two plugin generations, exact legacy runnable,
SDK event/settings counts, permission/disable gates, disk persistence and process
finalization checks are retained. New observations have separate report fields.

The second child runs the actual Host transformTL path with two real SDK plugins:
maximum registration priority overrides lexical plugin order; the lower-priority
plugin observes the first normalized edit; MODIFY_FINAL and CANCEL stop the chain;
an invalid edit is rejected before the next plugin. The actual Foundation native TL
binary codec normalizes between plugins. The remediation extension covers Boolean
masks/shared bits, root Vector results, cancellation winners, native text DTO routes
and legacy C-owned text ancestry. This child has its own one-process/four-interpreter
cleanup and genuine C backend observations.
It also links the local ExteralessCore package and actual ClientSettings bridge.
The driver stages the consumed Root registration expression, then two real SDK
plugins exercise all 44 global Config overloads across a disk reopen, separately
from per-plugin settings. `root_config_bindings` is mandatory.

The third child uses finalized NativeService callback-control/cleanup factories,
real C/SDK unload and nonterminal Host maintenance. A bounded stall occupies the
actual owner worker before account/grant revocation; terminal delivery and exact
FIFO release are checked. Long-delay task/peer/notification/UI DTO leases must be
cleaned by SDK CallbackLeases.end during `_exteraless_runtime.unload()`, with no new
retiring admission. Duplicate production-route cleanup is checked during that
retiring call. Post-destroy/replacement Host bridge replay must instead return typed
SecurityError before provider execution. Native settings
callbacks carry SDK slot 41, distinct from selected slot 2 and record id 9000.
The settings read pins its expected owner/account-generation/read permit. Native
notification discovery uses all 12 actual enum entries, not a three-event table.
Full scenarios and proof boundaries: `sdk-tl-remediation.md`.

`onOwnedCallback` compares the captured wireToken before calling the real dispatcher
and returns its admission Bool. Platform fixture effect methods accept the mandatory
PluginNativeCallLease and call check() before recording any attempted effect.

## Evidence / outputs

New native execution is pending macOS. Windows evidence is Python SDK behavior and
source validation; the coordinator-provided Core122/Host89/Hooks16 baseline
`4b3f7064` / `43653040458` does not cover this new driver slice.

Successful native execution must produce:

- `swift-plugin-smoke.json`, with all REQUIRED_CHECKS true and matching owner epochs;
- `swift-sdk-tl-smoke.json`, with all REQUIRED_TL_CHECKS true;
- `swift-sdk-hns-smoke.json`, with all REQUIRED_HNS_CHECKS true; the parent succeeds
  only after all three children pass;
- `build-inputs.json` and `host-python.json`;
- build/console logs, with `EXTERALESS_SWIFT_PLUGIN_PROBE_OK`;
- TL console log, with `EXTERALESS_SWIFT_SDK_TL_PROBE_OK`;
- HNS console log, with `EXTERALESS_SWIFT_SDK_HNS_PROBE_OK`;
- retained isolated run directory with native disk settings and source fixture.

UI/service stand-ins are explicitly **Foundation DTO recorders**; the TL codec and
NativeServices lifecycle helpers execute production source. They report no UIKit
visibility, production network/state application or Telegram delivery. Global Config mirror
API receipts and behavior tests are documented separately in `sdk-config-parity.json`.

## Python handoff evidence

Historical focused baseline: **33 passed on CPython 3.12.10**, **33 passed on 3.14.8**.
Each SDK scenario runs
in a fresh process with a 20-second timeout. The source receipt has a separate
bounded regeneration check. Native-service unit recorders exercise SDK code;
actual C legacy tests use the existing CPython-3.12 owner-token extension.
Machine-readable evidence: `tests/sdk-python-checks.json`.
The subsequent UI stitch's targeted checks and source deltas are recorded in
`sdk-ui-source-handoff.md`.

Final registered SDK cohort: **49 tests passed on each interpreter**. The former
Config source drift is reconciled explicitly at **272/4/32**. A final root-hash-only
refresh passed all four receipt/registration controls. Native execution is pending.
The additional exact native-root Python helper passed in a seven-test targeted
join on both interpreters; no native result is inferred from that unit transport.
Runtime's applied HNS patch receipt is `sdk-runtime-hns-stitch.md`.

```sh
python -X utf8 -B -m pytest tools/compat/tests/test_sdk_config_manifest.py \
  tools/compat/tests/test_sdk_adapter_wave2.py tools/compat/tests/test_ios_runtime.py \
  tools/compat/tests/test_native_sdk_tl_fixture.py -q
```

The Config table is frozen at 272/4/32, with actual root/child registration checks.
The four remaining exact IDs and the migration/camera codecs are documented in
`sdk-config-binding.md`. All 308 IDs are validated with the read-only merger.

Reviewed bounded legacy selection: 166 passed / 4 skipped on 3.12; 142 passed /
3 skipped on 3.14's Python-only selection. Approved-temp logs are under
`sdk-legacy-slice-py312` / `sdk-legacy-slice-py314`.
