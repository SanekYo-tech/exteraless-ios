# f704 — current source remediation/evidence DATA overlay

**Готово: 39 effective source-closed scopes; registered source scopes still open — 0.
Все 17 прежних assigned scopes представлены. Verified/native-verified/ported promotions — 0.**

Основа — опубликованный
`f704d76c1596eb0086d08e49dd049796a0220c2f`; предшествующий individual join
`8b726b757a692da2c883cd2c3258c1ff84d5c94b` остаётся историей.
Исходные **567 features / 30 modules / 925 SDK symbols / 308 Config overloads /
Pills 20+15**, **14/102/666 module maps**, signatures, raw author routes/hashes,
partial/unsupported статусы и старые report open fields сохранены.

## Материализация и regeneration

- [Explicit input](current-source-followups.json) закреплён raw hash в optional
  `join-policy.json.current_source_overlay`.
- [Effective JSON](current-source-reconciliation.json) и
  [readable projection](current-source-reconciliation.md) содержат source closure,
  review bounds, prerequisites, origin-report identities и evidence.
- Client/SDK/individual/wave-2 reports обновлены одним generator flow. Добавлены
  только `current_source_evidence` и current layer/reference; captured claims
  не редактировались вручную.
- Старый `individual_context.assigned_followups` сохранён под
  `historical_assigned_followups`. Текущие source states берутся из overlay.
- Обычная генерация и `--individual-only --docs-only` применяют один pure overlay.
  Перегенерация/check idempotent; fixtures без overlay/source files остаются valid.

### Hermetic capture correction для shallow checkout

Все **34 captured report bytes (3 507 743 bytes)** теперь входят в
`source-report-snapshots/<sha256>.md`; каждый `documents` pin содержит
`snapshot_path`, а input требует все snapshots. Byte counts/SHA/anchors,
captured timestamps, execution scopes и 64 source pins f704 не изменены.
Scoped `.gitattributes` сохраняет raw bytes без Git newline conversion.
Удаление только storage metadata восстанавливает прежний input SHA
`91d6560e3c15ad327c3761bae750f12ed3503fc14054a626551bb65bcd3333ce`.

В частности, listener report загружается с исходным **`db36648a…`**, даже когда
live document имеет новый **`ba9764ff…`**. Loader предпочитает проверенный archive;
Git/network для shipped policy не нужны. Corrupt/missing snapshot, wrong path/hash
или symlink escape — явный отказ, без fallback на live/Git и без ослабления anchors.
Legacy Git fallback сохранён только для явно неархивированных старых inputs.

**43 focused overlay tests PASS** после исправления: оба CLI-пути, source-free
fixtures без `.git`, изменённые/отсутствующие live reviews, запрет любых subprocess,
raw CRLF/Unicode, corrupt bytes/path/hash/size и missing/ambiguous anchors.
На реальных 34 snapshots с запрещёнными Git/subprocess также прошли generation,
`--individual-only --check` и `--check-data` за **6.062 s**; anchors/effective scopes
побайтно/структурно совпали с предыдущими.
[Capture receipt](current-source-snapshot-capture.json) ·
[Actual load/CLI proof](current-source-hermetic-load-check.json) ·
[Focused JUnit](current-source-snapshot-tests.xml).

**160 explicit links:** 25 SDK symbols, 10 Ghost feature IDs, 28 exact Original
module members и один module-scope target. Module-scope означает атрибуцию
механизма, а не pass всех 102 Settings methods. Полные остальные 925/567 строки
сохраняются, включая их прежние ограничения.

## Effective closed identities

Ключ всегда **origin report + exact ID**. Bare R1/S1/NFD labels не объединяются.
Полные пары, raw hashes и ссылки находятся в machine projection.

| Scoped family | Effective identities | Основание |
|---|---|---|
| Core SDK | CORE-API-F01–F05 | SDK symbol remediation source closure |
| Direct hooks | PLUGINS-P2-01 | Та же independent closure, actual shared ledger |
| Elyx / daemon original scopes | ELYX-GAP-01, ELYX-P2-01/02, utilities-P2-001 | Baseline joins + ARCH/platform/NFD/lifecycle chains; локальный dev fix отдельно не засчитан за полный ingress |
| Manager | PLUGINS-P2-02/03 + MCA-F01/02 | Baseline Custom/own-target joins + final ordering closure |
| Trust | PLUGINS-P2-04 + S1/S2/S3 | Baseline level/cap model + secondary permission closure |
| Settings search | MS-ROUTE-01 + R1–R5 | Baseline index/routes + five final caller/lifetime/qualifier closures |
| General resets | 3 exact named General routes + RSR01/RSR02 | Actual scoped catalog/provider + final Display-return/retry closures |
| Archive follow-ups | ARCH-01/02/03 + P2-01 of the archive-P1 report | Independent P1 and iOS-platform closures |
| Native Elyx | NFD-01/02/03 + DEV-LIFECYCLE-01 | Independent FD/final-source/mode-ABA closures |
| Earlier provenance gaps | SCR-01; named scope **Ghost toggle** | Actual `settings-quarantine-source-closure.md` and `ghost-toggle-source-closure.md` |

Итого **35 named findings + 3 named routes + 1 named scope = 39**. Source state
относится только к проверенному counterexample. Например, Manager alias closure
покрывает own-id/native target; новый внешний `p/s` URL handler не заявлен.
General catalog сохраняет unavailable disclosures и раздельные credential phases;
нет обещания cross-Keychain atomicity. Platform-unsupported и missing-provider
dispositions не ослаблены. GENERAL-SCALAR-01 остаётся отдельным owner-reported d7
source fix, без выдуманного нового independent verdict.

## Captured evidence и Git boundaries

- **34 report documents** имеют read-time raw SHA-256/byte pins и точные Git versions.
  **31** присутствуют в f704; FD cancellation main-subset addition и два новых
  Mac/listener receipts используют явно более поздние report file versions.
- **64 reported fix paths** закреплены именно по raw Git f704 bytes. Старые
  reviewer/source-map pins не заменены этими hashes.
- Три listener postimages отдельно совпали с publication **78f37532** и actual
  execution **bbc54817**. Это execution-specific delta, не замена f704 source groups.
- Loader проверяет raw tracked-ready snapshots и уникальные explicit report anchors. В `--check-data` проверяются
  уже captured anchors/input fingerprints; live 567-feature paths не репинятся.
- Existing `checks/`, `cohorts/`, семь raw maps и readonly individual-route helper
  проверены по [protected-history guard](current-source-protected-history.json):
  **17/17 совпали**. Cohort9bf checksum остаётся прежним.

## Доступные execution receipts — точные scopes

| Evidence | Подтверждённый scope |
|---|---|
| **IPA40 — 43779402542 / 6de4ac36** | Independent unsigned 13.1.1(40) compile/package PASS; 67 Mach-O / 60 frameworks / 1418 resource placements / 419 pins. Не покрывает f704 SDK delta. |
| **Linux — 43784503847 / f704** | 712 Core / 273 Host / 30 Hooks PASS, independent exact 47-case subset и identical Host source tree. Общий CI завершился на PyYAML; global PASS не заявлен. |
| **FD47 — 43784959730 / d213** | 47 cases / 0.453 s; native Linux FD/Host/registry, с указанными inspector/Python recorders. |
| **Ingress7 — 43781210777 / a707** | 7 Foundation ingress cases PASS; весь run имел Host timeout. |
| **ModeABA4 — 43783735908 / 11b87846** | 4 native Linux cases, actual Root spans/provider queues/preferences; transport/UI/Python — labelled boundaries. |
| **POSIX50 — 43774694321 / ff0c** | 50/0 Python/POSIX cases; не Apple FDRegistry или fifth-child proof. |
| **C gate — 7/7 на 3.12 и 3.14** | Test-instrumented actual C с native C recorder, не FDRegistry. |
| **Mac20 — 43743252038 / e16** | Прежний полный component gate: 680/180/30, 9 Ghost, 3 SDK children, C219; остаётся своим snapshot. |
| **Mac Core722 — 43786995069 / 5fa35f34** | **GLOBAL FAILURE**, но 722 Core + 30 Hooks PASS; 297/297 Git-pins и exact log hashes. Host/listener/UI failures не скрыты. |
| **Darwin listener — 43787862250 / bbc54817** | Real isolated Network compile **9.864 s**, execution **0.337 s** PASS. EINVAL duplicate endpoint/port исправлен в 78f37532; шесть inputs/три postimages подтверждены. `.waiting(EADDRINUSE)` — source-only, iOS не исполнялся. |

Source links, captured report hashes и исходные limitations каждого receipt
находятся в `execution_evidence`. Binary/artifact verification здесь не повторялась.

### Текущие pending blockers

- **Mac43788170016 / d296e456** активен под coordinator watcher. Published Host/UI
  compiler fixes и isolated listener PASS не являются завершённым HNS/NativeSDK5 gate.
- **UIKit43788169856 / d296e456** активен после прежнего aquery-before-compile
  failure. **37 labels / 89 sources / 92 classes / 434 methods / 20 scenes**
  ещё не имеют полной execution/frame приёмки.
- Новый complete five-child pipeline не завершён. Для f704 нет новой full-client
  acceptance сверх более раннего build40. **Observed native scene frames: none.**

Исторические readiness/aquery failures сохранены в `execution_history`, не
превращены в новые source findings и не удалены последующим isolated PASS.
Ни один active run не опрашивался этой задачей.

## Выполненные проверки

- Первый overlay: **27 overlay tests + 76 existing inventory tests PASS** на CPython 3.12.10;
  эти 103 результата сохранены как история. Для hermetic fix выполнен focused 43-case module.
  Есть проверки report-local ID collision, wrong target/overload, missing coverage,
  prerequisite cycles/open children, promotion refusal, captured Git report
  fallback, corruption и ordinary/individual-only idempotence.
- Реальные `--individual-only --docs-only --check` и `--check-data` — **PASS**.
- Прямое сравнение с immutable **8b726b75** подтвердило равенство всех исходных
  SDK/client/module records после удаления только additive current links.
- Config canonical contract неизменён:
  `37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`.
  **508 bindings / 276 implemented / 0 blocked / 32 unsupported / 308 overloads**.
  Текущий readonly receipt имеет 59 source pins; SDK/Root pins не исправлялись.
- Все shell-команды ограничены **30 s**; foreign plugins, runtime imports, CI,
  network, commit/push и native execution не выполнялись.

[Machine checks](current-source-overlay-checks.json) ·
[Overlay JUnit](current-source-overlay-tests.xml) ·
[Existing inventory JUnit](current-source-inventory-tests.xml).

## Changed paths / SHA-256

Точный список owned outputs и raw SHA-256:
[`current-source-output.sha256`](current-source-output.sha256).
Input overlay SHA-256:
`cc5d19b504519e29b46a0d650e14cffeb6ce926dbe46dcd43bc4624fdbb0d9cd`.
