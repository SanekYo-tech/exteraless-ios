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
  средствами Xcode; запуск свежего отдельного симулятора, проверка отчёта,
  очистка созданного симулятора.
- `python/runtime/register_bridge.c`, `include/EXLPythonBridge.h`: регистрация
  `_exteraless_bridge` как built-in через `PyImport_AppendInittab`, до старта Python.
- `python/runtime/smoke/runtime_probe.c`: реальный C API-тест initialization,
  SSL/hash/SQLite/compression, import встроенного моста, два одновременно живых
  OWN_GIL интерпретатора, раздельные handles, завершение интерпретаторов/process.
- `python/runtime/smoke/main.m`: отдельное диагностическое iOS-приложение.
- `tools/runtime/check_host_embedding.py`: MSVC-сборка того же C-probe на
  Windows с Python 3.12; один короткоживущий процесс, timeout 30 секунд.
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

Swift `PythonRuntimeConfiguration` теперь использует `python-stdlib` как
home, родительский `python/` как import root и реальный C API bootstrap:
`xt_bind(...)` + `BridgeBackend(service=..., manifest_path=...)`.
Неизвестный host service отказывает; mock автоматически не устанавливается.

## Запуск и доказательства

Workflow `.github/workflows/python-framework.yml` — только вручную.
Он не собирает Telegram. На выходе после успешного simulator probe:

- исходный проверенный support archive;
- `ExteralessPythonBridge.xcframework.tar.gz` — наш static C bridge;
- `ExteralessPythonSmoke-unsigned.ipa`;
- `runtime-manifest.json`, `simulator-smoke.json`, manifest support package.

Локально уже выполнен native probe на CPython **3.12.10 / Windows**:
`ok: true`, два OWN_GIL интерпретатора, built-in bridge, SSL и SQLite.
Это не результат на iOS. Проверка iOS считается выполненной только по
успеху workflow и его `simulator-smoke.json`; device installation — отдельно.

```powershell
$env:PYTHONUTF8 = '1'
python -m unittest discover -s tools/runtime/tests -v
python tools/runtime/check_host_embedding.py `
  --python C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe `
  --output C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-runtime-host-probe
```

## Следующее после успешного probe

1. Реальный `CPythonEngine` для Swift (сейчас остаётся Unbound/protocol).
2. Привязка native callbacks, их thread/GIL ownership и освобождение handles
   на правильном интерпретаторе; probe не проверяет foreign-thread callbacks.
3. Врезка runtime, bridge, stdlib/SDK и ресурсов в успешный Bazel-граф клиента.
4. Настоящие сервисы Telegram и жизненный цикл загрузки плагина, затем UI.

Субинтерпретатор не является границей памяти/процесса. `abandon` не
останавливает зависший нативный поток и не освобождает его память. Следующая
интеграция должна сохранять ограниченные очереди и корректное завершение;
общий RSS нельзя выдавать за память отдельного плагина. Проценты импорта
через permissive-mock не являются доказательством совместимости на iPhone.
