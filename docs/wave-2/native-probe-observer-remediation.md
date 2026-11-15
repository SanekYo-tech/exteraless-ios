# Real SDK probe — partial C-module observer correction

Mac `43732590856 / 96bff39e` passed **671 Core tests**, Host/Hooks, the Foundation
UI/TL checks, Java TL codec and **23 HNS scenarios** (1.624s execution). The native
Swift/CPython adapter passed. All Swift/C/SDK probe sources compiled; the first
three-child-driver process then stopped in `load-and-native-settings`.

The recorded error is in the pre-bootstrap profiler: CPython inserts its
multi-phase `_exteraless_bridge` module into `sys.modules` before `BridgeBackend`
exists. A `c_call` event during that interval caused the observer itself to record
an AttributeError. The actual fixture subsequently loaded on its owner worker.

`native_plugin_probe.py` now checks whether the backend type has been published
before classifying bound C calls. It still records later observer errors and
requires the actual built-in bridge/backend after bootstrap. Two bounded tests
passed on Python3.12: the partial-module window followed by counting a published
backend, and rejection of a published malformed backend.

A separate Python3.14 Windows process also imported the existing real C extension
with this observer installed before import: **PASS**, with no observer problems.
It loaded no plugin and invoked no native service. This import-order check is not
the macOS Swift/CPython three-child execution receipt.

The original Mac error/trace is retained in
`build/artifacts/python-runtime-43732590856/diagnostics/`. This correction needs a
new real SDK execution. It does not waive owner checks or claim that the later
native SDK children, C219 or device/iOS-simulator stages passed.
