# Runtime native acceptance — 43738810843

**Независимый verdict: PASS в границах runtime/component gate** для коммита
`136c946f87194221342a83b2b06743fe4cc3fc7c`, Python Framework run 19.
Проверка сохранённых артефактов выполнена на Windows 2026-11-15. Несовпадений
проверенных исходных хэшей, отчётов и бинарных контрактов не обнаружено.

Машинное заключение:
[`local-verification.json`](../../build/artifacts/python-runtime-43738810843/local-verification.json).
Исходные артефакты находятся в `build/artifacts/python-runtime-43738810843/`.

## Происхождение и метод

| Каталог | GitHub artifact ID | Предоставленный SHA-256 внешнего GitHub ZIP |
|---|---:|---|
| `runtime` | 14171797583 | `b205e76cbb275b6cc7634be31c9049eb6599c4ef2b33aec8fad19a70b13517df` |
| `device` | 14171364891 | `94312e7601ba80305a1e5b2a3afe9d0622be8f600b02d9c4e577524ae31ef12b` |
| `swift-components` | 14172076190 | `c6fdbdc99d7d3933d8832795e27bb32af71d20509738b35b8934501d5885364b` |

В предоставленном каталоге внешних GitHub ZIP нет: эти три digest записаны как
полученные метаданные, локально заново не вычислены. Хэши распакованных каталогов
с ними не сравнивались. Локальная inventory охватывает 65 исходных файлов,
57 755 395 bytes; её алгоритм и digest приведены в JSON.

Все исходные SHA-256 проверялись по **сырым Git blob bytes указанного коммита**:
`git cat-file --batch`, binary stdin/stdout, разбор точного размера каждого blob.
Текущий рабочий каталог не использовался как эталон исходников. Исходники и
существующие manifests/artifacts читались без изменений. Локально исполнялись
только проверки данных/архивов; плагины, native probes, CI, сеть и устройства не
запускались. Каждая shell-команда ограничена 120 секундами.

## Привязка исходников

| Evidence | Проверенные входы |
|---|---:|
| `runtime-manifest.json` и `runtime-compile-manifest.json` | по 559/559 Git hashes; полный набор путей совпал |
| Оба `build-inputs.json` | по 313: 311 Git blobs + 2 проверенных generated inputs |
| Их `root_source_sha256` / Java cohort | по 1/1 и 9/9 |
| Core / Host / Hooks `source_sha256` | 272/272, 64/64, 15/15; полные наборы путей совпали |
| Java TL `source_sha256` | 34/34 |
| HNS fixture `input_sha256` | 234/234; полный набор путей совпал |
| `input-preflight.json` | 975/975 хэшей и размеров: 973 Git blobs + 2 pinned gitlink blobs |

Всего в заявленных входах 1002 уникальных blob основного репозитория, два blob
из `rules_apple@485016eb5b0948cc17307064e7977a6d68e94046` и два generated input.
Gitlink подтверждён самим `136c946f`; его файлы прочитаны из закреплённого commit.

Generated inputs проверены отдельно:

- `SDKConfigRootRegistration.swift`: 1537 bytes,
  SHA `35f7b3e80e43460508314bc2e610b59e9ee2d721da2d22236bba1f740eba50f9`.
  Точная строка восстановлена в памяти по recipe runner и 21 группе реального
  root expression на строке 55 Git-версии `ExteralessClientRuntime.swift`.
- `python/vendor/exteraless-dependencies.json`: 88 488 bytes,
  SHA `80c47a163d0237778edbe0ea636678ed3b3dc9e3b6703766ce8f2cf0fb73fec6`.
  Проверена точная сериализация marker из dependency report с Git-pinned lock.

Также совпали оба scalar `source_fingerprint`, Core/Host component fingerprints,
13 файлов и три scoped region UI postimage, 12 сохранённых Swift-копий fixture
и SHA сгенерированного `Package.swift`. Пять пар отчётов между `runtime` и
`device` идентичны по bytes. Compile/runtime manifests различаются только
добавленными simulator reports и `simulator_execution_verified`.

## Фактические результаты

Counts подтверждены отдельными XCTest `started`/`passed` строками и итогом
`All tests`, а не количеством файлов или одним `ok`. Во всех трёх пакетах
нулевые failures/unexpected failures, запуск unfiltered через `--skip-build`.

| Проверка | Результат | Build, s | Test launcher, s | XCTest test / wall, s |
|---|---|---:|---:|---:|
| ExteralessCore | 671 passed | 107.639 | 13.599 | 11.587 / 11.787 |
| PluginHost | 180 passed | 66.178 | 13.500 | 6.327 / 6.380 |
| PluginHooks | 30 passed | 38.026 | 2.093 | 0.657 / 0.669 |
| HNS Foundation fixture | 23 scenarios passed | 64.501 | 1.878 | — |
| Java → Foundation TL | 1 pytest, 7 codec cases | 4.150 | 0.626 | pytest suite 0.328 |

CI budgets: Swift build 240 s / tests 30 s; HNS fixture compile 480 s / run 30 s;
Java compile 240 s / pytest 30 s / codec 20 s. HNS completion marker присутствует;
это Foundation helpers + настоящий Host worker с `fixture_engine=true`,
`cpython_executed=false`, `uikit_executed=false`.

Java XML подтверждает ровно один именованный тест без skips/errors/failures.
Его закреплённый test input содержит `empty`, `signed`, `plain_control`, `nested`
и три rejection cases: `int_vector`, `long_vector`, `invalid_base64`.
SHA сохранённого executable совпал с report:
`894e9699b81727c0fcfe79a214a1b0e64c839b4211184d97483a4dee642dac7e`.
Отдельный native C transport в этом Java control обозначен `not-run`.

### Три SDK child process

Pure `validate_report`, `validate_tl_report`, `validate_hns_report` из Git-версии
`tools/runtime/check_swift_plugin_embedding.py` повторно проверили отчёты.
У каждого child есть свой completion marker, одна initialization/finalization,
два разных plugin owner epoch; все интерпретаторы destroyed/OWN_GIL,
dispatch errors пусты, финальные handles/leases равны нулю, loaded plugins пусты.

| Child | Время / budget, s | True contract flags | Интерпретаторы: metadata + plugin |
|---|---:|---:|---:|
| Первый SDK | 6.734 / 30 | 31/31 | 1 + 2 |
| TL | 4.570 / 30 | 20/20 | 2 + 2 |
| HNS | 1.611 / 30 | 18/18 | 1 + 2 |

- Первый SDK: `binding_uninstalled`, `finalized`, `transient_handles_released`,
  `terminal_ui_lease`, `ui_live_models`, reload/owner/permission gates — true.
  Один C→Swift callback наблюдался вне main thread; live UI/tasks/requests = 0.
  Transport calls: 161/27; errors: 1/0, первый включает намеренный unknown-member
  rejection. `uikit_executed=false`, `telegram_services_executed=false`.
- TL: cleanup true, восемь уникальных releases `[2…9]`, normalized `flags2=5`,
  `close_friend=true`; cancel-winner, legacy origin, native text routes и root
  config binding — true. Провайдеры остаются Foundation DTO recorders.
- HNS: permission/account revocation, FIFO/terminal delivery, retiring admission
  guard, stored-token/exact/idempotent cleanup — true. 31 уникальный release
  identity (19 + 12), восемь retiring duplicate-cleanup checks, десять успешных
  уникальных cleanup calls: 4 cancel service + 2 unsubscribe + 2 dismiss + 2 cancel
  owner task. `hidden_owner_at_unload=[true,true]`.

SDK children и `swift-engine-smoke.json` использовали **macOS CPython 3.12.10**.
Swift engine отдельно подтверждает два worker/OWN_GIL interpreter, cleanup после
bootstrap failure, isolation, exception recovery, UTF-8/NUL и finalization.

## iOS runtime и бинарные артефакты

Три simulator report согласованы с `runtime-manifest.json`: `platform=ios`,
**CPython 3.12.16**, `native_completed=true`, exit status 0 и по два OWN_GIL
interpreter. Execution — `simctl spawn --standalone`; у всех
`application_installation_verified=false`.

`tools/runtime/validate_runtime.py.validate_bridge_report` из закреплённого
Git blob выполнен локально и прошёл: 33/33 required checks; **219 total,
169 baseline, 41 owner-bound**, previous suite 213, bulk-clear 6. Старый owner
subset равен 35; актуальный bound count — 41. Terminal admission: 27 checks,
rejected **1**, before-clear **1**, payloads created/freed **2/2**.
`bulk_clear_reentrant_registration`, `bulk_clear_nested_once`,
`bulk_clear_realm_registry_swaps`, `bulk_clear_monotonic_ids`,
`terminal_owned_refs_released`, `finalized` — true.

- **Support tar.gz:** 32 193 359 bytes, SHA
  `4eea2c76ad70f2df8c1767489315a16d72cd96ce5c086412ee2d154c3bd8e257` совпал
  с Git lock и manifests. Release `3.12-b13`; реальные device/simulator headers
  содержат `3.12.16`, по 66 extension modules, все 12 required присутствуют.
  Прочитаны 3537 regular files; gzip CRC/ISIZE и tar header checksums прошли.
- **Device probe IPA:** обе копии по 11 569 120 bytes, SHA
  `4e7e0d82e72bef3b0c6823225405c06f874f8e33524894e10f3238c1cb1ec4ee` совпал
  с обоими `device_ipa_sha256`. Portable `verify_probe_ipa` выполнен на Windows:
  56 Mach-O, все arm64/platform 2/signing `none`; 55 frameworks, включая 54
  extension frameworks. Проверен CRC всех 1028 ZIP entries; duplicate entries,
  provisioning profiles и bundle signatures отсутствуют. Это
  `com.exteraless.python-smoke`, minimum iOS 15.0.
- **Bridge XCFramework tar.gz:** обе копии по 79 503 bytes, SHA
  `2371c616def7913a3bd2a2e7f4851f3bd4eee4c72e3a87d00cc8e287e5497a54`.
  В исходных manifests отдельного SHA этого архива нет: digest измерен локально.
  Прочитаны все девять regular files; gzip CRC/ISIZE и tar header checksums прошли.
  Plist описывает `ios-arm64` / `ios-arm64-simulator`; шесть header/modulemap
  копий идентичны Git, обе static libraries имеют корректный archive magic.

Pure validators загружались из Git без вызова build/probe entrypoints.
Их полные SHA и дополнительные member inventories сохранены в JSON.

## 12 зависимостей

Package metadata/archive pins совпали с Git `dependency-lock.json`:
`packaging 26.3`, `requests 2.34.2`, `urllib3 2.8.0`, `idna 3.20`,
`certifi 2026.10.23`, `charset-normalizer 3.5.2`, `cachetools 8.0.0`,
`typing-extensions 4.16.0`, `beautifulsoup4 4.15.0`, `soupsieve 4.1.1`,
`pyyaml 6.0.3`, `debugpy 1.8.22`.

Lock SHA `222da84eea828044f5af0e8d034945662fd74aae6414bc91f67d6311f14ef924`;
пересчитанный receipt bundle SHA
`d7fe1f9be22ef7bf3bff75b5d462ebe756039c86226c56948007bed06aef8990`
совпал с обоими build-inputs. Проверены суммы: 479 file entries,
2 683 316 download bytes, 8 351 187 installed bytes.

**Граница этой проверки:** package archives/vendor payload в предоставленных
артефактах отсутствуют; probe IPA также не содержит vendor. Проверены pins и
согласованность receipt, но 479 payload-файлов локально не перехэшированы.
Это не receipt упаковки или iOS-import всех 12 пакетов в production Telegram.

## Оставшиеся границы приёмки

1. **Физическое устройство:** подписание/provisioning, установка, запуск,
   полный SDK pipeline на iOS CPython 3.12.16, lifecycle и performance остаются
   непроверенными. Device IPA здесь подтверждает unsigned compile/packaging.
2. **Приложение и UI:** standalone simulator CLI не проверяет установку,
   SpringBoard/UIKit lifecycle. Foundation fixtures не проверяют реальные
   settings/dialog views, навигацию, touch input, кадры/анимации и device frame
   pacing; для визуального verdict нужны отдельные frame-based evidence.
3. **Production Telegram network/state:** реальные accounts/service providers,
   MTProto requests, sends/edits, server acknowledgements и применение
   responses/updates к account state не исполнялись. DTO, cancellation и origin
   contracts проверены в локальных fixture boundaries.
4. **Полная сборка клиента/native/UI harness:** отдельная coordinator-owned
   приёмка по собственным build/run receipts. Этот verdict привязан к
   `136c946f`; pending native/harness изменения им не покрыты.
5. **Сохранность evidence:** внешние GitHub ZIP digest записаны со слов
   предоставившей сессии; vendor payload и HNS/SDK fixture executables в наборе
   отсутствуют. Проверка reports не добавляет недостающих byte/device receipts.
