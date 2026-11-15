# exteraless-ios

Порт **exteraless** (Telegram-клиент для Android с системой Python-плагинов,
форк exteraGram/NagramX, версия 13.1.1-beta15) на **iOS**.

База — нативный **Telegram-iOS 13.1.1** (тот же релиз, что и Android-основа
exteraless), поверх — Python-рантайм и портированная система плагинов.

## Структура

| путь | что это |
|---|---|
| `telegram-ios/` | форк Telegram-iOS 13.1.1 (сборка — Bazel, см. `build-system/`) |
| `tools/compat/` | генератор манифеста совместимости плагинов (этап 0) |
| `third_party/exteraless-android/` | исходники exteraless (java/kotlin/python) — эталон для сканера |
| `third_party/corpus-sources/` | клоны репозиториев плагинов (в git не входят, см. ниже) |
| `third_party/corpus/` | собранный корпус плагинов (генерируется) |
| `build/compat/` | манифест и отчёты совместимости (генерируется) |
| `python/runtime/` | pinned CPython, C engine/ABI и native probes |
| `python/exteraless_runtime/` | адаптер настоящего SDK loader для iOS |
| `swift/PluginHost/` | lifecycle, bridge services, permissions и callbacks |
| `swift/PluginHooks/` | лёгкие send/request/update точки расширения TelegramCore |
| `swift/ExteralessCore/` | типизированные настройки и независимые от UIKit client policies |
| `docs/parity/` | сверка Java/Kotlin функций и SDK с конкретными iOS consumers |

## Манифест совместимости (этап 0)

Манифест — «единственный источник правды» о том, какие Java-классы, методы и
хуки реально используют плагины. Генерируется из корпуса плагинов и исходников
Android-форка:

```bash
# 1. склонировать репозитории плагинов (один раз)
git clone --depth 1 https://github.com/The-MoonTg-project/extera-plugins third_party/corpus-sources/extera-plugins
git clone --depth 1 https://github.com/Den4ikSuperOstryyPer4ik/CactusPlugins third_party/corpus-sources/CactusPlugins
git clone --depth 1 https://github.com/mr-Vestr/plugins third_party/corpus-sources/vestr-plugins

# 0. перед первой сборкой: сабмодули Telegram-iOS (пины — docs/submodule-pins.json)
git submodule update --init --recursive
# если сабмодули не инициализированы (снапшот без них): python tools/fetch_submodules.py

# 2. собрать корпус в один каталог
python -m tools.compat.collect_corpus

# 3. сгенерировать манифест + отчёт
python -m tools.compat.generate_manifest
```

Результат: `build/compat/manifest.json` и `build/compat/report.md`.

Если исходники exteraless лежат не в `third_party/exteraless-android`,
укажи их через `EXTERALESS_ANDROID_ROOT`.

## Сборка iOS (GitHub Actions)

Конфигурация — `telegram-ios/build-system/exteraless-configuration.json`.
По умолчанию api_id/api_hash — официальные от Telegram-iOS (как exteraless
использует официальные Android-шные). Переопределяются секретами
`TELEGRAM_APP_ID` / `TELEGRAM_APP_HASH`.

Workflow: `.github/workflows/ios-build.yml` — macOS-раннер, Bazel,
только ручной запуск. `Make.py build --unsigned` собирает IPA с шестью
iOS-расширениями для последующей самостоятельной подписи. Перед компиляцией
проверяется граф упаковки; сертификаты и профили в CI не нужны.
Проверки и артефакты: [docs/ci-unsigned.md](docs/ci-unsigned.md).

Перед локальным Make.py для runtime-интеграции:

```bash
python3 tools/runtime/prepare_telegram_runtime.py --telegram-root telegram-ios
```

Подготовка создаёт декларированные Bazel inputs: pinned framework/stdlib,
SDK/manifest и 12 закреплённых pure-Python distributions. Она также проверяет
tracked patch к закреплённому Rust submodule. Повторить после изменения исходников;
staging проверяет fingerprints. Полный контракт —
[telegram-ios/build-system/exteraless/README.md](telegram-ios/build-system/exteraless/README.md).

Первая проверенная unsigned IPA: [build 21](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43584868441).
**Telegram с встроенным Python/PluginHost:**
[build 23](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43635233046),
commit `68bb1adf`, [unsigned IPA artifact](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43635233046/artifacts/14131805640).
Проверены 67 ARM64 Mach-O, 55 runtime frameworks, 1071 Python-ресурс и шесть extensions.
Актуальный CPython/Swift/SDK gate:
[runtime build 19](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43738810843),
commit `136c946f` — **GREEN**, включая три bounded native SDK-процесса и iOS probes.
Подробности текущей интеграционной волны и проверки — [docs/python-runtime.md](docs/python-runtime.md).

Проверенный Linux Core-срез: [43732308228](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43732308228),
`96bff39e`: **661 Core + 180 Host + 30 Hooks**. SDK Config: **276 реализовано,
0 заблокировано, 32 явно неподдерживаемых API**. Полная сборка новой IPA и UIKit
приёмка продолжаются; актуальные результаты и владение файлами —
[docs/wave-2/progress.md](docs/wave-2/progress.md).

## Статус этапов

- [x] 0a. Репозиторий + манифест-генератор + корпус
- [x] 0b. CI: unsigned Telegram-iOS 13.1.1 + проверенный артефакт
- [x] 1. CPython 3.12.16 xcframework + реальные iOS-simulator probes
- [x] Нативный CPythonEngine и Swift-адаптер (component validation)
- [x] 2. Native C↔Swift dispatcher — реальные host/iOS component probes
- [x] 3. SDK loader и базовый virtual-java путь — собственный native fixture прошёл
- [x] 4. Встройка PluginHost в Telegram — полная unsigned IPA build 23 проверена
- [x] 5. Первые extension points — send и RPC/update observations врезаны и скомпилированы
- [ ] 6. UI менеджера плагинов — скомпилирован в IPA, проверка по кадрам на устройстве pending
- [ ] Полный client/SDK parity — идёт большая реализационная волна и последующее независимое ревью

Подробный план: `docs/PLAN.md`.
