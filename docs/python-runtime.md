# Встроенный CPython: проверяемая поставка для iOS

## Текущий handoff — 16.11.2026

Координатор: Mac43786995069 / `5fa35f34` выполняется с продолжением независимых
bounded-проверок после соседнего fixture failure. Зависимые этапы требуют своих
prerequisites; ошибочные этапы не превращаются в успешные.

Статусы CI переданы координатором при назначении и последующем уточнении.
Окно чтения handoff, ревью и уточнений: **01:26:56–01:32:15 UTC**, без опроса CI.
Следующие результаты, watcher IDs и владение файлами — [wave-2/progress.md](wave-2/progress.md).

**main `a823e619`** — fixture-only исправление isolated helper; перед ним
`d717` исправил CI/YAML после source-когорты **`f704d76c` (288 путей)**.
Все известные замечания source-ревью закрыты. В том числе:

- [ARCH-01/02/03](wave-2/reviews/elyx-archive-p1-closure.md) и последующий
  [iOS platform P2-01](wave-2/reviews/elyx-ios-platform-closure.md);
- [NFD-01/03](wave-2/reviews/native-elyx-final-source-closure.md),
  [NFD-02](wave-2/reviews/elyx-nfd02-closure.md) и последующий
  [DEV-LIFECYCLE-01](wave-2/reviews/native-elyx-mode-aba-closure.md);
- [Custom](wave-2/reviews/manager-custom-ordering-closure.md),
  [Search R1–R5](wave-2/reviews/settings-search-r1-r5-closure.md),
  [Reset RSR01/02](wave-2/reviews/settings-reset-rsr-closure.md) и
  [Trust S1–S3](wave-2/reviews/plugin-trust-secondary-closure.md).

Это **source closure** в рассмотренных сценариях. Полный native-паритет ещё
не подтверждён. SDK Config сохраняет **276 implemented / 0 blocked / 32 unsupported**,
308 API ID / 508 bindings. Карты 567 source features и 925 SDK routes полны;
само наличие карт не повышает verification/ported статусы.

### CI по последнему сообщению координатора

| Run / срез | Подтверждённый результат |
|---|---|
| Linux `43784503847 / f704d76c` | **712 Core / 273 Host / 30 Hooks PASS**, 9.176 / 5.545 / 0.356 с. Общий run FAILED на PyYAML; CI/YAML-фикс — `d717` |
| Linux `43785348360 / d717` | Swift job **PASS**; Python **472 PASS / 36 skip / 6 fail** из-за импорта `pytest` из isolated helper |
| Mac `43785374048 / d717` | Та же ошибка в раннем finite pytest; **до 5 новых native child-процессов этот run не дошёл** |
| Compat `43786135131 / a823e619` | **GREEN: 478 PASS / 36 skip**, 147.86 с |
| Mac `43786148988 / a823e619` | **91 runtime-packaging + 63 plumbing + 49 finite SDK / 13 skip PASS**; затем **FAILED: реальный Darwin listener не достиг readiness за 2 с** |
| UIKit `43785534046 / d717` | **FAILED на `aquery`, до компиляции**. Tooling owner скачивает сохранённый `build.log` |

Локальная проверка fixture-only фикса `a823e619`: **4 PASS / 10 Windows/C skips**;
emitter с `-I -S` и `noSite` — **PASS**. Swift **712/273/30** относится к прежнему
main-run `43784503847 / f704d76c`; последующие исправления сохранили production source.
**5-child native gate не пройден**. NativeDev owner уточняет точное состояние
`NWListener` отдельной bounded Darwin-only проверкой; причина readiness failure
ещё не установлена. **20 UIKit-сцен / 434 native XCTest-метода — READY, ещё не исполнены**.

Отдельные bounded Linux receipts уже сохранены в репозитории:

| Gate | Run | Результат |
|---|---|---|
| [POSIX Python / NFD-02 / platform](wave-2/elyx-load-preflight-posix-ci.md) | `43774694321` | **50 PASS / 0 skip** |
| [Host FD](wave-2/elyx-fd-cancellation-posix-ci.md) | `43784959730` | **47 PASS / 0 skip** |
| [Ingress, более ранний срез](wave-2/elyx-fd-posix-test-followup.md) | `43781210777` | **7 PASS / 0 skip**; общий run FAILED на Host timeout |
| [Mode ABA](wave-2/elyx-mode-aba-posix-ci.md) | `43783735908` | **4 PASS / 0 skip** |

Свежий C gate: **7/7 на каждой Python 3.12 и 3.14**, точный nativeSpy-счётчик
**61 calls / 60 buffer frees / 33 context releases**. Linux и этот C gate
не подтверждают Apple FD execution; оно остаётся отдельной native-проверкой.

Предыдущий полный Mac **build 20 — `43743252038 / e16f3808`** независимо проверен:
**680 Core / 180 Host / 30 Hooks + 3 SDK child + iOS C219**.
[Receipt](wave-2/runtime-native-acceptance-20.md) относится к срезу **до `f704d76c`**.

### Последняя проверенная Telegram IPA

**Unsigned Telegram 13.1.1 (40)**: run
[43779402542](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43779402542),
HEAD **`6de4ac36`**, artifact **`14187634135`**. Размер **98 177 711 байт**;
SHA-256: `e28940fdb017941525824ba1906d09e32da6bd973fa1c1c7c41bd294eeee3d99`.
Delivery: `build/artifacts/telegram-43779402542/exteraless-ios-13.1.1-40-unsigned.ipa`.

[Независимая приёмка build 40](wave-2/ipa-build40-acceptance.md) подтверждает
**67 unsigned ARM64 Mach-O / 60 frameworks (55 runtime) / 6 extensions /
1418 resource placements / 419 source pins / 12 distributions**.
Это compile/package именно `6de4ac36`; новые SDK/Host/UIKit исходники `f704d76c`
этим артефактом не покрыты. Пользователь подписывает IPA сам. Физическая установка,
APNs, live RPC и новая UIKit-приёмка ещё не выполнены; полный порт не объявлен готовым.

Runtime закреплён: **CPython 3.12.16, BeeWare `3.12-b13`**, support SHA-256
`4eea2c76ad70f2df8c1767489315a16d72cd96ce5c086412ee2d154c3bd8e257`.
**36 файлов Original/SDK сохранены без изменений.** Ниже — исторические срезы;
их run IDs, hashes, counts и границы относятся к моменту записи.

## Исторический срез полной client/SDK волны — 15.11.2026

- **[Runtime43743252038](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43743252038)
  на `e16f3808` — полностью GREEN.** Пройдены Foundation Core/Host/Hooks,
  23 HNS-сценария, Java/TL codec, настоящий Swift/CPython engine и три SDK child
  процесса с лимитом30с. iOS simulator выполнил новый **219-call gate**;
  unsigned device probe скомпилирован и опубликован.
- Артефакты run20 скачаны в `build/artifacts/python-runtime-43743252038/`.
  [Независимая сверка](wave-2/runtime-native-acceptance-20.md) — **PASS**:680/180/30 tests,
  включая9/9 atomic Ghost tests, три SDK child,219/169/41 C calls,2/2 terminal payload cleanup,
  source fingerprints и56 unsigned arm64 Mach-O диагностической IPA совпали.
- **[Linux43764252538](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43764252538)
  на `aca0eb38`: 712 Core + 180 Host + 30 Hooks PASS.** Search и reset Core fixtures
  включены. Darwin storage aliases,
  UTF-16 scalar boundaries и async-fixture исправления прошли последующий Mac gate.
- SDK Config: **276 implemented / 0 blocked / 32 unsupported**,308 API;
  59 raw source pins и canonical consumed-inventory contract. Пять portable
  адаптаций (layout/fonts/swipe/performance/Monet) подключены к native consumers.
- Native XCTest-map опубликован:36 targets/410 методов. UIKit recording protocol —
  3+3+2 fresh processes. Их выполнение и просмотр реальных кадров ожидаются после
  full-app compilation; Mac DTO/codec receipts не подтверждают Telegram network/UIKit.
- Актуальная сборка/владение файлами: [wave-2/progress.md](wave-2/progress.md).

Последняя независимо проверенная Telegram IPA — **build40 на `6de4ac36`**, run
[43779402542](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43779402542).
Размер98 177 711байт, SHA-256
`e28940fdb017941525824ba1906d09e32da6bd973fa1c1c7c41bd294eeee3d99`.
Подтверждены67unsignedARM64Mach-O,60frameworks,6extensions,1418resourceplacements,
419sourcepins. [Полный receipt](wave-2/ipa-build40-acceptance.md).
Новая Host/SDK FD-дельта и UIKit20 приёмка ещё выполняются.
Полный app graph использует **runner `xcode-27`, Xcode 27.1**;
`macos-26` / Xcode 26.6 — для Foundation/CPython component workflow.

## История интеграционной волны — 14.11.2026

**[Component 43633853229](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43633853229)
на `38d335fa` полностью прошёл за 2 мин 44 с.**

- Настоящий Swift → CPython → SDK → C → Swift plugin probe выполнился на macOS
  за **2,358 с**: AST, load/unload/reload, settings Unicode/NUL, callbacks,
  app event, MODIFY/CANCEL, permissions, persistence и finalize.
- Плагин импортировал настоящие bundled requests/cachetools; C-мок не установлен.
  В этом probe Telegram/UIKit providers заменены явными Foundation fixtures.
- iOS simulator: CPython **3.12.16**, SSL/SQLite/компрессия, два OWN_GIL workers,
  **169 native C callbacks**, rollback/reentry/изоляция и завершение прошли.
- [Compat 43633810023](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43633810023):
  **246 pytest / 20 skipped, 79 PluginHost + 16 PluginHooks Swift tests**.
- Артефакты `Python-3.12-device-probe-12` и `Python-3.12-ios-runtime-12` опубликованы.
  Локально сверены SHA-256 диагностической IPA, **56 unsigned iOS ARM64 Mach-O**
  и **22 git source fingerprints**. Копии: `build/artifacts/python-runtime-43633853229/`.

Предыдущий run `43629521505` выявил SDK audit bug: frozen `os` без `__file__`
приводил к кешированию пустых runtime paths. `_audit_paths.py` исправляет это до
исполнения плагина; regression включает настоящие библиотеки и проверки доступа.
Подробности: [`AUDIT_PATHS.md`](../python/exteraless_runtime/AUDIT_PATHS.md).

В дереве этого среза runtime подключён к Bazel-графу Telegram: `PluginHost`,
отдельный `PluginHooks`, static C-мост, dynamic Python.framework и 54 native
extension frameworks. Main-app lifecycle соединён с нативными Telegram services,
SDK loader и менеджером плагинов. **Полная unsigned Telegram IPA проверена:**
[43635233046](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43635233046),
commit `68bb1adf`, artifact `exteraless-ios-13.1.1-23` (14131805640).
Скачанная IPA независимо перепроверена валидаторами именно этого git commit:
**67 iOS ARM64 Mach-O, 55 runtime frameworks, 1071 ресурс, шесть extensions**;
rpath chains и sealed dependencies совпали. Размер **88 440 189 байт**, SHA-256:
`e0be1839d30c4182f5f3105a43e8f02902d53afff60f29b677601d8f01e6d6fa`.
Файл: `build/artifacts/telegram-43635233046/Telegram.ipa`, рядом
`local-verification.json`, manifests, entitlement templates и DSYM.

Первая полная попытка
[43634378027](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43634378027)
подтвердила Bazel/unsigned preflight всех 55 frameworks, затем выявила два optional
`MTRpcError` в Network hook insertion. Типы исправлены перед повтором с action cache.
UIKit lifecycle, визуальная приёмка и физическая установка ещё требуют проверки.

Следующая полная client/SDK волна и независимое ревью описаны в
[wave-2-contract.md](wave-2-contract.md). Её незакоммиченный код не входит в build 23.

- `python/exteraless_runtime/` исполняет настоящий SDK loader: AST metadata,
  load/unload, event dispatch, JSON settings, callbacks на owner worker.
- `NativeBridgeBinding` маршрутизирует C-вызовы в Swift `BridgeServices`;
  pluginId берётся из per-interpreter state. Windows/CPython 3.12.10 probe
  прошёл **169 C-callbacks / два OWN_GIL workers** с debug allocator.
- Pending callbacks ограничены 256 на плагин / 1024 глобально, а неуспешный
  native call откатывает вновь экспортированные C handles. Контракт:
  [bridge-callback-lifetime.md](bridge-callback-lifetime.md).
- Восемь SHA-256-pinned pure-Python wheels поставляются в `python/vendor`;
  версии и зависимости — `python/runtime/dependency-lock.json`. Сборщик
  проверяет архивы без исполнения их кода, SDK проверяет bundled requirements.
- `tools/runtime/check_swift_plugin_embedding.py` проверяет сквозной путь
  Swift → CPython → SDK → C → Swift на собственном коротком fixture-плагине.
  Telegram/UIKit services в этом headless probe представлены явными fixtures.
- Карта event hooks: [wave-1-hooks.md](wave-1-hooks.md). Send поддерживает
  CANCEL и изменение plain-text/flags; RPC/update hooks передают observations.
- Экран менеджера и настроек: `TelegramUI/Sources/Exteraless/`; критерии
  визуальной приёмки — [wave-1-visual.md](wave-1-visual.md), запись ещё требуется.

Перед локальным Make.py нужно подготовить декларированные Bazel inputs:

```sh
python3 tools/runtime/prepare_telegram_runtime.py --telegram-root telegram-ios
```

CI делает это автоматически. Source/inventory guard отклоняет устаревший staging.

## Предыдущая runtime-веха — 14.11.2026

**[Run 43615992774](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43615992774)
на `013fc301` полностью прошёл за 2 мин 15 с.**

- iOS-simulator: настоящий **CPython 3.12.16**, загрузка `.fwork` extensions,
  SSL/SQLite/compression и built-in C-мост; два OWN_GIL интерпретатора.
- Native engine на iOS: два worker-потока, изоляция, исключения/SystemExit,
  Unicode/NUL, отказ чужому потоку, защита finalize/destroy и нормальное завершение.
- Swift adapter с host CPython **3.12.10** на macOS также прошёл реальные проверки.
- Артефакты `Python-3.12-device-probe-10` и `Python-3.12-ios-runtime-10` опубликованы.
  Скачанный IPA проверен повторно: SHA-256 совпал с manifest, все **56 device Mach-O**
  имеют iOS ARM64 и допустимый unsigned/ad-hoc статус. Source fingerprint совпал
  с git blobs проверенного коммита.

Симуляторные отчёты указывают `execution: simctl spawn --standalone` и
`application_installation_verified: false`; физическая установка проверяется
пользователем после подписи. Локальная копия диагностической IPA и отчётов:
`build/artifacts/python-runtime-43615992774/`.

У upstream framework `Info.plist` сохранилась строка 3.12.10, но заголовки,
support manifest и исполняемый runtime согласованно сообщают **3.12.16**.
Проверка версии движка опирается на заголовки и `Py_GetVersion`, не на plist.

## Исходная веха

Unsigned Telegram-iOS 13.1.1 успешно собран и проверен в
[43584868441](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43584868441),
commit `f85868c5`, artifact `exteraless-ios-13.1.1-21`.
Этот опубликованный артефакт — базовый клиент без Python/PluginHost.

## Выбор runtime

`python/runtime/support-lock.json` закрепляет официальный support package
BeeWare `3.12-b13` по SHA-256. Он содержит device ARM64 и simulator
ARM64/x86_64 slices Python.xcframework, stdlib и native extensions.

PEP 684 входит в CPython 3.12. Отдельного configure-флага
`--with-experimental-isolated-subinterpreters` для этого не требуется.
Собственный GIL выбирается при `Py_NewInterpreterFromConfig`.
Поэтому runtime берём готовый, а свой C-мост компилируем отдельно — это
быстрее пересборки того же CPython на каждом этапе.

Проверка native extensions включает `_ssl`, `_hashlib`, `_sqlite3`, `_socket`,
`_asyncio`, `_ctypes`, `_lzma`, `_bz2`, `zlib`, `math`, `select`.
Наличие модулей подтверждается структурой архива; их загрузка и часть
операций проверяются отдельным нативным embedding probe.

## Файлы

- `tools/runtime/support.py`: поблочная загрузка, SHA-256, проверка slices,
  установка stdlib и PEP 730 `.fwork` / `.origin` связей в app bundle.
- `tools/runtime/validate_runtime.py`: сборка device + simulator probe
  средствами Xcode; отдельный clone предсозданного симулятора и прямое
  исполнение iOS-simulator бинарника через `simctl spawn --standalone`, проверка отчёта,
  очистка clone. UIKit/установка через SpringBoard не входят в этот probe.
- `python/runtime/register_bridge.c`, `include/EXLPythonBridge.h`: регистрация
  `_exteraless_bridge` как built-in через `PyImport_AppendInittab`, до старта Python.
- `python/runtime/engine.c`, `include/EXLPythonEngine.h`: нативный жизненный цикл
  процесса/интерпретаторов, временный main tstate на воркере, переключение GIL,
  непрозрачные ID, выполнение исходника и возврат UTF-8/ошибок через собственный C ABI.
- `python/runtime/cpython312_compat.c`: узкий слой для особенностей CPython 3.12;
  использует internal headers той же сборки. Версии заголовков и библиотеки
  проверяются до инициализации. Эти детали не экспортируются в Swift.
- `swift/PluginHost/Sources/PluginHost/CPythonXCFrameworkEngine.swift`: адаптер
  протокола `CPythonEngine`; initialize/finalize на одном выделенном `Thread`,
  create/run/destroy на потоках `SubinterpreterManager`.
- `python/runtime/smoke/runtime_probe.c`: реальный C API-тест initialization,
  SSL/hash/SQLite/compression, import встроенного моста, два одновременно живых
  OWN_GIL интерпретатора, раздельные handles, завершение интерпретаторов/process.
- `python/runtime/smoke/main.m`: отдельное диагностическое iOS-приложение.
- `tools/runtime/check_host_embedding.py`: MSVC-сборка того же C-probe на
  Windows с Python 3.12; один короткоживущий процесс, timeout 30 секунд.
- `python/runtime/smoke/engine_probe.c`: два настоящих worker-потока, параллельный
  bootstrap, отдельные handles/globals, восстановление после исключений/SystemExit,
  Unicode/NUL, отказ чужому потоку и преждевременной финализации.
- `tools/runtime/check_swift_embedding.py` + `smoke/swift_engine_probe.swift`:
  сборка адаптера с настоящим host CPython на macOS, затем проверка через Swift
  `PythonRuntime` / `SubinterpreterManager`. Обычные SwiftPM-тесты не линкуют Python;
  этот отдельный probe проверяет и код внутри `canImport(CExteralessPythonBridge)`.
- `tools/runtime/tests/`: небольшие проверки упаковки, без исполнения плагинов.

В C-мосте исправлены два препятствия для 3.12 OWN_GIL: слот
`Py_mod_multiple_interpreters` объявляется уже на 3.12 (только `Py_mod_gil`
требует 3.13), общий реестр C-указателей использует заранее инициализированный
OS mutex на 3.12, а не гоняющийся lazy PyThread lock.

## Layout

```text
App.app/
  Frameworks/Python.framework/Python
  Frameworks/_ssl.framework/_ssl
  Frameworks/_ssl.framework/_ssl.origin
  ... остальные native extensions ...
  python-stdlib/lib/python3.12/
    encodings/ ...
    lib-dynload/_ssl.cpython-312-iphoneos.fwork
  python/virtualjava/
  python/sdk/
  python/exteraless_runtime/
  python/vendor/                 # pure-Python wheels и их .dist-info
  python/compat-manifest.json
```

`.fwork` указывает на `Frameworks/<module>.framework/<module>`, `.origin` —
обратно на marker. На симуляторе frameworks подписываются ad-hoc, без
сертификатов Apple. Device probe упаковывается unsigned для самостоятельной
подписи пользователем. Это отдельный диагностический app ID, не Telegram.

В app bundle исключаются CPython `test/` (27 МБ, около 1600 файлов), native
test/demo extensions и build-only Headers/Modules фреймворка. `unittest` и
рабочие stdlib extensions сохраняются. Исходный support archive не меняется.
Упаковка проверена на самом закреплённом архиве: 54 extension frameworks,
1020 файлов ресурсов, около 33 МиБ для device (до добавления smoke executable).
Все 67 исходных device Mach-O проверены: iOS ARM64, без подписи.

Swift `PythonRuntimeConfiguration` теперь использует `python-stdlib` как
home, родительский `python/` как import root и реальный C API bootstrap:
`xt_bind(...)` + `BridgeBackend(service=..., manifest_path=...)`.
Неизвестный host service отказывает; mock автоматически не устанавливается.

## Контракт нативного движка

Процесс CPython принадлежит одному движку. Повторная инициализация, в том числе
после finalize, запрещена. Пока существуют живые/создаваемые интерпретаторы,
финализация отказывает. ID интерпретатора не является указателем; чужой поток,
удалённый ID и повторный вход проверяются до обращения к Python.

`runScript` компилирует expression либо statement suite, затем исполняет код
**один раз**. Для expression строка возвращается без дополнительного repr,
прочие значения — через repr; statement suite возвращает `None`. Ошибка
выполнения `SyntaxError` не является поводом выполнить код заново. `SystemExit`
возвращается как ошибка Swift. Результаты копируются по длине, сохраняя NUL.

`_datetime` в закреплённом CPython 3.12 остаётся legacy C-модулем с общими
статическими типами. Параллельный cold-import через sqlite3 в двух Windows
OWN_GIL воркерах воспроизвёл `0xC0000374`; ранний import `_datetime` под main GIL
устранил этот сбой в трёх отдельных контрольных процессах. Проверки совместимости
C-расширений в суб-интерпретаторах остаются включёнными.

Ранний error path `Py_NewInterpreterFromConfig` в 3.12 может вернуть main tstate
без main GIL. Compatibility helper проверяет `locked` и `last_holder` вместе
под mutex самого GIL и восстанавливает владение перед cleanup. Оба состояния
GIL проверены fault injection в отдельном короткоживущем C-процессе с allocator
diagnostics; тестовые точки инъекции не входят в production XCFramework.

Удаление интерпретатора с дополнительными Python tstate отказывает вместо
`Py_FatalError("not the last thread")`. При нормальном удалении предварительно
закрывается создание новых потоков из finalizer/atexit. Нативный probe проверяет
живой `_thread`, отказ destroy, кооперативное завершение через sentinel и успешный
повторный destroy — без предположений о задержке потока.

В `SubinterpreterManager` неуспешный bootstrap освобождает интерпретатор на его
воркере. Если native cleanup отказывает, слот остаётся abandoned и учитывается
в лимите. Создания резервируют место до первого await; выполняющееся destroy
не исчезает из учёта до подтверждённого результата. `canFinalizeProcess`
требует пустого пула и отсутствия незавершённых созданий.
Остановка терминальна: закрывает приём до первого await. Поздно завершившееся
создание очищается на своём worker; `HostState` под lock не публикует late
handles/loaded/subscriber gate. При ещё выполняющемся bootstrap остановка
не ожидает его бесконечно и пропускает финализацию процесса.

## Запуск и доказательства

Workflow `.github/workflows/python-framework.yml` — только вручную.
После `--phase build` сразу публикуется `Python-3.12-device-probe-<number>`:
проверенная unsigned диагностическая IPA, static bridge XCFramework,
`runtime-compile-manifest.json` и результат host Swift-probe. В compile manifest
исполнение на симуляторе и установка на устройстве явно помечены непроверенными.

Затем `--phase probe` проверяет fingerprint исходников и запускает simulator
процессы. Только после их успеха публикуется полный validated runtime:

- исходный проверенный support archive;
- `ExteralessPythonBridge.xcframework.tar.gz` — наш static C bridge;
- `ExteralessPythonSmoke-unsigned.ipa`;
- `runtime-manifest.json`, `simulator-smoke.json`, `simulator-engine-smoke.json`,
  `swift-engine-smoke.json` (macOS host), manifest support package.

Device probe содержит и низкоуровневую проверку runtime, и C-engine probe.
На симуляторе это два последовательных свежих процесса в одном устройстве.
Mach-O и отсутствие developer signing в диагностической IPA проверяются тем же
парсером, что и в основной Telegram IPA.

Диагностическая IPA устанавливается после самостоятельной подписи пользователя.
Приложение **Python Runtime Check** запускает C-engine probe и показывает результат.
Его `Documents/runtime-smoke.json` доступен через Files/File Sharing; он содержит
результаты native workers и завершения. Это диагностическое приложение, не Telegram.

Локально уже выполнен native probe на CPython **3.12.10 / Windows**:
`ok: true`, два OWN_GIL интерпретатора, built-in bridge, SSL и SQLite.
Новый C-engine probe также прошёл на Windows: два собственных native потока,
изоляция данных, исключения и нормальное завершение. Swift-адаптер **скомпилирован
и выполнен с настоящим CPython 3.12.10 на macOS** в
[43612335857](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43612335857):
`swift-engine-smoke.json` подтверждает `ok`, два native workers, изоляцию,
Unicode/NUL, восстановление после исключений, cleanup bootstrap и finalize.
Это не результат на iOS. Проверка iOS считается выполненной только по
успеху workflow и его `simulator-smoke.json`; device installation — отдельно.
В отчёте явно стоит `execution: simctl spawn --standalone` и
`application_installation_verified: false`. Это реальный iOS-simulator
процесс с тем же бандлом и C-probe, но не проверка sandbox/жизненного цикла
установленного приложения. Установка в `43601656327` зависла в `simctl install`
до запуска Python; эту проверку не подменяем успешным compile.

Run `43604638215` выявил ошибку выбора симулятора: строковая сортировка
взяла hardware-specific `iOS-27-2-iPhone19-4` при активном SDK 27.1.
Запуск процесса, сбор логов и остановка этого симулятора зависали; отметка
входа в `main` не появилась. Одной фильтрации hardware suffix оказалось
недостаточно: inventory из run `43605905475` содержит только iPhone Duo
даже под generic ID `iOS-27-1`. Поэтому прежний селектор снова выбрал Duo.
Контрольный `simctl spawn ... launchctl version` достиг timeout 30 секунд
с пустым выводом. Это произошло **до запуска Python**, а не по его timeout
90 секунд; `log show`, `shutdown` и `delete` также зависали до timeout.

Теперь модель задаётся точным именем через `--simulator-device` (по умолчанию
`iPhone 17`); workflow передаёт `--simulator-device 'iPhone 17'` явно.
Среди available устройств в состоянии `Shutdown` выбирается именно эта
модель на generic iOS runtime с численно максимальной версией не выше SDK.
Runtime ID с hardware suffix исключаются. При отсутствии нужной модели
выбор завершается ошибкой с её именем, SDK и списком runtimes, без подмены
другим устройством. На сохранённом inventory при SDK 27.1 это даёт
`iOS-27-0` / `iPhone 17`: generic 27.1 содержит только Duo, а 27.2 новее SDK.
Это проверяется локальной регрессией. Полный runtime CI прошёл после перехода
к standalone-процессам, см. подтверждённую веху выше.

Run `43613723001` на macOS 26 / Xcode 26.6 снова завис в системном `launchctl`
до Python. Host-лог содержит разрывы XPC после отмены клиентов, но не устанавливает
причину зависания. Поэтому CLI-проверка теперь использует standalone-режим,
как [нативный runner LLVM](https://github.com/llvm/llvm-project/blob/main/compiler-rt/test/sanitizer_common/ios_commands/iossim_run.py).
Simulator-бинарник линкует Foundation без UIKit; запуск SpringBoard не требуется.
При timeout сохраняется sample только своего launcher-процесса и завершается
его собственная process group. Повторные попытки автоматически не запускаются.

```powershell
$env:PYTHONUTF8 = '1'
python -m unittest discover -s tools/runtime/tests -v
python tools/runtime/check_host_embedding.py `
  --python C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe `
  --output C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-runtime-host-probe
python tools/runtime/check_host_embedding.py --probe engine `
  --python C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe `
  --output C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-native-engine-probe
python tools/runtime/check_host_embedding.py --probe engine --fault-injection --debug-memory `
  --python C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe `
  --output C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-engine-fault-probe
```

## История плана после probe `43612335857`

`43612335857` подтвердил исправленный выбор iPhone 17 / iOS 27.0, но
`launchctl version` снова завис — проблема воспроизвелась и на обычной модели
до запуска Python. Runtime workflow переведён на `macos-26` с явным
`DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer` (SDK iOS 26.5).
При отказе сохраняются и логи CoreSimulator со стороны macOS. Telegram build
имеет собственный toolchain; runtime-компонент не требует Xcode 27.

1. Привязка native callbacks, их thread/GIL ownership и освобождение handles
   на правильном интерпретаторе; probe не проверяет foreign-thread callbacks.
2. Врезка runtime, bridge, stdlib/SDK и ресурсов в успешный Bazel-граф клиента.
3. Настоящие сервисы Telegram и жизненный цикл загрузки плагина, затем UI.

Субинтерпретатор не является границей памяти/процесса. `abandon` не
останавливает зависший нативный поток и не освобождает его память. Следующая
интеграция должна сохранять ограниченные очереди и корректное завершение;
общий RSS нельзя выдавать за память отдельного плагина. Проценты импорта
через permissive-mock не являются доказательством совместимости на iPhone.
