# SDK TL native response: `self` constructor collision

## Root cause — Mac 43735410090 / cca2d83a

The first SDK child passed. The TL child reached `flags2_on` and failed its existing
`seen_close_friend == true && seen_flags2 == 5` assertion. Its traces show the same
unmodified native User response entering both plugins.

The shipping codec's encode/decode normalization materializes Boolean flag fields,
including **`"self": false`** on `user`. The exact 1,286-byte captured dispatch payload
is now `tools/compat/tests/fixtures/tl_native_user_response.json`; its JSON values were
compared with the first matching dispatch in the downloaded Mac report.

Failure path:

1. `exteraless_runtime.dispatch_json` → `Schema.hook_value` → `decode_response`.
2. Vector element decoding calls `get_registered(alias)(**fields)` for `TL_user`.
3. `fields["self"]` collides with the bound receiver of
   `TLObject.__init__(self, **fields)`:
   **`TypeError: TLObject.__init__() got multiple values for argument 'self'`**.
4. The hook body never receives its Vector/User. Host's existing invocation-error
   handler (`PluginHost.swift`, TL-transform loop) continues with the original input;
   the second plugin encounters the same constructor error. Its expected observations
   are never written.

The earlier Python fixtures supplied `bot`/`close_friend` but omitted `self`, so they
did not exercise the native-normalized constructor call. The observed failure occurs
before either Boolean mutation or response formatting/native replacement validation.

## Fix and diagnostics

`python/exteraless_runtime/_tl.py` makes the receiver positional-only:

```python
def __init__(self, /, **fields):
```

The actual TL `self` field now enters the same typed setter as all other fields.
Existing optional getters, Boolean mask reconciliation, value-companion rules and
Vector serialization continue through their current implementations.

The native probe adds bounded diagnostics:

- `traces[].dispatch_errors`: last 1,200 characters of each error, at most four per
  interpreter, preserving the exception tail and rethrowing the original error.
- `flags2_diagnostics`: actual strategy, normalized-result preview (2,048 characters)
  and stored `seen_close_friend` / `seen_flags2` values from this own canned fixture.

The assertion remains **true / 5**. Native codec/response validator sources, the two
plugin sources, Java byte-array cohort, a9's partial-module observer and cca2d83a's
`PluginRuntimeScript.quote` join are preserved. Source hashes are in the receipt.

## Bounded evidence

- Before the fix, the captured input reproduced the exact TypeError through a freshly
  compiled **real C BridgeBackend on CPython 3.12.10**, after ordinary SDK bootstrap.
- After the fix: **5 passed / 0 skipped on 3.12.10 (2.74 s)** and
  **5 passed / 0 skipped on 3.14.8 (3.11 s)**; two unrelated remediation cases deselected.
- Each suite was capped at 30 s. Existing unit workers use 20 s; the C-response workers
  use 30 s. The new worker is 12,408 bytes; payload/result files are capped at 32 KiB.
- The C test loads the unchanged `native_tl_first.plugin` and `native_tl_second.plugin`
  in separate processes and passes the first worker's actual serialized results into
  the second: flags2 **1 → 5 → 1**, retained `usernames` ArrayList, valid bot companion,
  `Vector<User>`, `Vector<Int>` and exact `Vector<Long>` values. It also covers true/false
  `self` and absent `bot_info_version`.
- The invalid bot candidates retain their missing/inconsistent companions for the
  native validator to reject; this Python fixture does not substitute a normalizer.
- C owns epochs and handles; no legacy services/mock backend are installed. Unload
  leaves zero handles. The same bootstrap SecurityError scans occur in passing C
  workers: TL class/ArrayList identities still resolve correctly. Those warnings are
  not the cause of this constructor failure.

Local C builds use the unchanged bridge source and its dispatcher/buffer ABI exports.
The existing 3.14 MSVC driver built both ABIs; the 3.12 target uses its own headers and
`python312` library. Desktop host services are recorders. These runs do not execute
Swift normalization, OWN_GIL workers or UIKit/network/state application.

Focused command (set `EXTERALESS_TL_C_BRIDGE` to the corresponding current extension):

```text
python -X utf8 -B -m pytest tools/compat/tests/test_native_sdk_tl_fixture.py tools/compat/tests/test_sdk_tl_c_response.py tools/compat/tests/test_sdk_tl_remediation.py -k "native_tl_python_fixture or actual_native_response or boolean_flags or vector_roots" -q
```

## Next native callgraph checks

On the coordinator's next compatible SDK snapshot, retain the actual
`ExteralessTLTransformCodec.response` → binary response decode → second C/SDK worker:

1. `flags2_on`: `self=false`, `close_friend=true`, flags2=5, usernames remains ArrayList;
   `flags2_off`: false / 1, retaining the value-optional bit.
2. `bot_missing` is rejected; `bot_on` preserves version 9; `bot_off_inconsistent` is
   rejected with the previous valid bot result retained.
3. Complete the existing User/Int/Long Vector, origin, cancellation-winner, native text,
   epoch and cleanup checks in the second TL child.
4. Continue to the third native HNS child, which the failed Mac run did not start.

Ready hashes and exact artifact locations: `tests/sdk-tl-self-checks.json`.
The fixed snapshot's Mac pass is pending. This repair is uncommitted; the frozen
production-app snapshot and its CI run keep their existing identity.
