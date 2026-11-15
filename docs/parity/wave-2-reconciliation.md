# Individual source-route reconciliation

**925/925 SDK symbols; 3 module maps; 782 exact Original member identities. Verification promotions: 0.**

[Individual JSON](individual-source-join.json) · [Client inventory](client-features.json) · [SDK925](sdk-surface.json)
[Captured-source audit](individual-source-input-audit.json) · [fac6 history at 9bfce05f](cohorts/9bfce05f.json) · [Handoff](../wave-2/individual-source-join.md)

The retained feature cohort has 567 IDs, 30 modules, 308 Config overloads and 15 separate Pill types.
Config remains 276 implemented / 0 blocked / 32 unsupported. Original SDK signatures and module method indexes are unchanged.

## Captured author maps

| Owner | Records | Raw map SHA-256 | Captured pin fields | Dispositions |
|---|---:|---|---:|---|
| [core-api](../../docs/wave-2/sdk-symbols/core-api.json) | 249 | `27d04bd9b7d39fff971842592982445f2d39e3cf5bda4996eca9ba0b6ee6c783` | 65 | `{"metadata": 81, "native-adapter": 30, "partial": 62, "plugin-contract": 13, "pure-sdk": 46, "unsupported": 17}` |
| [utilities](../../docs/wave-2/sdk-symbols/utilities.json) | 267 | `2ac21bccf6e5ca7046bd7a6060c15b1bcebcc44fe4403dd1d39a75af018f16a0` | 76 | `{"metadata": 163, "native-adapter": 21, "partial": 11, "plugin-contract": 15, "pure-sdk": 57}` |
| [elyx](../../docs/wave-2/sdk-symbols/elyx.json) | 262 | `f4e52c05d14eda15c8278c972fdbca16aecd320637e3f19b586db4ed5853ae95` | 65 | `{"metadata": 157, "native-adapter": 9, "partial": 16, "pure-sdk": 72, "unsupported": 8}` |
| [newui](../../docs/wave-2/sdk-symbols/newui.json) | 147 | `2d07544d4806b466d6d3969191ccb88148d4efc027c6cd07210d6a247d41e400` | 36 | `{"metadata": 80, "native-adapter": 19, "partial": 16, "plugin-contract": 22, "pure-sdk": 5, "unsupported": 5}` |
| [module-general](../../docs/wave-2/module-routes/general.json) | 14 | `53a522771fede9455b8d4a8c02f063cfae2604f2ad7542f1c94b77aee69fcae7` | 0 | `{"native-adaptation": 3, "native-adapter": 3, "native-lifecycle-adaptation": 2, "partial": 3, "unsupported": 3}` |
| [module-settings](../../docs/wave-2/module-routes/settings.json) | 102 | `ffc974596dbabdc71a4667e6673eca21dfd0a7eb0ab283832e6984daef1e406f` | 92 | `{"equivalent-platform-role": 26, "native-flow": 8, "partial": 43, "unsupported": 25}` |
| [module-plugins](../../docs/wave-2/module-routes/plugins.json) | 666 | `1b8c2b1bb167248a741bf27bbdbb082f1dbc51f37254d686ad3385c331a3574c` | 125 | `{"member-body": 134, "partial": 309, "platform-lifecycle": 89, "platform-renderer": 40, "source-routed": 28, "unsupported": 66}` |

Every SDK row carries its exact ordered route, contract, limitations and evidence in `individual_source.reported`.
`native_relation.status=source-route-<disposition>` is source attribution, never a ported/native test result.
Module `individual_source.reported` retains all structured members, Settings actions/flows and Plugins provider/lifecycle routes; module implementation statuses stay partial.
The old three missing authorship maps are supplied. Their partial/unsupported operations remain visible; a missing provider never becomes implemented.

## Mixed source boundaries

Raw map hashes and each author's source boundary/pins are retained verbatim. Shared paths may have different hashes in different captured maps.
Route lines remain captured lines; current source changes are listed separately in the input audit. Matching a later Git blob does not make it tested.
General supplies a d7d499f7 boundary without an author pin table. Its raw map is pinned; separately derived Git pins are labelled in the audit.

## Findings retained for follow-up

| Receipt owner | Finding | Reported state |
|---|---|---|
| core-api | `CORE-API-F01` | source finding; no closure supplied by join |
| core-api | `CORE-API-F02` | source finding; no closure supplied by join |
| core-api | `CORE-API-F03` | source finding; no closure supplied by join |
| core-api | `CORE-API-F04` | source finding; no closure supplied by join |
| core-api | `CORE-API-F05` | source finding; no closure supplied by join |
| utilities | `utilities-P2-001` | source finding; no closure supplied by join |
| elyx | `ELYX-GAP-01` | existing explicit platform exclusion; source-only |
| elyx | `ELYX-P2-01` | new source counterexample; not executed |
| elyx | `ELYX-P2-02` | new source counterexample; inherited in byte-identical Android SDK; not executed |
| module-general | `GENERAL-SCALAR-01` | source-fixed |
| module-settings | `MS-ROUTE-01` | source finding; no closure supplied by join |
| module-plugins | `PLUGINS-P2-01` | open-source-gap |
| module-plugins | `PLUGINS-P2-02` | open-source-gap |
| module-plugins | `PLUGINS-P2-03` | open-source-gap |
| module-plugins | `PLUGINS-P2-04` | open-source-gap |

- ELYX-GAP-01 archive admission and ELYX-P2-01/P2-02 gen/dev handoff, plus utilities-P2-001 daemon lifecycle: assigned; not closed by data merge.
- PLUGINS-P2-01 direct hook ledger and CORE-API-F02 send priority: assigned; no closure overlay selected.
- CORE-API-F01/F03/F04/F05 omission, class existence, callback containment and named-queue cancellation: assigned; no closure overlay selected.
- PLUGINS-P2-02/P2-03 Manager Custom and original alias/link routes: assigned; no closure overlay selected.
- PLUGINS-P2-04 TrustLevel and MS-ROUTE-01 Settings search: assigned; no closure overlay selected.
- GeneralHelper.resetSettings, GeneralHelper.resetAllSettings and GeneralConfig.reset: three explicit partial routes remain assigned. GENERAL-SCALAR-01 is only the separate owner-reported d7 scalar-reader fix.

A new production edit or remediation report is not automatically a closure overlay. This data join creates no new behavior finding or review verdict.

## Execution evidence boundary

- **Independent Mac20 43743252038 / e16f380836c10de3fb1d08f468f1242788eb245d**: PASS within runtime/component gate. 680 Core including 9 Ghost, 180 Host, 30 Hooks, 23 HNS, Java7, 3 real SDK children, C219/169 baseline/41 bound and 2/2 terminal payload cleanup. Foundation/standalone evidence precedes d7 and does not verify individual routes, production Telegram network or UIKit. [runtime-native-acceptance-20.md](../../docs/wave-2/runtime-native-acceptance-20.md).
- Full IPA **43749522967 / e766b61e241598dccc8017bcd205bfe8b7c792ce**: in-progress; not queried or promoted to success by this join.
- 36 labels / 85 sources / 88 classes / 410 native methods and eight recording scenarios remain source-provided, not executed/visually accepted by this join.

## Integrity

The optional explicit `individual_manifests` policy is consumed by ordinary generation and by `--individual-only --docs-only`.
Exact IDs, original signatures, typed module identities, raw owner hashes and false promotion flags are checked before writing. `--check-data` validates the materialized layer without reading moving production sources.
The handoff records executed integrity tests and the scoped SDK manifest check; source-only checks cannot establish runtime/provider/visual parity.
