# Runtime native acceptance — run 20

**Независимый PASS в границах runtime/component gate**:
`43743252038 / e16f380836c10de3fb1d08f468f1242788eb245d`.
Проверка выполнена на Windows 2026-11-15 по сохранённым артефактам и сырым
Git blob bytes этого коммита. Текущий worktree не использовался как эталон.

Машинное заключение:
[`local-verification.json`](../../build/artifacts/python-runtime-43743252038/local-verification.json).
Набор: `build/artifacts/python-runtime-43743252038/{runtime,swift-components}` —
57 исходных файлов, 45 884 466 bytes. Отдельный device artifact не скачан;
фактические probe IPA и bridge archive проверены из `runtime/`.

| GitHub artifact | ID | Предоставленный SHA-256 внешнего ZIP |
|---|---:|---|
| Runtime | 14173775782 | `c3149ff47e29e109b41f52df31a4ac3d5c20414d7924a3396e13b594d3d72963` |
| Swift components | 14173707171 | `b5b8d59208e7be327daec93c4b31678e1c0cb4499dc4c2dda6129e6dee299a96` |

Внешние ZIP отсутствуют: их digest записаны как предоставленные метаданные,
не перехэшированы и не сравнивались с распакованными каталогами. Pure validators
из Git имеют те же bytes, что в run 19. Локально выполнялись проверки данных и
архивов; native probes, плагины, CI, сеть, устройства и SDK regeneration не
запускались. Все shell-команды имели предел 120 секунд.

## Counts и timings

Проверены уникальные индивидуальные `started`/`passed`, итог `All tests`,
`ok/phase=complete` и unfiltered `--skip-build` launchers. Failures, unexpected
failures и skips отсутствуют.

| Проверка | Passed | Build, s | Test launcher, s | XCTest test / wall, s |
|---|---:|---:|---:|---:|
| ExteralessCore | **680** | 87.179 | 10.505 | **8.912 / 9.060** |
| PluginHost | **180** | 63.871 | 15.408 | **6.530 / 6.581** |
| PluginHooks | **30** | 24.491 | 1.914 | **1.058 / 1.073** |
| HNS Foundation fixture | **23 scenarios** | 46.195 | 1.685 | — |
| Java → Foundation TL | **1 pytest / 7 codec cases** | 7.087 | 1.356 | pytest suite 0.704 |

CI budgets: Swift 240 s build / 30 s test; HNS 480 s compile / 30 s run;
Java 240 s compile / 30 s pytest / 20 s codec. Java XML не содержит skips/errors,
SHA сохранённого executable совпал с report:
`6e582807bb3efd372ca870987d2c6ad59aa6c1d3f350c7cc5347b34e9f160e15`.
HNS23 по-прежнему использует real Host worker + fixture engine:
`cpython_executed=false`, `uikit_executed=false`.

### Девять новых GhostMode tests

Все девять входят в Core 680. Suite: **0.193 s test / 0.195 s wall**;
`swift-components/ExteralessCore/test.log:1217–1237`. Набор test methods в
Git-исходнике точно совпал с набором реально started/passed имён.

| Метод `PrivacyGhostModeMutationTests` | Started / passed line | Время, s |
|---|---:|---:|
| `testAllLockedReturnsActiveWithoutAReplacementOrObservation` | 1218 / 1219 | 0.005 |
| `testBothDirectionsAndResetWriteAndObserveOneCompleteGeneration` | 1220 / 1221 | 0.011 |
| `testMixedLockedValuesKeepAbsenceExplicitDefaultsAndOverrides` | 1222 / 1223 | 0.006 |
| `testPreAndPostReplaceFailuresExposeOnlyWholeStates` | 1224 / 1225 | 0.010 |
| `testPresenceOnlySetAndResetRejectEveryGhostDependency` | 1226 / 1227 | 0.087 |
| `testResultBelongsToThisProjectionEvenIfAnObserverTogglesAgain` | 1228 / 1229 | 0.003 |
| `testStaleLockValuesRejectEveryGhostLock` | 1230 / 1231 | 0.022 |
| `testStaleValuesRejectUnlockedAndAllLockedSnapshots` | 1232 / 1233 | 0.044 |
| `testSuppliedBeforeIsNotReplacedByARefreshedCache` | 1234 / 1235 | 0.005 |

Проверены assertions закреплённого source: реальные временные
`client-settings.json`, `ClientSettings`, чтение/reopen файла, external writer,
file-replacement hooks и observer snapshots. Они подтверждают целое поколение
на toggle/reset, сохранение locked absence/defaults/overrides, отсутствие записи
при all-locked, pre/post-replace recovery, stale-CAS для value/lock/presence и
результат собственной projection при повторном toggle из observer.
Это file-backed Core outcomes; UIKit interaction ими не проверяется.

## Git input snapshot и Config

| Snapshot | Проверено |
|---|---:|
| Runtime `source_fingerprint` | **565/565** raw Git hashes; точный набор путей |
| SDK `build-inputs.source_sha256` | **314**: 312 Git blobs + 2 generated inputs |
| Root source / Java cohort | **1/1**, **9/9** |
| Core / Host / Hooks input hashes | **274/274**, **64/64**, **15/15** |
| Java TL / HNS23 inputs | **34/34**, **235/235** |
| Input preflight | **999/999** hashes и byte lengths: 997 main-repo + 2 gitlink |

Уникальные artifact inputs: 1026 main-repo blobs, два blob из подтверждённого
`rules_apple@485016eb5b0948cc17307064e7977a6d68e94046`, два generated input.
Повторно проверены scalar fingerprints, 13 UI postimage files / три scoped
region, 12 staged Swift-копий и generated package SHA. Несовпадений нет.

Ключевые SHA-256 в `e16f3808`:

| Source | SHA-256 |
|---|---|
| `PrivacyGhostModeMutation.swift` | `828fa0a2aea53b33181e7adb1e2655c7197097de6f3e071923444c91be7b2d7b` |
| `PrivacyGhostModeMutationTests.swift` | `eb5adc4118edf2d3cb7014268466ac387fe0f89f61ce4bd447fc57aeb8a2d261` |
| `python/exteraless_runtime/_config_manifest.py` | `e07ab6008635478254b19e3b1cca5d8ab3e858bdd365f29f8c27fb81e9a92e30` |
| `ExteralessClientRuntime.swift` | `5709414fc3a29f553eb160c3fc267956e3138de56fc207cbcf61e57981a4dcbf` |

Root покрыт `build-inputs`, отдельным `root_source_sha256`, preflight и Config
`SOURCES`. Generated root проверен точным in-memory recipe по 21 группе Git
root expression на строке 55: SHA
`35f7b3e80e43460508314bc2e610b59e9ee2d721da2d22236bba1f740eba50f9`.

**Config: 308 API; 276 implemented / 0 blocked / 32 unsupported** — counts
пересчитаны из Git receipt. Все **59 SOURCES pins** совпали с Git. В сравнении
с run 19 изменился только root pin; остальные literal constants и receipt без
`source_pins` идентичны. Canonical inventory contract заново проверен:
`37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`.
SHA canonical manifest без `SOURCES`:
`d317e0d4b659709f16290df1596b02b6037ee0da2224c6d1e6f822bbd5b6c404`.

Дельта runtime fingerprint к run 19: 559 → 565, шесть added, девять changed,
550 unchanged, ноль removed. Core добавил ровно helper + девять tests в одном
новом test file. SDK build-inputs добавил helper и обновил Config/root hashes.

## Native SDK и C cleanup

| Новый SDK child | Время / budget, s | True contract checks | Metadata + plugin interpreters |
|---|---:|---:|---:|
| Первый SDK | **4.081 / 30** | 31/31 | 1 + 2 |
| TL | **2.189 / 30** | 20/20 | 2 + 2 |
| HNS | **1.072 / 30** | 18/18 | 1 + 2 |

Все три сохранённых report прошли соответствующие pure validators; каждый
completion marker присутствует ровно один раз. По одной initialization и
finalization, все interpreters destroyed/OWN_GIL, errors пусты, финальные
handles/leases = 0, loaded plugins пусты; по два разных plugin owner epoch.

- Первый SDK: finalized/binding-uninstalled, owner/reload/permission и transient
  cleanup checks true; один callback вне main thread; live UI/tasks/requests = 0.
  Transport calls 161/27, errors 1/0 с намеренным unknown-member rejection.
- TL: восемь уникальных releases `[2…9]`, `flags2=5`, `close_friend=true`;
  cancel-winner, legacy-origin и root-config bindings true.
- HNS: 31 уникальный release identity (19 + 12), восемь retiring duplicate-cleanup
  checks, десять успешных уникальных cleanup calls (4 service cancel + 2 unsubscribe
  + 2 dismiss + 2 owner-task cancel), hidden-owner-at-unload `[true,true]`.

Swift engine и SDK children — **macOS CPython 3.12.10**. Три iOS simulator report —
**CPython 3.12.16**, `native_completed=true`, exit status 0, по два OWN_GIL
interpreter; embedded reports совпали с `runtime-manifest.json`.

`validate_bridge_report` прошёл на новом C report: **219 total / 169 baseline /
41 owner-bound**, previous suite 213, bulk-clear 6, старый bound subset 35.
Terminal admission **27 checks, rejected 1 / before-clear 1**, payloads
**created 2 / freed 2**. Все 33 required flags, включая reentrant/nested clear,
registry swaps, monotonic IDs, terminal owned-ref release и finalization, true.

## Фактические бинарные SHA-256

| Runtime artifact | Bytes | SHA-256 |
|---|---:|---|
| `ExteralessPythonSmoke-unsigned.ipa` | 11 569 120 | `2ce31c2ca798b0857cbad194b5c3d07a51a1d7b678647f29b36ec395e9fab1f5` |
| `Python-3.12-iOS-support.b13.tar.gz` | 32 193 359 | `4eea2c76ad70f2df8c1767489315a16d72cd96ce5c086412ee2d154c3bd8e257` |
| `ExteralessPythonBridge.xcframework.tar.gz` | 79 502 | `b49133eda8a41a45428e00764f5e48f9e0321adcd49bf2980854c46004463df5` |

- Новый IPA SHA совпал с `runtime-manifest.device_ipa_sha256`.
  `verify_probe_ipa` выполнен на Windows: **56 Mach-O, все arm64 / platform 2 /
  signing none**; 55 frameworks, включая 54 extensions. Все 1028 ZIP CRC прошли;
  provisioning/bundle signatures, duplicates, неожиданных `.so/.dylib` нет.
  Bundle `com.exteraless.python-smoke`, minimum iOS 15.0.
- IPA archive SHA отличается от run 19, но **все 1028 member payloads идентичны**:
  added/removed/changed member bytes = 0.
- Support совпал с Git lock и manifests; actual device/simulator headers —
  `3.12.16`, по 66 extension modules, все 12 required присутствуют. Полное чтение
  3537 regular files, gzip CRC/ISIZE и tar header checksums прошли.
- Bridge: полное чтение девяти regular files и проверки gzip/tar прошли;
  шесть headers/modulemaps совпали с Git, plist slices — device/simulator arm64.
  У обеих `.a` новые SHA, но их четыре object payloads + symbol-table payload
  идентичны run 19; ar timestamps отличаются. Отдельного bridge archive SHA в
  исходном manifest нет — этот digest измерен локально.

## Зависимости и оставшиеся границы

Подтверждены все 12 package metadata/archive pins против Git lock, generated
dependency marker и receipt bundle SHA
`d7fe1f9be22ef7bf3bff75b5d462ebe756039c86226c56948007bed06aef8990`.
Inventory: 479 файлов, 2 683 316 download / 8 351 187 installed bytes; суммы
согласованы. Версии и полный lock SHA записаны в JSON. **Vendor payload и package
archives отсутствуют** в этом наборе, probe IPA также не содержит vendor:
479 payload-файлов не перехэшированы, imports всех 12 пакетов на iOS не доказаны.

Границы приёмки остаются явными:

1. Физическое устройство: signing/provisioning, установка, запуск, полный SDK
   на iOS 3.12.16, lifecycle/performance не проверены.
2. Simulator выполнен через Foundation CLI `simctl spawn --standalone`,
   `application_installation_verified=false`. UIKit lifecycle/interaction,
   реальные settings/dialog views, кадры/анимации и device frame pacing не проверены.
3. Production Telegram accounts/providers, MTProto requests, sends/edits,
   server acknowledgements и применение responses/updates к account state
   не исполнялись; SDK UI/network поверхности — Foundation DTO fixtures.
4. Полная Telegram IPA/native/UI harness приёмка требует собственного gate.
   Этот verdict относится к `e16f3808`; статус in-progress `43744733589/5a4`
   не запрашивался и из runtime GREEN не выводится.
5. Внешние ZIP и vendor payload отсутствуют; HNS/SDK fixture executables в
   предоставленном наборе не сохранены. Report validation не добавляет их
   недостающие byte/device receipts.

Записи run 19 и существующие manifests сохранены без изменений; их контрольные
хэши зафиксированы в новом JSON.
