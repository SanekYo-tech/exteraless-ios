# Individual SDK/module source join

**Материализованы 925/925 SDK IDs и все три module maps: 14 General / 102 Settings /
666 Plugins identities. Unknown / duplicate / missing IDs: 0. Verification promotions: 0.**

Первый fac6 source join сохранён как immutable history в
[`cohorts/9bfce05f.json`](../parity/cohorts/9bfce05f.json), с полными Git blob/raw
SHA-256 locators на `9bfce05f708fba472ca942bcfe355914847a347d`.
Новый join продолжает этот feature inventory, а не переименовывает его старые
runtime results. Исходные **567 features / 30 modules / 2614 method bodies /
308 Config overloads / Pills 20+15**, config/UI/source indexes сохранены.

## Материализованные данные

- [`sdk-surface.json`](../parity/sdk-surface.json): каждая из 925 записей содержит
  `individual_source.reported` с точным Original, ordered route, contract,
  limitations и evidence, плюс raw owner receipt SHA и fingerprints.
- [`client-features.json`](../parity/client-features.json): три модуля содержат
  все structured members; Settings — **55 actions + 47 flows/row groups**,
  Plugins — **666 member_routes** с operation/provider/lifecycle/unavailable data.
- [`individual-source-join.json`](../parity/individual-source-join.json): семь
  raw map hashes, captured boundaries/pins, exact partitions и прежние findings.
- [`wave-2-reconciliation.md`](../parity/wave-2-reconciliation.md) и
  [JSON](../parity/wave-2-reconciliation.json): текущая проекция;
  прежние три missing-authorship maps предоставлены. Это не module/feature pass.

| SDK partition | IDs | Captured source-pin fields |
|---|---:|---:|
| core-api | 249 | 65 |
| utilities | 267 | 76 |
| elyx | 262 | 65 |
| newui | 147 | 36 |

SDK source dispositions: **481 metadata / 180 pure-sdk / 79 native-adapter /
50 plugin-contract / 105 partial / 30 unsupported**. `native_relation.status`
использует `source-route-<disposition>`; individual graph coverage не выдано за
выполнение 925 функций. У трёх module maps статус всего модуля остаётся **partial**;
среди 782 member dispositions сохранены **355 partial / 94 unsupported** и точные
native/helper/platform-role категории. Null provider и missing operation не
превращены в implemented.

## Устойчивость к обычной CI-регенерации

Новый pure helper — `tools/compat/individual_routes.py`. `feature_inventory.py`
читает optional explicit `individual_manifests` list из `join-policy.json`.
Список содержит семь путей/raw hashes и ожидаемые counts. Отсутствующий policy/list
сохраняет работоспособность fixture projects без исходников/receipts.

```text
python -B -m tools.compat.feature_inventory --individual-only --docs-only
python -B -m tools.compat.feature_inventory --individual-only --docs-only --check
python -B -m tools.compat.feature_inventory --check-data
```

`--individual-only` использует уже материализованный feature cohort. Обычный
generator также сохраняет и применяет individual layer после lexical build/merge;
старый class-level join его не стирает. SDK declarations/parameters/defaults/return
annotations и structured module identity tuple остаются исходными. Raw map
revision меняется только через явный policy/cohort update.

Реальный read-only путь `build_client_inventory/build_sdk_inventory → merge_parity
→ individual join` проверен в памяти за **21.297 s**: все 925 routes, три карты,
исходные signatures/indexes и canonical Config contract сохранились.
[`individual-regeneration-check.json`](../parity/checks/individual-regeneration-check.json).

## Captured source boundaries и поздняя дельта

[`individual-source-input-audit.json`](../parity/individual-source-input-audit.json)
фиксирует отдельную сверку при HEAD
`897e3106618ab62a779ed26cfc3661115c0caff9`, **2026-11-15T19:31:37 UTC**.
Это read-time observation, не единый объявленный execution snapshot всех карт.

- Core API сохраняет Git **e16f3808**, inventory **9bfce05f**. Другие карты
  сохраняют собственные 9bf-era worktree hashes, включая поздние source edits.
- Всего **459 author pin fields / 323 distinct captured paths**: **395** совпали
  с прочитанными current bytes; **64** позднее изменились. Все 64 captured versions
  найдены по **точному исходному SHA в Git**, unavailable captured bytes — **0**.
- Эти 64 включают ожидаемую смену derived inventory envelopes и **18** изменённых
  source/test paths. Для каждого сохранены old/current hashes и matching Git
  revisions. Различные read times не объявлены ID collision или whole-map failure.
- General JSON FROZEN с boundary **d7d499f7**, но без author pin table. Дополнительно
  выведены **18** raw Git pins именно d7, отдельно помеченные как data-join-derived.
  Они не выданы за авторские hashes или за новую native verification.
- Проверены **7404 captured line bounds**, invalid — **0**. Ещё **120** reference
  objects не содержат authored line; номера им не придуманы. Проверка bounds не
  выдана за unique-symbol/callgraph/behavior proof.

Полный список 18 source/test paths находится в JSON. Он включает runtime
`__init__/_facades/_platform/_scheduling/_tl/_ui`, virtualjava proxy, Host
model/protocol/storage/event paths, Runtime composition, Manager settings
controller/model и два SDK test files. Поздние changes сохраняются для overlay,
а не подставляются в старые tested/source receipts.

## Findings остаются у owners

**14 source findings без closure overlay**, плюс **3** General aggregate reset
routes, остаются явно открытыми для follow-up:

- `ELYX-GAP-01`, `ELYX-P2-01/02`, `utilities-P2-001`: archive/gen/dev/daemon.
- `PLUGINS-P2-01` и `CORE-API-F02`: direct hook ledger и send priority.
- `CORE-API-F01/F03/F04/F05`: omission, class existence, callback containment,
  named-queue cancellation.
- `PLUGINS-P2-02/03/04`: Manager Custom, aliases/links, TrustLevel.
- `MS-ROUTE-01`: Settings search/index/resolver.
- `GeneralHelper.resetSettings`, `GeneralHelper.resetAllSettings`,
  `GeneralConfig.reset`: точные aggregate/group reset providers.

`GENERAL-SCALAR-01` отдельно сохранён как **owner-reported source-fixed at d7**:
contentCapture/crashReports callable через actual native keys, **30/30** Python
checks на каждой версии по [owner report](sdk-general-scalar-readers.md). Это не
закрытие трёх reset routes и не post-d7 native execution. Новых behavior findings
агрегатор не выпускал; background source edits не объявлены закрытиями.

## Integrity checks

Полный machine report:
[`checks/individual-integrity.json`](../parity/checks/individual-integrity.json).

- **34 новых integrity tests PASS**, **42 прежних inventory tests PASS**;
  CPython 3.12.10, external pytest plugins/cache отключены. JUnit сохранены.
- `--individual-only --check` и `--check-data` — **PASS**.
- Real ordinary-regeneration dataflow — **PASS**, см. выше.
- Проверены exact IDs, original signatures, same-arity method identities,
  provider/null/limitation shapes, отсутствие promotions, сохранность captured
  payload, optional policy/no-files fixtures и raw map/size bounds.
- Первый новый regression test обнаружил одноразовый metadata drift при втором
  regeneration. Helper исправлен; final suite и actual regeneration прошли.

### SDK Config — coordinator refresh, не Catalog defect

После join выполнен разрешённый `sdk_config_manifest --check`. Он показал
**одну** позднюю raw-pin разницу в `SOURCES`, без других manifest value changes:

`telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift`

- stored: `6998d97a25376dcdc8f9b965ef5fcc4f1a3309b309b30fd74e9c90ed13f019ee`
- expected at check: `ba0330321b86bb8a112193d50fc8b5368b5335c9065230fd8402677956baf1ad`

**508 bindings / 276 implemented / 0 blocked / 32 unsupported** и canonical
`sdk-config-input-v1` сохраняются:
`37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`.
Coordinator регенерирует manifest после owner source completion. `_config_manifest.py`,
10 SDK input receipts и production/runtime code этой задачей не изменялись.

## Execution evidence

Прочитан [independent Mac20 PASS](runtime-native-acceptance-20.md),
**43743252038 / e16f380836c10de3fb1d08f468f1242788eb245d**:
**680 Core (9 Ghost включены), 180 Host, 30 Hooks, 23 HNS, Java7, 3 SDK children,
C219 / 169 baseline / 41 bound, 2/2 terminal payload cleanup**.
Report SHA-256:
`e8657e9f7d654a0e0fb24f62f73e9085cca378f1a112bb53172c9388f4345358`.

Binary/artifact verification не повторялась. Этот component/Foundation/standalone
gate предшествует d7 и текущим remediation changes; он не доказывает graph-wide
SDK execution, Telegram network/state, UIKit или full IPA. **36 labels / 85 sources /
88 classes / 410 methods / 8 recordings** остаются отдельной native/UI приёмкой.
IPA **43749522967 / e766b61e** — in-progress по handoff; её статус не запрашивался.

Все команды имели предел **≤30 s**. CI/commit/push/network, foreign plugins и
native execution не выполнялись. Следующий слой — явно опубликованные owner
remediation overlays; этот fully materialized data join готов к их стыковке.

## Paths и SHA-256

Все изменённые/новые owned outputs перечислены в
[`checks/individual-source-output.sha256`](../parity/checks/individual-source-output.sha256).
Главный individual receipt SHA-256:
`69046f796cff7e506264d3c62aaf8a04d0c6f4650b2897868fc85354e8f2c85f`.
