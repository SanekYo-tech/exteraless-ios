# Runtime33 — current evidence DATA join

**Готово: independent Runtime33 PASS добавлен в hermetic overlay. NativeSDK5
завершён в точном runtime/native-component scope. Source/ported promotions — 0.**

- Execution: **43795739683 / `d8705c51d4ca4b07730fa6cccc1d9885fb453937`**.
- Report publication: **`4c32f9136fabdc46b3e2e33d3117b6879f522ae5`**.
- Original report: [`runtime-native-acceptance-33.md`](../wave-2/runtime-native-acceptance-33.md).
- Captured raw report: **16 074 bytes**, SHA-256
  `15d27c9dcc9fcf451b3be4d482fdedc3e4efe5b831f2dc87d15497dfd7f411e4`.
- [Immutable snapshot](source-report-snapshots/15d27c9dcc9fcf451b3be4d482fdedc3e4efe5b831f2dc87d15497dfd7f411e4.md)
  загружается существующим loader без Git/network.

## Точная дельта

В `current-source-followups.json.execution_evidence` добавлен один entry
`Runtime33-NativeSDK5`, с counts, timings, custody, diagnostic IPA и limitations.
Reports/snapshots **34 → 35**, всего **3 523 817 raw bytes**. Все прежние 34 pins,
bytes, timestamps и anchors сохранены; старые 10 execution entries не переписаны.

Прежние pending Mac/NativeSDK5 и UIKit records перенесены в history с явными
successor links. Это не объявляет outcome старого run. Текущие remaining gates:
новая полная Telegram IPA и UIKit **43797987677 / 84a0456a**, active по handoff.
Исходный Mac20/e16 PASS остаётся отдельной исторической записью.

Сохранены **567 features / 925 SDK symbols / 30 modules / 14–102–666 member maps /
308 Config overloads / Pills20+15**, все **39 source closures** и **64 f704 source
pins**. Старые partial/unsupported/native_relation и raw author maps не изменены.
Поздняя source-only MapWeak fixture correction не подставлена в tested SHA d870.

## Подтверждённый Runtime33 scope

| Component | Exact result |
|---|---|
| Core / Host / Hooks | **722 / 273 / 30 PASS** |
| HNS / Java | **23 scenarios / 7 codec cases**; HNS остаётся Foundation fixture engine |
| FD / Ingress / Mode | **47 / 7 / 4 PASS**; FD47 также входят в Host273 и не увеличивают unique-test total |
| Real Darwin listener | **0.191 s**, native success marker + exit 0 |
| SDK children | **4.227 / 2.672 / 0.997 / 7.159 / 5.566 s**, каждый в budget 30 s |
| Lifetimes | **35 interpreters / 13 owners**, destroyed/OWN_GIL; по одной init/finalization на child |
| Final FD custody | source receipts / stages / read tickets / capabilities / file authorities — **0 / 0 / 0 / 0 / 0** |
| iOS C probe | **219 total / 169 baseline / 41 bound**, terminal payloads **2 created / 2 freed** |
| Runtime source fingerprint | **629/629** Git matches at d870 |

Эти results взяты из прочитанного independent report, не исполнены повторно
агрегатором. C/SDK/native tests, binary verification и сеть здесь не запускались.

## Ограничения evidence сохранены

- `sdk-followup.xml`: **49 PASS / 13 skips** из 62; 12 optional C-fixture cases и
  один Python3.14 case остаются skipped.
- Девять staged-alias actual copies не сохранены; проверены source identities и seals.
- Пять archive-child payload не сохранены и локально не перехэшированы.
- Четыре live-filesystem predicates остаются **CI-only**; complete cohort verifier
  не заявлен локально исполненным на отсутствующих CI directories.
- SDK ZIP **1 443 986 607 bytes**: 53 Range blocks, **49 selected files**,
  **7 052 333 downloaded bytes**, 302 515 uncompressed selected bytes. Полный
  digest/CRC sweep этого ZIP локально не пересчитан.
- Vendor payload отсутствует: 479 файлов не перехэшированы, imports всех 12
  distributions на iOS не доказаны.
- Darwin FD flags не заменяют `platform=ios` / `actual_ios_fd_paths=true`.
- Diagnostic probe IPA: **56 Mach-O / 55 frameworks**, SHA
  `9a303832fc4831b8c549924e39f65a97cbc4a18bfd0e4fc1a466e4b2663b98a9`.
  Это **Python smoke IPA**, не полная Telegram IPA build40.

**UIKit20/434, frames, новая full Telegram IPA/app integration, physical-device
lifecycle и live Telegram/APNs/network-state acceptance остаются отдельными gates.**
Ни одного native scene frame здесь не наблюдалось; active UIKit run не опрашивался.

## Data checks и доставка

- Existing pure generator выполнил generation, idempotent `--individual-only
  --docs-only --check` и `--check-data` **с запрещёнными Git/subprocess calls**:
  PASS, **5.797 s** суммарно.
- **10 focused existing data-regression cases PASS**, 33 нерелевантных этому
  обновлению cases deselected. Старые test outputs не переписаны.
- Canonical Config contract неизменён:
  `37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`;
  **276 implemented / 0 blocked / 32 unsupported / 308 APIs / 508 bindings**.
- Generator/test/runtime/SDK code не менялся. Existing checks/cohorts, старый
  `current-source-output.sha256`, семь maps и 34 snapshots проверены неизменными.
- Все shell-команды имели предел **≤30 s**; CI/commit/push/network не выполнялись.

[Current machine checks](current-runtime33-checks.json) ·
[Capture receipt](current-runtime33-capture.json) ·
[Data JUnit](current-runtime33-data-tests.xml) ·
[New output paths/SHA-256](current-runtime33-output.sha256).

Прежние `current-source-overlay-checks.json` и `current-source-output.sha256`
описывают предыдущую source/hermetic доставку, а не hashes новых projections.
Input overlay SHA-256:
`e8fe8de2b34d19318cfc88628e0fac687e5b067c162f8c4c86fc1e729d142037`.
