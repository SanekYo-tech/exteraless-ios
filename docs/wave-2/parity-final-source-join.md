# Final source-only parity join

**567/567 Original IDs reconciled; 0 receipt gaps. SDK Config: 276 implemented /
0 blocked / 32 unsupported. Verified/ported promotions: 0.**

Request pin: `fac6cf26be9f622dc1c5eec8cf7cf165fff6200c`.
Materialization HEAD: `16c23a99449eba704885a83982e35a079054f815`.
That intervening coordinator commit publishes reports and a workflow; its
production-source delta from fac6cf26 is **zero**. This join uses exact read-time
source hashes and does not attribute later build results to these inventories.

**Later coordinator follow-up:** IPA43740868881/fac6 failed on **25 TelegramCore
typechecks**; four owners are correcting narrow signatures/captures. A separate
atomic Ghost requirement exposed legacy `for/set` in
`telegram-ios/submodules/TelegramCore/Sources/State/ExteralessOutgoingPrivacy.swift`.
Owner `ses_e1fbf2c33` is changing the Core helper and three writers, including a
ClientRuntime Root method, not definitions. The SDK check below passed **before**
that work. Temporary raw Root-pin drift is expected; the coordinator regenerates
the SDK manifest after completion. This is a new source follow-up, not a broken
Catalog finding. The fac6 receipt is retained without another full scan.

## Delivered

- [Client inventory](../parity/client-features.json): all **567 IDs**, **30 modules**,
  **2614 Original method bodies**, **849 UI definition sites**, **308 overloads**,
  **20 Pill settings + 15 separately retained numeric Pill types**.
- [SDK surface](../parity/sdk-surface.json): **36 modules / 925 symbols**; all 36
  source files independently compared byte-for-byte with Original. Original
  declarations, config/UI/source indexes and module method indexes are preserved.
- [Current reconciliation](../parity/wave-2-reconciliation.md), its
  [exact maps](../parity/wave-2-reconciliation.json), and
  [final source receipt](../parity/final-source-join.json): **19 selected receipts**,
  **675 source/document pins**, 1010 feature callsite references, no unavailable
  callsite paths. One post-join receipt comparison found **0 drift**.
- [Historical cohort locator](../parity/cohorts/93a1badc.json) preserves complete
  old documents via immutable Git blobs/raw SHA-256, including the old 272/4/32,
  Feed/SDK drift and original run IDs. Old owner/review/SDK receipts were not edited.

Current author statuses are **121 implemented / 407 partial / 7 compat-storage /
1 platform-prerequisite / 31 unsupported**, with zero verified. A source receipt
is not a claim that the whole feature has passed native acceptance.

## Five applied portable source joins

| Original ID | Actual key | Joined scope |
|---|---|---|
| `neko.typeface` | `appearance.useSystemFonts` | Apple system / bundled Roboto producer, Root/extensions, typed Cloud import, SDK |
| `neko.tabletMode` | `appearance.tabletMode` | Auto/Tablet/Phone root-content policy, live binding, typed Cloud import, SDK |
| `etgbackup.ChatSwipeAction` | `chats.chatSwipeAction` | Native eligible reveal/pager ownership, Root, exact `mainconfig` Cloud conversion |
| `nagram.performanceClass` | `tools.performanceClass` | Native energy/render budgets and ChatController consumer, Root, Cloud, SDK |
| `appearance.monetStyle` | `appearance.monetStyle` | Native theme actions/factory/codec/replay and extensions, Cloud, SDK |

`chat-swipe` is primary for its one Original ID; the old Tools claim is secondary.
Chat remains primary for `nagram.showTextTranslate`; AI evidence is retained.
All fresh supplemental anchors resolve in actual source. Historical unapplied
patch notes do not override these later bindings.

**Exact Original Monet asset parity remains unavailable:** the six original
Telemone/Classic/AMOLED assets are absent. Older upstream Classic reference
tokens, native HCT roles, accent selection and contrast corrections remain
documented iOS adaptations. Font's absent Original bytes/Pixel Google Sans,
Android metrics and full instance-cache/visual equivalence are also explicit limits.

## Review reconciliation

The current matrix imports the published source closures for **PNP-01–03,
PFM-01, CMC-01–15 (13 + final 03/05), Feed/Player FU-01–04, TLN-01–11 + F01/F02,
SDK-01–09, TBF-01–06, CAF-01–03, PFR01–05**, and the HNS, AI, Identity, Avatar/ASC
and Darwin-storage tails. No remaining reported P1/P2 is carried forward from
those final counterexamples. Historical review states/hashes stay in their own
layers; AI and Avatar `AF-03` identities are report-scoped.

SCR-01 has an owner source-fix report and three named passing Mac Core
regressions. An independent final SCR-01 re-review was not supplied; this
provenance limitation is retained rather than fabricating a reviewer verdict.

## Checks and immutable SDK inputs

- Existing `feature_inventory --check-data`: **PASS**.
- Existing `sdk_config_manifest --check` after join and before the later Ghost
  Root edit: **PASS**, **508 bindings / 308 APIs / 276–0–32**; all **59 raw source
  pins / 10 input receipts** matched that snapshot.
- Canonical `sdk-config-input-v1` remains
  `37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`.
- Existing scanner/parity/join suites: **42 passed, 1.13 s**, CPython 3.12.10;
  [JUnit](../parity/checks/inventory-tests-fac6cf26.xml). External pytest plugin
  autoload/cache disabled; no SDK/runtime imports or external plugin execution.
- Commands were bounded to **30 seconds**. Production, scanner/tools, SDK code,
  ten SDK input receipts and build artifacts were read-only. No commit/push/CI
  or real network operation was performed.

The existing Markdown renderer hard-codes older CI/review prose. Only the owned
docs projection was reconciled; no mechanical scanner change was needed.

## Evidence claims and remaining gates

**Mac 43738810843 / 136c946f SUCCESS** retains its component scope: **671 Core /
180 Host / 30 Hooks**, **23 Foundation HNS**, **Java7**, **3 real Swift/C/CPython SDK
children**, **simulator C219 (169 baseline / 41 owner-bound)** and unsigned device
probe compilation. The completed **independent PASS** report
[runtime-native-acceptance.md](runtime-native-acceptance.md) was received and read,
including **2/2 created/freed terminal payloads**. Its raw SHA-256 is
`a56d2b7eee2b53e02baa978a55628fbde78c7660c3bf5ac29d36a450d94243f5`.
Full artifact/binary verification was not repeated by this join.
Foundation DTO/provider fixtures, standalone simulator execution and a compiled
device probe do not establish Telegram networking, UIKit or full-app acceptance.

- Last verified full Telegram IPA remains **build23 / 43635233046 / 68bb1adf**.
- Full IPA **43740868881 / fac6cf26** was in progress at request, then reported
  **failed on 25 TelegramCore typechecks**. No CI query/poll was performed here.
- New compile and atomic Ghost source follow-ups, and the coordinator's ensuing
  SDK manifest refresh, remain pending their owners. The 567 receipts do not
  claim closure of a requirement found after this snapshot.
- Native plan **36 labels / 85 sources / 88 classes / 410 methods** and eight
  recording scenarios **3+3+2** are source-provided, **not executed**. Frame/PTS
  evidence remains required under `telegram-ios/AGENTS.md`.
- Inventory coverage limits remain: **794 SDK symbols** lack individual behavior
  reconciliation; **32 Config overloads** retain exact unsupported reasons; exhaustive
  `module.general/settings/plugins` member/route maps remain authoring needs.
- **56 file-only feature references** remain an anchor-granularity limit, distinct
  from the old 56 missing receipts, all of which now have claims.

## Updated paths and SHA-256

The exact output list and raw-file hashes are in
[`docs/parity/checks/final-source-output.sha256`](../parity/checks/final-source-output.sha256).
It covers the five regenerated inventory/reconciliation files, join policy/schema,
historical locator, final source JSON, JUnit and this handoff.

Primary immutable output hashes:

| Path | SHA-256 |
|---|---|
| `docs/parity/client-features.json` | `ee82f6d3f53c1ff2ccc9785305b63553ea504abdb5274c11fa9148144d5fc240` |
| `docs/parity/sdk-surface.json` | `ce7b067fdcffc440ba3640ac194c2eef8a68192a80410cbcb3a593e0d9cf64d8` |
| `docs/parity/wave-2-reconciliation.json` | `65c940cbd72d5ebcd50e5e12c87950ab9fc1b56694336cbb1d361cd4a3a5c593` |

SDK input receipt remains
`6624ada22f523f8028f2029b3dba7ac69285349930844d75f172dd48a6410367`;
the aggregate source-evidence fingerprint is
`ebfa8bfdbd74bf621f79e07758acba42ae1a448603acd6d108227db6c988e402`.
