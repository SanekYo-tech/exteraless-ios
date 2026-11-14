# Plugin UI — integration and frame handoff

Status: UI implementation is in place; iOS compilation and recorded-frame verification
are pending. This Windows session has no Swift/iOS simulator or XcodeBuildMCP.

## Coordinator contract

The public factory is `exteralessPluginManagerController(context:) -> ViewController`.
It adapts `ExteralessPluginRuntime.shared` to closure-driven `PluginManagerActions`:

- `status: () -> String`, `snapshot: () -> [Plugin]`, `logs: () -> [String]`
- `importPlugin: (URL) async throws -> Void`
- `setEnabled: (String, Bool) async throws -> Void`
- `remove: (String) async throws -> Void`
- `settings: (String) async throws -> String`
- `updateSetting: (String, String, String) async throws -> Void` (id, key, JSON scalar)
- `click: (String, String) async throws -> Void` (id, callback id)
- optional `permissions: (String) -> [PluginPermission]`
- optional `setPermissions: (String, [PluginPermission]) async throws -> Void`

The factory calls `runtime.update(context:)` first. The facade method labels are the
ones in the wave request. Snapshot/status/log reads
must be cheap, synchronized native reads. `status` must carry the actual startup
state/error and existing safe/unsafe-mode flags; the UI does not infer them. The host
owns AST metadata parsing, durable installation, per-plugin serialization, permission
policy, callback registration and Python worker scheduling. Failed loads must throw
and/or be reflected in `Plugin.loadError`/`loaded`; the UI never shows an installation
success banner. Settings values and callbacks always return through the host.

Register the main-actor factory through `ExteralessPluginEntry` during bootstrap,
including when runtime startup fails, so the error screen remains reachable:

```swift
ExteralessPluginEntry.setControllerFactory { context in
    MainActor.assumeIsolated { exteralessPluginManagerController(context: context) }
}
```

The factory bridge uses NSLock; controller creation is main-thread-only.

## Implementation details

- `PluginManagerController.swift`: closure contract, runtime adapter, manager/detail/
  bounded log lists, system document picker and coordinated file staging. The picker
  admits generic data as well as Python/plugin UTTypes because providers can report
  unregistered `.plugin` files as data. Extension and regular-file validation precede
  import. Security scope spans the coordinated copy; staging lives in
  `Application Support/exteraless/imports/<UUID>/` and is removed after the host call.
- `PluginSettingsController.swift`: header/divider/switch/selector/input/edittext/
  text/slider, click and long-click callbacks, nested `sub_page` navigation. Writes
  use setting keys, callbacks use opaque IDs. Both successful and failed mutations
  refresh the root JSON and resolve subpages by stable `row_id`; this includes an
  on_change callback throwing after the value was already persisted. A failed read
  leaves cached controls disabled with a reload action. Input drafts remain editable.
- `PluginSettingsModel.swift`: typed scalar encoding and bounded schema decoding on
  a detached task. Limits are 1 MiB JSON, 1,000 rows, 16 subpage levels, and 1,000
  options per selector. Slider range/rounding matches the SDK. Unknown native row
  types are explicitly displayed as unsupported rather than silently skipped.
- `PluginUIHelpers.swift`: self-sizing UIKit grouped lists hosted by
  `Display.ViewController`, using Telegram navigation, ItemListUI font metrics and
  presentation colors. Main-thread UI, keyboard/safe-area/reserved-corner insets,
  accessibility actions, stepped VoiceOver slider, retry/error states and draft
  preservation. Source globbing must include these two new UI helper Swift files.
- Manager/log polling runs only while visible (every two seconds), reads synchronized
  snapshots only, and never loads Python or calls create_settings. Logs retain at
  most 100 entries / 2,000 displayed characters per entry. No automatic sharing.

## Local checks

Scoped `git diff --check` passed. The five new Swift files passed UTF-8, final-newline
and trailing-whitespace checks. All five reused Telegram string keys were matched
against `Telegram/Telegram-iOS/en.lproj/Localizable.strings`. The settings JSON keys
and scalar/slider/subpage semantics were reviewed against `python/sdk/ui/settings.py`
and `python/sdk/extera_utils/plugin_loader.py`; the native loader calls that serializer.
These are source checks, not Swift type checking or UIKit/animation verification.

## Expected frames (write before recording)

- Settings > Plugins pushes with the existing Telegram navigation transition. The
  outgoing settings and incoming list each move as a single surface, without a
  detached header, blank gap, clipped edge or color flash. No custom spring is added;
   use the current navigation timing (roughly 0.3–0.5 s) as the baseline. Pop and interactive cancel
  must settle back to the same positions without additional overshoot.
- Empty state shows the real runtime status, a file import action and an explicit
  empty-list explanation. Starting/failed runtimes remain inspectable.
- Picking a file uses the system Files sheet. Cancellation restores import controls.
  Import shows an indeterminate busy state for the actual copy/host work only; a
  failing AST parse/load replaces it with the actual error and current host snapshot.
- Toggle/remove controls become unavailable during their operation. A load error
  must never look like a running plugin. Long titles and errors wrap beside controls.
- Plugin detail shows declared permissions and the actual granted-permission
  switches. Changing a grant updates the displayed state once the host operation
  finishes; reopening the detail retains it. Permission labels and their technical
  names wrap without covering switches in large text sizes.
- Opening plugin settings shows loading, then the real rows or an explicit empty/
  error state. Header/divider, switch, selector, input, text callbacks, slider and
  subpages must remain usable after a schema refresh. Errors preserve an input draft.
  An operation error brings its row into view; it must not disappear behind a long
  editor or be replaced by a success message after a partially committed callback.
- A slider moves locally during a drag and commits once on release; VoiceOver changes
  use the declared step. A cancelled drag restores the last confirmed value.
- Light/dark/custom themes use Telegram presentation colors throughout, including
  the editor, picker and error rows. At the largest accessibility text size, labels
  wrap, controls stay tappable and the keyboard does not cover Save or the edited text.
- Logs are explicitly bounded; refreshing a snapshot must not scroll to the bottom.

## Frame verification handoff

After the combined iOS build, use the permitted simulator and XcodeBuildMCP to drive
the screens. Follow `telegram-ios/AGENTS.md`: record with `simctl io recordVideo`,
extract timestamped/indexed sheets with `tools/animation_sheet.py`, inspect the whole
transition and every flagged frame. Record push/pop/interactive cancellation,
picker open/cancel/import failure, toggle failure, permission changes/reopen,
settings loading/error/empty,
callback/subpage navigation, slider release/cancel and input save failure. Cover
light/dark, long content, Dynamic Type, keyboard, narrow phone and regular-width
layouts. If available, include Duo reserved-corner postures. Use a small controlled
fixture through the actions overload or a real locally authored plugin; do not load
an external plugin corpus. Attach frame/time evidence before making visual claims.
