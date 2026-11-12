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
unsigned IPA артефактом.

## Статус этапов

- [x] 0a. Репозиторий + манифест-генератор + корпус
- [ ] 0b. CI: сборка стокового Telegram-iOS
- [ ] 1. CPython 3.12 xcframework
- [ ] 2. Мост `_exteraless_bridge`
- [ ] 3. Virtual-Java слой
- [ ] 4. PluginHost (Swift)
- [ ] 5. Extension points
- [ ] 6. UI менеджера плагинов

Подробный план: `docs/PLAN.md`.
