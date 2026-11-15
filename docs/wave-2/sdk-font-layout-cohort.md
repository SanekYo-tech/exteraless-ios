# SDK Font + Layout — next worktree cohort

This is the **uncommitted successor cohort** to `a320166c18216bcc1433b361849397822fec51e1`.
The first Mac snapshot remains that commit, with its original **272/4/32** receipt.
No native execution result from it is attributed to the changes below.

## Applied SDK joins

Adapted only the generator/disposition/test sections of `font-family-config.patch`
and `layout-mode-sdk.patch` to the current canonical-contract generator.

| Original SDK surface | Actual registered key | Type/default and native scope |
|---|---|---|
| NekoConfig.typeface; ExteraConfig.get/setUseSystemFonts | appearance.useSystemFonts | Bool / true; Apple system sans versus bundled Roboto, preserving explicit native font roles |
| NekoConfig.tabletMode; ExteraConfig.get/setTabletMode | appearance.tabletMode | Int / 0; 0 Automatic, 1 Tablet where it fits, 2 Phone/single-pane; hardware identity and system size classes remain native |

Both use the existing **identity** Config codec and settings permission boundary.
The generator pins the actual Core policy declarations and their references inside
AppearanceFeatures.definitions. Stale missing-key dispositions are removed. Native
range/type validation stays authoritative; no Python fallback default was added.

## Receipt and canonical inventory contract

After both joins: **276 implemented / 0 blocked / 32 unsupported**, exactly 308 IDs.
Only these statuses change:

- compat.ExteraConfig.getUseSystemFonts()
- compat.ExteraConfig.setUseSystemFonts(boolean)
- compat.ExteraConfig.getTabletMode()
- compat.ExteraConfig.setTabletMode(int)

The 220/44/44 source partition and canonical `sdk-config-input-v1` inventory contract
are preserved. Contract SHA-256 remains
`37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`.
The mutable aggregate inventory raw hash is not restored to SOURCES. Counts now
include an explicit blocked:0 for consumers after complete binding resolution.

## Root fixture and checks

- Actual root registration contains AppearanceFeatures.definitions. Its registered
  initializer references both new policy groups; negative tests remove each reference
  and require generation to fail rather than discover an unregistered declaration.
- The native fixture still calls `settings.register(SDKConfigRootRegistration.definitions)`.
  The driver stages that expression from root groups, including AppearanceFeatures.
  The fixture is byte-identical to `a320166c`; it does not self-register either new
  policy. Runtime/Host/TL and native renderer sources were not edited by this SDK join.
- SDK tests check exact ConfigItem/native-key identity, live Bool/Int values and native
  defaults, all three layout values, rejected out-of-range/Bool-as-Int inputs, write
  rollback, settings-rights rejection and named failure when native registration is absent.
- **22 passed on CPython 3.12.10 (13.64 s)** and **22 passed on 3.14.8 (12.61 s)**.
  Runtime fixtures use fresh 20-second children; each focused suite was capped at 30 s.
  The canonical-contract metadata-drift, path-flavour/hash-seed and bounded-diagnostic
  regressions are included. Regeneration/check and scoped whitespace checks passed.

Native UIFont/CoreText identity, glyphs, layout/rendering and resource/target validation
remain the Font/Layout owners' and Builder's native gates. These Python checks and
source wiring are not a native rendering pass. Cloud patch sections were not applied
by this task. No CI/commit/push or watcher polling was performed.

Exact ready-file/dependency hashes and JUnit paths:
`tests/sdk-font-layout-checks.json`.
