# Native SDK helper path quoting

Mac `43734307283 / a9afcb79` passed the first real Swift/C/CPython SDK child after
the observer correction. The TL child then failed before its helper was loaded:
its local JSONEncoder escaped `/` as `\/` in a Python source string. Python leaves
that unrecognized escape in the path, so `spec_from_file_location` could not open
the staged helper. Its console also recorded that exact invalid-escape warning.

`tlQuote` now delegates to the existing `PluginRuntimeScript.quote`, whose literal
encoding preserves forward slashes. The same observed engine loads the HNS helper,
so that path receives the correction too. Actual JSON payload encoders are unchanged.

Existing Host coverage rejects escaped slash in Python bootstrap source
(`PythonRuntimeConfigurationTests`). The next Mac run must actually import both
helpers and execute the TL/HNS checks; an earlier child's pass is not a full gate.
Diagnostics are retained at `build/artifacts/python-runtime-43734307283/`.
