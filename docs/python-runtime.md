# Встроенный CPython: проверяемая поставка для iOS

## Исходная веха

Unsigned Telegram-iOS 13.1.1 успешно собран и проверен в
[43584868441](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43584868441),
commit `f85868c5`, artifact `exteraless-ios-13.1.1-21`.
Это пока базовый клиент: Python/PluginHost ещё не включены в его Bazel-граф.

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
  исполнение iOS-simulator бинарника через `simctl spawn`, проверка отчёта,
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
  python/virtualjava/             # следующий этап встройки клиента
  python/sdk/
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
Он не собирает Telegram. На выходе после успешного simulator probe:

- исходный проверенный support archive;
- `ExteralessPythonBridge.xcframework.tar.gz` — наш static C bridge;
- `ExteralessPythonSmoke-unsigned.ipa`;
- `runtime-manifest.json`, `simulator-smoke.json`, `simulator-engine-smoke.json`,
  `swift-engine-smoke.json` (macOS host), manifest support package.

Device probe содержит и низкоуровневую проверку runtime, и C-engine probe.
На симуляторе это два последовательных свежих процесса в одном устройстве.
Mach-O и отсутствие developer signing в диагностической IPA проверяются тем же
парсером, что и в основной Telegram IPA.

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
В отчёте явно стоит `execution: simctl spawn` и
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
Это проверяется локальной регрессией; успешный CI run с исправлением ещё
не подтверждён.

Перед Python выполняется контрольный `launchctl version` с timeout 30 секунд;
inventory, версия SDK, запрошенная модель, выбранное устройство и вывод
контрольного процесса сохраняются в диагностике.

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

## Следующее после успешного probe

`43612335857` подтвердил исправленный выбор iPhone 17 / iOS 27.0, но
`launchctl version` снова завис — проблема воспроизвелась и на обычной модели
до запуска Python. Runtime workflow переведён на `macos-26` с явным
`DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer` (SDK iOS 26.5).
При отказе сохраняются и логи CoreSimulator со стороны macOS. Telegram build
имеет собственный toolchain; runtime-компонент не требует Xcode 27.

1. Подтвердить новые native/Swift probes по CI; C-core уже проверен на Windows,
   адаптер написан, в app Bazel-граф пока не включён.
2. Привязка native callbacks, их thread/GIL ownership и освобождение handles
   на правильном интерпретаторе; probe не проверяет foreign-thread callbacks.
3. Врезка runtime, bridge, stdlib/SDK и ресурсов в успешный Bazel-граф клиента.
4. Настоящие сервисы Telegram и жизненный цикл загрузки плагина, затем UI.

Субинтерпретатор не является границей памяти/процесса. `abandon` не
останавливает зависший нативный поток и не освобождает его память. Следующая
интеграция должна сохранять ограниченные очереди и корректное завершение;
общий RSS нельзя выдавать за память отдельного плагина. Проценты импорта
через permissive-mock не являются доказательством совместимости на iPhone.
