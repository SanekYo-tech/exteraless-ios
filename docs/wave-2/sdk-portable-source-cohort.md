# Final portable SDK source activation

**276 implemented / 0 blocked / 32 unsupported**, exactly **308 ExteraConfig IDs**
with the **220 mapped / 44 storage / 44 utility** source partition.
This uncommitted source cohort follows the accepted Font/Layout join. Earlier Mac
snapshots and their results keep their original identities.

## Actual registered inputs

| SDK/source surface | Native key or array | Registration path |
|---|---|---|
| NekoConfig.typeface; ExteraConfig.get/setUseSystemFonts | appearance.useSystemFonts; Bool, default true | Root → AppearanceFeatures → CoreAppearanceFontFamilyPolicy.definitions |
| NekoConfig.tabletMode; ExteraConfig.get/setTabletMode | appearance.tabletMode; Int 0/1/2, default 0 | Root → AppearanceFeatures → AppearanceLayoutModePolicy.definitions |
| AppearanceConfig.monetStyle | appearance.monetStyle; Int 0/1, default 0 | Root → AppearanceFeatures → AppearanceMonetPolicy.definitions → definition |
| NaConfig.performanceClass / getPerformanceClass() | tools.performanceClass; Int 0/1/2/3, default 0 | Root → ToolsPerformancePolicy.definitions → definition |
| ChatSwipe | ChatSwipeFeatures.definitions | Actual Root array; no ExteraConfig overload |

The Performance generator hunk is applied with the canonical inventory contract
retained. Monet discovery reads the selected `definition`, resolves `settingKey`,
and checks both array membership and the live AppearanceFeatures reference.
Removing either policy's registration or `[definition]` membership fails generation.
Unreferenced sibling arrays cannot create bindings.

Both new ConfigItems use the existing identity scalar adapter. Live native metadata,
settings permission checks, native option validation and named unavailable errors
remain authoritative. The two new key bindings add no ExteraConfig methods; its
counts, routes and exact IDs stay at the accepted Font/Layout result. Four existing
Appearance binding records only refresh their native declaration line by +1 after
the appended Monet registration.

## Source receipts

- `appearance-parity.json`: Font and Monet now identify actual keys and consumers;
  Layout retains its key and records the applied root-role/SDK registration joins.
- `tools-parity.json`: Performance receipt activation is applied, including the
  actual ChatController energy-publication callsite.
- All four rows retain `ported=false` and pending native verification. Font and
  Monet retain partial parity: exact missing Original font/palette assets, Android
  metrics/OEM wallpaper colors and rendered equivalence remain unverified.
- Domain IDs are preserved. Both edited fragments pass the inventory merge schema
  in memory. `docs/parity/client-features.json` retains its original bytes.

Canonical inventory mode remains `sdk-config-input-v1`, contract SHA-256
`37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`.
The generated receipt contains **59 raw-byte source pins**. The complete list of
**10 pinned domain/disposition JSON inputs**, including unchanged receipts, is
explicit in `tests/sdk-portable-source-checks.json` and
`sdk-final-source-inventory.json`. All ten paths already exist in Git HEAD; the
hashlists identify the current worktree bytes needed for the next snapshot.

## Bounded verification

- **29 passed on CPython 3.12.10 — 14.04 s**.
- **29 passed on CPython 3.14.8 — 13.01 s**.
- Suites capped at 30 seconds; SDK scenarios use fresh 20-second children.
- Covers typed ConfigItem identity, native defaults, all valid scalar options,
  native range rejection, invalid scalar/metadata types and keys, settings rights,
  absent registration, canonical metadata refresh, path/hash-seed determinism and
  bounded stale diagnostics. Regeneration/check and scoped whitespace checks pass.
- The test executes the native driver's actual root-staging write expression in
  isolation. The emitted array contains all **21 actual root groups**, including
  ChatSwipe and Performance. Font/Layout/Monet arrive through AppearanceFeatures.
  The Swift fixture registers this same staged root on initial load and disk reopen.
  Driver and native fixture hashes match the prior source inventory.

Current file/dependency hashes and JUnit artifact hashes:
[`tests/sdk-portable-source-checks.json`](tests/sdk-portable-source-checks.json).
The earlier Font/Layout 22-case receipt remains historical. This cohort's native
compile/execution and UI/resource/frame gates are pending the coordinator's next
compatible Mac snapshot.
