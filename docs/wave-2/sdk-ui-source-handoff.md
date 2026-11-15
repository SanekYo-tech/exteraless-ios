# SDK source handoff — final NativeUI stitch

Applied the owned Python portions of `plugin-ui-sdk-hunks.patch` against the current
SDK2 adapter, including its menu wrapper hunk. Changes are uncommitted; no CI dispatch.

## Source changes

- `_ui.py`: portable padding/layout/margins/weights, LayoutParams and ImageView,
  named font/image/icon data. Native owns resource resolution and rendering.
  Numeric fields reject Bool; loading/spinner default `cancelable=false`.
- Cached Builder/create identity and live model updates. Nine distinct presentation
  callbacks (including required reserved closed) remain stable when buttons/items/
  listeners change. Item icons work through the actual Python SDK entry point.
- Native input values update the widget tree before button/item listeners. Button
  text changes retain enabled/destructive/color state; make_button_red clears an
  explicit color. Failed native widget updates restore the prior Python model.
- Settings use change/action/longAction/refresh plus closed. Refreshed row callback
  IDs do not allocate new C wrappers. A failed refresh restores the prior SDK
  callback maps so the still-visible rows remain callable.
- `_registrations.py`: menu callbacks bind the supplied native account, adapt the
  supplied message accessors and fragment, return void, and pin navigation sourceId.
  Existing file/intent and Pill lease behavior is retained.

Native model fixture updates are in `native_plugin_probe.py`, `swift_sdk_fixture.swift`
and the SDK driver/report fields. They require exact padding/layout/font/image DTOs,
live item/button/blur/clickable updates, captured field values, nine unique stable
callbacks, unchanged C BridgeBackend identity, terminal FIFO and zero leaked handles.
The new mandatory observation is `ui_live_models`. The two-process native command
and its 30-second-per-child bound remain in `sdk-native-probe.md`.

## Targeted checks

Each case runs in a fresh isolated child with a hard 20-second timeout; only the
existing local fixture was extended.

| Interpreter | Initial selection | Final regression selection |
|---|---|---|
| CPython 3.12.10 | 6 passed, 3.65s | 3 passed, 2.53s |
| CPython 3.14.8 | 6 passed, 3.99s | 3 passed, 2.82s |

The UI case appears in both selections: **8 distinct scenarios per interpreter**.

```sh
python -X utf8 -B -m pytest tools/compat/tests/test_sdk_adapter_wave2.py -q \
  -k 'ui or settings_menu or failures or owner_binding or registrations or pill_scopes'
python -X utf8 -B -m pytest tools/compat/tests/test_sdk_adapter_wave2.py \
  tools/compat/tests/test_ios_runtime.py -q \
  -k '[ui] or lifecycle_settings or callback_cleanup'
```

JUnit evidence in approved temp: `sdk-ui-stitch-py312.xml`, `sdk-ui-stitch-py314.xml`,
`sdk-ui-stitch-final-py312.xml`, `sdk-ui-stitch-final-py314.xml`.
Python source parsing and scoped `git diff --check` also passed.

Native Swift execution is pending the Linux/Mac integration gates. Foundation DTO
assertions do not claim UIKit rendering. The accepted Config receipt remains
**308 IDs: 179 implemented SDK mappings, 102 blocked, 27 unsupported**; missing
native setting keys/manager contracts stay explicit for coordinator reconciliation.
