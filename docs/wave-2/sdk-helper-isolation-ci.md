# Elyx fixture-helper isolation — 2026-11-16

Mac run43785374048 and Linux run43785348360, both at `d717af9e`, failed the same
six unit-transport Elyx cases. A helper imported from `test_sdk_direct_hooks.py`
entered pytest collection inside a child launched with `-I -S`. The child was
given the verified PyYAML directory, which correctly contains no pytest.

The direct-hook helper now has an explicit helper-only import name, matching the
existing archive helper convention. Both archive-helper callers use that existing
name. Test collection and all original cases remain enabled in normal pytest.

Local CPython3.12 verification with `PYTHONPATH=python/vendor`: four passed,
ten explicit Windows/native-C skips. The archive emitter also passed directly
under `-I -S -B`, with no site-packages or inherited import path. Runtime source,
Original SDK bytes and plugin permissions are unchanged.

Linux previously completed472 pytest cases and the Swift job; fresh Linux/Mac
execution is required for the six corrected helper-dependent cases and subsequent
native gates.
