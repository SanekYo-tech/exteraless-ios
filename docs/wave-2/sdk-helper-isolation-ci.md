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

## Executed follow-up

Commit a823e619 passed Linux43786135131:478 pytest cases,36 skips,147.86s.
Mac43786148988 passed49 finite SDK cases (13 skips), then exposed a native-listener
readiness failure. That separate Network.framework failure is being diagnosed
with the actual listener status; it is not the helper import defect.

The next Mac workflow continues independent bounded native checks after a sibling
fixture failure. Preparation remains required; HNS and SDK stages require their
successful Host/Core/engine prerequisites. Test errors still fail the job, and
validated runtime publication retains the normal all-success gate. Existing
13 tooling tests and a workflow dependency-reference check passed locally.
