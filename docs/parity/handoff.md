# Parity implementer handoff

Scope: `tools/compat/feature_inventory.py`, two new
`tools/compat/tests/test_feature_inventory_*.py`, and `docs/parity/**`.
No Android, Swift, SDK, bridge, BUILD or workflow source was edited.

## Delivered

- `client-features.json`: 567 source setting/state entries, all 30 merged client
  modules, 2,614 public method bodies, 849 named UI definition sites, and 308
  ExteraConfig API overloads. Its 139 scalar-returning symbols contribute **zero**
  entries to functional-config counts. Read the generated totals for the separate
  settings/templates/state and static-consumer classifications.
- `sdk-surface.json`: all 36 SDK modules / 925 public declarations and exports,
  Android counterpart pins, Python signatures/defaults, strict builtin bridge
  mapping, adapter boundaries, and separate Android pip / iOS lock inventories.
- `android-evidence.json`: executable, anchor-checked annotations for materialized
  PillStack/translation collections and conditional initial values.
- `index.md`, `android-audit.md`, `schema.md`: readable audit, proposed Core keys,
  native subsystem candidates, platform constraints and parity-fragment contract.

All initial implementation statuses are pending. The inventory does not promote
static references, settings storage, bridge metadata or stock UI concepts to a
verified port. Native candidate files/anchors resolve; actual key-read/effect
locations should arrive in the domain agents' fragments.

## Coordinator integration

Use the original `features[].id` as identity and `ios.setting_key` as the proposed
wave-2 Core key. Examples:

| Inventory ID | Proposed Core key |
|---|---|
| `appearance.avatarCorners` | `appearance.avatarCorners` |
| `chats.removeMessageTail` | `chats.removeMessageTail` |
| `openextera.addCommaAfterMention` | `chats.addCommaAfterMention` |
| `general.botPrivacyEnabled` | `privacy.botPrivacyEnabled` |
| `neko.sendReadMessagePackets` | `privacy.sendReadMessagePackets` |
| `ai.responseStreaming` | `ai.responseStreaming` |
| `general.downloadSpeedBoost` | `tools.downloadSpeedBoost` |

Fragments can override proposed keys with their actual registered keys and supply
`ios.implementation_callsites`, adaptations and `implementation.evidence`.
Merge with repeated `--parity` arguments. Both prior generated and tracked parity
are preserved; conflicting fragments/unknown IDs fail. An explicit fragment can
downgrade a status. Android definition changes retain historical proof and require
new verification before `ported` becomes true again.

**Collision needing an owner decision:** Neko `sort_by_unread` and Nagram
`SortByUnread` are distinct source settings. Only Nagram's currently has real
sorting consumers. Do not register both under `chats.sortByUnread`.

The Android direct pip list is **7**, not 8. The dependency agent expanded the
initial 8-package iOS lock to **12** during this wave; current JSON includes that
change and retains PyYAML/debugpy source-projection/runtime constraints. lxml and
Pillow are outside this Python lock. Provision metadata, native wheels and
JVM/DEX/Xposed are not falsely recorded as completed functionality.

## Local checks

Only the new bounded source fixtures were executed; no external plugin code or
CI was run. CPython 3.12.10: **23 tests passed**. Cases cover Kotlin keys/defaults,
anonymous ConfigItems, linked bits, Java-vs-Kotlin comments, same-arity overloads,
real vs shadowed/import-aliased consumers, shim != feature counts, Java+Kotlin
module merging, bounded evidence, AST nonexecution, dispatch-vs-metadata support,
verified-status persistence and invalidation on a changed Android definition.

```powershell
& 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe' -B -m pytest tools/compat/tests/test_feature_inventory_scanner.py tools/compat/tests/test_feature_inventory_parity.py -q
& 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe' -B -m tools.compat.feature_inventory
& 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe' -B -m tools.compat.feature_inventory --check
```

Regenerate after the other agents' native/SDK changes and after merging their
evidence. The JSON pins describe the exact sources read by that generation.
