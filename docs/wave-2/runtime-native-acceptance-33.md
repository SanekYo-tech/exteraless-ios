# Runtime native acceptance — run 33

**Независимый PASS в указанных runtime/native-component границах**:
`43795739683 / d8705c51d4ca4b07730fa6cccc1d9885fb453937`.
Проверены сохранённые reports, реальные native case events, source identity и
бинарные артефакты. Проверка выполнена на Windows 2026-11-16.

Результат относится к runtime gate. Последняя отдельно проверенная полная
Telegram IPA — build 40 / `6de4ac36`; этот run не заменяет её binary acceptance.

Evidence: `build/artifacts/python-runtime-43795739683/`.
Машинное заключение:
[`local-verification.json`](../../build/artifacts/python-runtime-43795739683/local-verification.json).

## Загрузка и целостность

| Artifact | ID | ZIP bytes | SHA-256 |
|---|---:|---:|---|
| Runtime 33 | 14195165547 | 43 456 316 | `33565bffc015d46e7bbdeb9ee771d3f9e705bb347dde01d3799eebec5e3dc19d` |
| Swift components | 14194702473 | 430 393 | `e43f09d4891148b144cb3af41d96076c80a4cbdd3884a72ed5b50954e3b8095d` |
| SDK follow-up | 14194907333 | 1 443 986 607 | `786cfd2abe4ebdeec4ec3829d71551b95507e0c2e65f70b421fb990c14251df1` |

Для первых двух ZIP полностью пересчитаны SHA и CRC всех entries. GitHub
metadata всех трёх artifacts независимо подтверждают run/head/size/digest.

Большой SDK ZIP прочитан выборочно: **53 HTTP 206 blocks**, каждый с точным
`Content-Range` и размером body. Прочитан central directory из **40 306 entries**;
получены **49 выбранных файлов / 302 515 uncompressed bytes**. Всего Range bodies
скачано **7 052 333 bytes**; `.build`/`build`/`swift-build` payload не скачивался.
Для всех выбранных entries проверены CRC и SHA; receipts находятся в
`metadata/sdk-followup-selected.json` и `range-cache/index.json`.
**Полный digest и полный CRC sweep SDK ZIP локально не вычислялись.**

Дополнительно скачан completed CI logs ZIP: **99 571 bytes**, SHA
`8b39fb6abf97ece9c86b78d55c046ed7977977337e8cbe6d63039ac391e3f395`,
49 log files с проверенными CRC. CI не запускался и не опрашивался циклически.
Device artifact 14194966617 не скачан: probe IPA и complete runtime manifest уже
находятся в runtime artifact. Bearer token использовался только на GitHub API;
в запросы по signed blob URL он не передавался и в receipts не записан.

## Реальные counts и timings

Проверены отдельные уникальные `started`/`passed` events и suite totals.
Native counts ниже не выводились из числа pytest wrappers.

| Suite | Passed | Build, s | Test launcher, s | Native test / wall, s |
|---|---:|---:|---:|---:|
| ExteralessCore | **722** | 80.689 | 10.600 | 9.147 / 9.294 |
| PluginHost | **273** | 52.736 | 9.484 | 8.327 / 8.402 |
| PluginHooks | **30** | 33.741 | 2.111 | 0.666 / 0.680 |
| HNS Foundation fixture | **23 scenarios** | 50.876 | 1.698 | — |
| Java → Foundation TL | **7 codec cases / 1 pytest** | 3.622 | 0.781 | pytest suite 0.388 |
| Native FD/activation/transactions | **47** | отдельный ≤120 s budget | — | 0.921 / 0.932 |
| Native ingress | **7** | отдельный ≤120 s budget | — | 0.017 / 0.022 |
| Native Root mode-ABA | **4** | 34.405 | 1.014 | 0.088 / 0.093 |
| Darwin developer listener | **native marker + exit 0** | 12.784 | 0.191 | execution budget 10 s |

Failures/unexpected failures в этих native suites — 0. Основные Swift package
budgets — 240 s compile / 30 s test; HNS — 480 s compile / 30 s run. HNS использует
реальный Host worker с fixture engine, `cpython_executed=false`, `uikit_executed=false`.

Native evidence в `ci/logs/CPython 3.12 + native bridge (iOS)/`:

- Step **16**, строки **18–117**: все **47** имён совпали с Git methods —
  6 activation + 29 files/registry + 12 transaction/outcome tests. Включены реальные
  FD custody/cancellation, atomic exchange/rollback, namespace ABA, zero-write
  refusal и post-commit persistence/load failure outcomes. Эти же имена входят
  в общий Host suite; отдельный filtered run не увеличивает число уникальных tests.
- Step **17**, строки **18–31**: **7** ingress/protocol cases, Git pins и пять
  сохранённых Swift-копий совпали. Проверены pre-admission refusal и сохранение
  publication outcomes/исходного error envelope после поздних guards.
- Step **19**, строки **18–25**: **4** mode-ABA cases. В обоих receipts совпали
  64 Git pins; пересчитаны **13 exact production spans**, проверены 10 source
  copies и два сгенерированных Swift-файла. Root methods/native queues/store/Host
  реальные; UI/context/transport и Python execution здесь recorders.
- Step **14** и selected `native-listener/.../evidence/execute.log`: marker
  `SDK_DEVELOPER_NATIVE_OK storage_refusal_ready_owned_bind_error_retry_auth_session_revocation_committed_receipt`,
  exit 0. Все шесть source pins и копий совпали с Git. Это реальный Darwin Network
  listener с собственными loopback clients, без app/account или iOS claim.
- Step **15**: `NATIVE_ELYX_CANDIDATE_OK 2214 -> 2321`. По сохранённым ZIP bytes
  независимо проверены три новых/изменённых тела, восемь сохранённых тел и CRC.

Отдельный `sdk-followup.xml` содержит **49 passed / 13 skipped** из 62 cases,
0 failures/errors, 23.086 s. Skips: 12 cases требуют отдельных explicit C-extension
fixtures, ещё один требует Python 3.14 `concurrent.interpreters`. Они остаются
skipped; список причин сохранён в JSON. Четыре negative readiness cases passed
и не заявляют positive native readiness вместо пятого child.

## Пять реальных SDK child

`five-child-acceptance.json` проверен по всем пяти report SHA, markers, timings,
build-inputs SHA и aggregate source-map hash. `native_children=5`, все stage flags
complete; frozen requirement lists совпали с Git readers.

| Child | Время / budget, s | Required true flags | Interpreters / plugin owners |
|---|---:|---:|---:|
| Initial SDK | **4.227 / 30** | 31 + 10 SDK observations | 3 / 2 |
| TL phase 2 | **2.672 / 30** | 20 | 4 / 2 |
| HNS remediation | **0.997 / 30** | 18 | 3 / 2 |
| Archive lifecycle | **7.159 / 30** | 11 | 13 / 5 |
| Elyx developer | **5.566 / 30** | 14 | 12 / 2 |

У каждого child одна initialization/finalization. Всего **35 interpreter
lifetimes / 13 owner lifetimes**: destroyed/OWN_GIL true, native owner threads
зафиксированы, dispatch/observation errors пусты. Финальные handles, leases,
legacy services и mock calls — 0, loaded-plugin lists пусты.

- Initial SDK сохраняет все прежние lifecycle/owner/permission/reflection/DTO
  checks; live UI/tasks/requests = 0, один callback вне main thread. Transport
  calls **167/31**, errors **1/0** с намеренным unknown-member rejection.
  `darwin_family_fd_paths=true`; `actual_ios_fd_paths` этим child не подтверждён.
- TL: releases `[2…9]`, cleanup и root config binding true. HNS: десять успешных
  уникальных cleanups, 31 release identity, восемь retiring duplicate checks.
- Archive: metadata zero-entry, IDs, trust/settings, reload и same-name
  module/wheel replacement подтверждены; пять разных C owner epochs,
  snapshots first/reload/replacement/literal, zero network/neighbor effects.
- Fifth: реальная public activation/readiness, missing gate/hook/ABI rejection,
  FD inspection и новый verified owner load. Счётчики пяти opaque operations:
  **claim 5 / manifest 5 / read 9 / check 27 / release 9**, прочитано **13 799 bytes**.
  В конце **source receipts / stages / read tickets / capabilities / file authorities = 0**.
  Python/requires refusal сохраняют `ok=false`, `reloaded=false`,
  `source_changed=false`, `publication_outcome=refused`, zero old retirement.

Пятый child содержит **10 metadata bootstrap**, 5 readiness, 2 metadata calls,
3 FD inspections, 2 owner bootstrap, один ordinary load, один verified load и
два unload. Trusted workers не допускают threads и не входят в plugin entry;
каждый реальный owner имеет ровно один entry/load/unload. Реальные hooks:
`developer_manifest=5`, `inspect_developer_descriptor=3`, `verified_developer_load=2`.
First/next snapshot различают helper, asset и same-filename wheel.

Git Swift observer проверяет nil/unrecorded worker, native owner thread при run
и destroy, использует prefix-only detection настоящих load invocations и возвращает
результат engine без подмены. Metadata bootstrap включает sealed vendor root —
проверена именно версия `d8705c51`.

### Честная граница локального replay

Первым трём readers передавались лексические POSIX paths. У четвёртого/пятого
повторены semantic/data predicates; четыре live filesystem predicates (удалённые
extract directories, сохранённый unrelated sentinel, пустая staging directory)
остались CI-only. Отсутствующие CI paths на Windows не использовались как proof.

`verify_native_sdk_cohort.verify` целиком на этих путях локально не вызывался.
Сохранённый CI acceptance согласован с повторной проверкой данных. Шесть входных
payload пятого child дополнительно совпали по SHA с выбранными actual test-fixture
bytes; это content identity, не утверждение о сохранности исходного CI directory.

## Source identity

Все **629/629 runtime fingerprint entries** совпали с raw Git bytes `d8705c51`;
набор путей также совпал. Core/Host/Hooks pins — **282/87/15**, Java — **41**,
HNS — **253**, preflight — **1735** (1733 main-repo + два pinned rules_apple blobs).
Пересчитаны scalar fingerprints, 13 UI postimage files / три scoped regions,
13 сохранённых UI Swift-копий и Config **59 SOURCES pins / 308 API / 276/0/32**.

SDK input map содержит **374 records**:

- **347** direct Git blobs;
- **9** source/staged aliases с одинаковыми seals и проверенными Git originals;
- **7** точных in-memory recipes: пять declaration manifests, generated root,
  dependency marker;
- **6** retained fifth-child input payloads, совпавших с seals;
- **5** archive-child emitted inputs, чьи CI seals согласованы, но actual payload
  в выбранном наборе не сохранён и локально не перехэширован.

Actual staged-copy bytes девяти aliases также не сохранены: это проверка source
identity/seals, а не выдуманная повторная проверка отсутствующих файлов.
Root SHA: `c77116a664f976f194e9754dab1520571ae5f51d9f87e26e0e85b3dbb86f2f93`;
21 группа root expression соответствует generated input.
Descriptor ABI pin `7c1d62d040f75b900bdd0ece50335797fd0596fde5ddb38f8e77b449c3e3c83c`
и NFD-02 source seal проверены против Git. Исходники текущего WIP не использовались.

## iOS C probes и бинарные артефакты

Три iOS reports и embedded runtime-manifest records совпали: CPython **3.12.16**,
`native_completed=true`, exit 0, по два OWN_GIL interpreter. Completed CI step 38
содержит отдельные runtime/engine/bridge standalone markers и final validation
marker. Execution — `simctl spawn --standalone`, installation verified = false.

Current `validate_bridge_report` прошёл: **219 total / 169 baseline / 41 bound**,
previous suite 213, bulk clear 6, прежний owner subset 35. Все **33** required flags
true. Terminal admission **27 checks; rejected 1 / before-clear 1**;
payloads **created 2 / freed 2**, owned refs released/finalized true.
Проверен current C source SHA
`2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2`.

| Файл в `runtime/` | Bytes | Фактический SHA-256 |
|---|---:|---|
| `ExteralessPythonSmoke-unsigned.ipa` | 11 570 004 | `9a303832fc4831b8c549924e39f65a97cbc4a18bfd0e4fc1a466e4b2663b98a9` |
| `Python-3.12-iOS-support.b13.tar.gz` | 32 193 359 | `4eea2c76ad70f2df8c1767489315a16d72cd96ce5c086412ee2d154c3bd8e257` |
| `ExteralessPythonBridge.xcframework.tar.gz` | 81 888 | `015682640eac0d37527c1a84ae65f0836f2dac08769f12d44424401e26c02166` |

Probe IPA SHA и binary records совпали с manifest. Recursive census:
**56 unsigned arm64/platform-2 Mach-O**, **55 frameworks**, **54 `.fwork`/`.origin`
pairs**, все dependency chains разрешаются, CRC всех 1028 ZIP entries прошли.
Все 55 runtime framework binaries совпали с pinned support archive. Device и
simulator headers содержат 3.12.16. Оба tar.gz прочитаны полностью с проверкой
gzip CRC/ISIZE и tar headers; шесть bridge headers совпали с Git, восемь static
Mach-O objects имеют правильный arm64/device-or-simulator platform.

Swift engine и все пять SDK children использовали **macOS CPython 3.12.10**.
Darwin FD flag не удовлетворяет frozen iOS reader, требующему
`platform=ios` и `actual_ios_fd_paths=true`; такого iOS FD receipt этот run не даёт.

12 dependency package pins, lock и seal согласованы:
lock `222da84eea828044f5af0e8d034945662fd74aae6414bc91f67d6311f14ef924`,
bundle `d7fe1f9be22ef7bf3bff75b5d462ebe756039c86226c56948007bed06aef8990`.
Receipt содержит 479 файлов / 8 351 187 bytes. **Vendor payload отсутствует** в
runtime artifacts и probe IPA, поэтому его 479 файлов не перехэшированы; imports
всех 12 distributions на iOS не заявлены.

## Оставшиеся gates

- Полная Telegram app integration/new IPA, physical signing/install/launch,
  native window/GTK, UIKit 20-scene, frames/animations/interactions.
- APNs, реальные Telegram accounts/live RPC, server acknowledgements и live updates.
- Полный Swift/SDK FD pipeline на iOS 3.12.16; Mac native acceptance не заменяет
  actual-iOS observation.
- 13 skipped optional pytest cases, полный SDK ZIP digest, непереданные CI staged
  copies/archive inputs/live cleanup filesystem и vendor payload — с указанными
  выше пределами evidence.

Старые receipts 20/23/40 сохранены; их контрольные SHA приведены в новом JSON.
Изменены только новые локальные records и approved-temp read-only fetch helper.
