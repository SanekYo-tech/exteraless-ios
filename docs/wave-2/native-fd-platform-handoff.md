# Native FD platform witness — Mac gate and UIKit coordinator join

## Applied Mac semantic contract

The first child in `tools/runtime/check_swift_plugin_embedding.py` now requires
`native_trace.interpreters[actual-first-plugin-owner].observation.sdk_checks.darwin_family_fd_paths == true`.
Its nine earlier SDK observation requirements and the other three child validators
are retained. Missing/false/string/integer substitutes fail. The source helper
sets this flag only after its actual Darwin-family descriptor/path operations.

The current owner code is used unchanged:

- `python/runtime/smoke/native_plugin_probe.py::_probe_darwin_family_fds`, called
  from `_NativeChecks.verify_services` on the native owner worker.
- `python/runtime/smoke/plugins/native_wave_probe.plugin::NativeWaveProbe.fd_family_probe`:
  actual allowed asset-FD write, rejected code-FD write and rejected code `dir_fd` open.
- Real `_Extraction`, F_GETPATH/samefile/raw system alias and unknown descendant
  symlink rejection, followed by the helper's actual descriptor/extraction cleanup.
- The two `sys.platform` selectors in `_audit_paths.py` and the one in `_archives.py`
  now each include `darwin` and `ios`. Their exact current lines and hashes are
  recorded in the source-contract receipt. The owner's P2 review remains separate.

`build-inputs.json` includes current and staged first-helper/plugin SHA-256 values,
the two actual production helper hashes and the mandatory observation names.
The staged first-helper/plugin bytes must match their sources; both join the
existing final four-child input-drift check. A Mac flag is not iOS execution evidence.

There are currently **four** native children, each capped at30s: initial SDK,
`--tl-phase2`, `--hns-remediation`, `--archive-lifecycle`. The developer owner's
fifth real Swift/C/provider child awaits its driver hunk and is not counted or
substituted by this change.

## Applied UIKit join

The authorized coordinator packet is **APPLIED** through the patch tool. Before
application, all six existing-file preimages and four owner-source inputs matched
its receipt; the new helper path was absent. All seven resulting files matched
the packet's exact output SHA-256 values. The complete 40-path and32-path archive
payload inventories were verified, including the32-path ZIP SHA
`86e7eafdced3291a8fd38cb054a266a0936a8a96a6e43969bdd49f3cbb945ba1`.

Application receipts and the new source/input delivery are under:
`build/wave-2-dependencies/native-ui-ios-fd-join/`.
`pre-apply.json` and `applied-packet.json` retain the exact pre/post check. The FD
owner updated `_archives.py` after the precheck; that independent change is
recorded separately and included in the fresh source capture.

Historical packet (retained with its original unapplied status and hashes):

`build/wave-2-dependencies/native-gate-map-followup/ios-fd-packet/client-ui-ios-fd-coordinator.patch`

The actual scene still loads **`clientUIFixture`**. Its native engine wrapper now
calls the copied shared FD helper after each real plugin load and records only a
successful return through its cleanup. The Mac-wide `verify_services` scenario
is not substituted for this iOS witness.

`make_client_ui_fd_packet.py` is the historical emitter for an unapplied source
cohort. Applied sources are checked by `harness_inputs` and the native recording
driver rather than re-emitting or reapplying that patch.

The seven-file join does the following:

1. Bundles the **actual, byte-identical `native_plugin_probe.py`** as a trusted
   helper resource. Its unrelated service checks/profiler are not invoked.
2. Copies only the actual `fd_family_probe` method into the already installed
   `ClientUIFixture` class. That method executes under the real installed plugin
   filename and audit ownership. No additional plugin/dependencies are loaded.
3. After each successful Host `load_json` source on its owner worker, executes
   the shared `_probe_darwin_family_fds` with the real SDK record and
   `PythonBridge.getCacheDir()`. The plugin's recorded worker, actual runtime
   plugin ID and **actual `sys.platform == "ios"`** are required.
4. Captures the returned helper checks, platform, builtin-bridge origin, real
   interpreter reference, owner token and actual resource hash. The separate
   two-script dispatch is counted; ordinary Host sources still execute once.
5. Fingerprints the helper resource and rejects a stale source copy or a copied
   FD method whose AST differs from the current nativeWave method.
6. Calls `native_fd_evidence.validate_ios_fd_observations` from the
   SDK driver. Both existing plugin lifetimes must have
   **`actual_ios_fd_paths == true`**, platform `ios`, current helper hash and
   matching native reference/owner. `darwin_family_fd_paths` alone cannot pass.

The full465-line helper is byte-identical to the owner source; the complete
`fd_family_probe` method matches nativeWave, whose entire file remains a hashed
source input. Both resource BUILD fields are applied. IPA validation checks the
bundled helper bytes against its compiled manifest and verified source copy.

The wrapper retains the real `CPythonXCFrameworkEngine` C-ABI calls. Native
initialize/create observations precede Host bootstrap; `NativeBridgeBinding`
is installed before `host.start()`. The FD operation itself runs on the existing
plugin worker after load. No replacement engine/binding or successful fallback
for an unknown service is installed. Optional Search context signatures and the
Runtime page-lease forwarding were protected by pre/post source hashes.

All original SDK interactions, Composer math, six Pill calls and Map dispatch
remain in place. This adds **zero scenes and zero interpreters**; the existing
one initialize/finalize, inspector plus two plugin lifetimes and30s process cap
remain the acceptance contract. The helper must return through its real cleanup
before any iOS observation is retained. No FD value is fabricated or replayed
from the Mac report.

Current verification: **7 driver contracts +4 focused FD checks passed**. The
51 checks in the preceding32-path receipt remain historical evidence. The current
checks cover full helper/IPA hash identity, the actual applied worker script,
post-cleanup acceptance, stale owner/interpreter rejection and an explicit
`Host.fd_probe_classification: unknown service` error rejection. Source preflight
is clear. The existing **20 scenes, same retained IPA and30s/process** contract
and approved public MapKit traffic boundary continue to apply.

This is an applied source/input receipt, not NativePASS. Apple compilation,
native FD execution and frame review remain coordinator-run; no CI query/dispatch,
commit or main SDK Root/config pin regeneration was performed.
