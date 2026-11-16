# exteraless-ios

Порт **exteraless** (Telegram-клиент для Android с системой Python-плагинов,
форк exteraGram/NagramX, версия 13.1.1-beta15) на **iOS**.

База — нативный **Telegram-iOS 13.1.1** (тот же релиз, что и Android-основа
exteraless), поверх — Python-рантайм и портированная система плагинов.

## Текущий handoff — 16.11.2026

**[Полный Mac gate33](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43795739683)
на `d8705c51` — GREEN и независимый PASS:**722 Core /273 Host /30 Hooks,
23 HNS, пять реальных SDK-процессов и C219. [Проверка артефактов](docs/wave-2/runtime-native-acceptance-33.md).
UIKit20/434 и новая полная Telegram IPA остаются следующими gates.

### Предшествующий source/test-срез

Статусы CI переданы координатором при назначении и последующем уточнении.
Окно чтения handoff, ревью и уточнений: **01:26:56–01:32:15 UTC**, без опроса CI.
Последующие результаты и watcher IDs ведёт координатор в [progress.md](docs/wave-2/progress.md).

**main `a823e619`** — исправление только fixtures после CI/YAML-фикса `d717`
и source-когорты `f704d76c` (288 путей).

- Все известные source findings закрыты, включая ARCH-01/02/03, iOS platform P2,
  NFD-01/02/03, DEV-LIFECYCLE-01, Custom, Search, Reset и Trust
  ([независимые ревью](docs/wave-2/reviews/)). Это закрытие замечаний к исходникам;
  полная native-приёмка нового среза ещё требуется.
- Linux `43784503847 / f704d76c`: **712 Core / 273 Host / 30 Hooks PASS**
  (9.176 / 5.545 / 0.356 с). Общий run упал на PyYAML; это исправлено в `d717`.
  На `d717` Swift job снова PASS, но Python и ранний Mac gate остановились
  на импорте `pytest` из isolated helper. Исправление — `a823e619`.
- Compat **43786135131 / a823e619 — GREEN: 478 PASS / 36 skip**, 147.86 с.
  Swift 712/273/30 относится к указанному выше `f704d76c`; production source сохранён.
- Mac **43786148988 / a823e619**: 91 runtime-packaging, 63 plumbing и
  49 finite SDK / 13 skip — PASS; затем **FAILED: реальный Darwin listener
  не достиг readiness за 2 с**. NativeDev owner уточняет состояние `NWListener`
  отдельной bounded Darwin-only проверкой; **5-child gate не пройден**.
- UIKit **43785534046 / d717**: **FAILED на `aquery`, до компиляции**.
  Tooling owner скачивает сохранённый `build.log`; **20 сцен / 434 native XCTest-метода
  готовы, но ещё не исполнены**.

SDK Config: **276 implemented / 0 blocked / 32 unsupported**, 308 API ID,
508 bindings. Карты 567 source features и 925 SDK routes полны; это не повышение
статусов native verification. Подробности — [docs/python-runtime.md](docs/python-runtime.md).

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
**Последняя независимо проверенная unsigned Telegram IPA — 13.1.1 (40),
со встроенным Python/PluginHost:**
[build 40](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43779402542),
commit `6de4ac36`, [unsigned IPA artifact](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43779402542/artifacts/14187634135).
Независимо проверены 67 unsigned ARM64 Mach-O, 60 frameworks (55 runtime),
1418 обязательных resource placements, шесть extensions, 419 source pins
и 12 distributions. Размер: **98 177 711 байт**. SHA-256:
`e28940fdb017941525824ba1906d09e32da6bd973fa1c1c7c41bd294eeee3d99`.
Delivery-файл:
`build/artifacts/telegram-43779402542/exteraless-ios-13.1.1-40-unsigned.ipa`.
[Заключение и SHA-256](docs/wave-2/ipa-build40-acceptance.md).
Новые SDK/Host/UIKit исходники `f704d76c` этим build 40 не покрыты.
Пользователь подписывает IPA самостоятельно; физическая установка, APNs и live RPC
ещё не проверены. Build 40 подтверждает compile/package своего среза.

**Исторический полный CPython/Swift/SDK gate до новой когорты:**
[runtime build 20](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43743252038),
commit `e16f3808` — **GREEN: 680 Core / 180 Host / 30 Hooks**,
три bounded native SDK-процесса и iOS 219-call gate.
Подробности текущей интеграционной волны и проверки — [docs/python-runtime.md](docs/python-runtime.md).

Исторический Linux Core-срез: [43764252538](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43764252538),
`aca0eb38`: **712 Core + 180 Host + 30 Hooks**. SDK Config: **276 реализовано,
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
- [x] 4. Встройка PluginHost в Telegram — полная unsigned IPA build 40 проверена
- [x] 5. Первые extension points — send и RPC/update observations врезаны и скомпилированы
- [ ] 6. UI менеджера плагинов — скомпилирован в IPA, проверка по кадрам на устройстве pending
- [ ] Полный client/SDK parity — известные source findings закрыты; native gates, UIKit и проверка на устройстве ещё требуются

Подробный план: `docs/PLAN.md`.
