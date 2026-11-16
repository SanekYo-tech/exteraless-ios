# План: порт exteraless (Android) → iOS

## Текущий handoff — 16.11.2026

**Mac43795739683 / `d8705c51` — GREEN и независимый PASS:**722Core/273Host/30Hooks,
23HNS,5SDKchildren,C219. [Artifact acceptance](wave-2/runtime-native-acceptance-33.md).
Следом — UIKit20/434 и новая полная Telegram IPA.

### Предшествующий source/test-срез

Статусы CI взяты из назначения и последующего уточнения координатора.
Окно чтения handoff, ревью и уточнений — **01:26:56–01:32:15 UTC**, без опроса CI.
Следующие результаты и watcher IDs —
в [wave-2/progress.md](wave-2/progress.md).

**main `a823e619`**: fixture-only исправление isolated helper после `d717`
(CI/YAML) и `f704d76c` (source-когорта, 288 путей).
Все известные source findings закрыты: ARCH-01/02/03, iOS platform P2,
NFD-01/02/03, DEV-LIFECYCLE-01, Custom/Search/Reset/Trust; доказательства —
[независимые ревью](wave-2/reviews/). Native-приёмка нового среза остаётся отдельным
критерием готовности полного порта.

| Проверка | Состояние по последнему сообщению координатора |
|---|---|
| Linux `43784503847 / f704d76c` | **712 Core / 273 Host / 30 Hooks PASS**; общий run FAILED на PyYAML, исправлено в `d717` |
| Linux `43785348360 / d717` | Swift job PASS; Python **472 PASS / 36 skip / 6 fail** на импорте `pytest` из isolated helper |
| Mac `43785374048 / d717` | Ранний finite pytest упал по той же причине; новые 5 native child-процессов ещё не исполнялись |
| Compat `43786135131 / a823e619` | **GREEN: 478 PASS / 36 skip**, 147.86 с; production source прежнего Swift 712/273/30 сохранён |
| Mac `43786148988 / a823e619` | **91 runtime-packaging + 63 plumbing + 49 finite SDK / 13 skip PASS**; затем FAILED: реальный Darwin listener не достиг readiness за 2 с. **5-child gate не пройден** |
| UIKit `43785534046 / d717` | **FAILED на `aquery`, до компиляции**; tooling owner скачивает сохранённый `build.log`. 20 сцен / 434 native XCTest-метода — READY, ещё не исполнены |

Локально фикс `a823e619` прошёл 4 проверки / 10 Windows/C skips и emitter `-I -S`
с `noSite`. NativeDev owner уточняет точное состояние `NWListener` отдельной
bounded Darwin-only проверкой; причина readiness failure ещё не установлена.

Последняя независимо проверенная unsigned IPA — **Telegram 13.1.1 (40)**,
`43779402542 / 6de4ac36`, artifact `14187634135`:
[приёмка build 40](wave-2/ipa-build40-acceptance.md). Source-когорта `f704d76c`
в неё не входит. Пользователь подписывает IPA сам; физическая установка,
APNs и live RPC ещё не проверены. Полные границы и receipts — [python-runtime.md](python-runtime.md).

## Исходники

| Что | Где | Версия |
|---|---|---|
| exteraless (Android-клиент + плагины) | `third_party/exteraless-android/` (java/kotlin/python) | 13.1.1-beta15 |
| Telegram-iOS (база) | `telegram-ios/` | 13.1.1 (тот же релиз) |
| Корпус плагинов | `third_party/corpus/` (генерируется) | репо каталогов exteraGram |
| ocm-ios (референс Python-встройки, не в репо) | Downloads | build 81 |

## Архитектура

```
Telegram-iOS 13.1.1 (Swift/ObjC, Bazel)
└── PluginHost (Swift): сервисы, extension points, HookRegistry
    └── _exteraless_bridge (C, versioned protocol, immutable owner token)
        └── CPython 3.12.16 (PEP 684, собственный OS worker/GIL на плагин)
            ├── virtual-java: явный реестр классов и манифест поддержанных методов
            ├── SDK: порт TMessagesProj/src/main/python (elyx_runtime, extera_utils, ui/*)
            └── packaged stdlib / PEP 730 frameworks, bundled wheels, батчинг событий
```

Принципы:
1. **Нативные операции — Swift/C, SDK-совместимость — Python.** Прокси вызывают
   реальные native providers через узкий versioned мост.
2. **Манифест подтверждается реализацией.** Корпус показывает использование;
   Java/Kotlin inventory задаёт исходный контракт. Поддержка требует живого
   consumer и отдельных свидетельств source, tests и native execution.
3. **Приоритеты по частотам корпуса.** Extension points и Swift-цели —
   сначала те, что чаще всего дёргают плагины.
4. **Одноразовый process lifecycle CPython.** Зависший worker теряет допуск к новым
   операциям, но сохраняется в учёте до подтверждённого выхода. Живой/неизвестный
   interpreter запрещает finalize; maintenance не делает finalize/reinitialize.
5. **Тесты как оракул.** pytest-сьют exteraless гоняется против SDK
   headless (Linux CI); мост-конformance — на симуляторе.

## Этапы

| # | Что | Статус | Критерий готовности |
|---|---|---|---|
| 0a | Репозиторий + манифест-генератор + корпус | **готово** | `python -m tools.compat.generate_manifest` зелёный, отчёт читается |
| 0b | CI: сборка базового Telegram-iOS | **готово** | unsigned IPA: run `43584868441` |
| 1 | CPython 3.12 xcframework | simulator **проверен**, device pending | run `43615992774`; подписанное приложение ещё требует запуска на iPhone |
| 2 | Мост `_exteraless_bridge` + протокол | **component gate пройден** | 169 C-callbacks на iOS; Swift↔C с настоящим CPython |
| 3 | Virtual-Java слой + SDK loader | **собственный native fixture пройден** | `43633853229`: load/reload/settings/events, provided deps, MODIFY/CANCEL |
| 4 | PluginHost Swift + менеджер суб-интерпретаторов | **IPA build 40 проверена** | `43779402542`, `6de4ac36`, runtime в основном bundle |
| 5 | Extension points по частотам корпуса | baseline observations в IPA; новые transformations в source | native parsing/order/pts/seq, pre/post/update MODIFY/CANCEL; новая Apple-проверка ожидается |
| 6 | UI менеджера плагинов (Display/UIKit) | UI в build 40; новый native gate READY | 20 сцен / 434 native XCTest-метода ещё не исполнены; требуется приёмка кадров |
| 7 | Отчёт совместимости в CI | частично | fixture/native suites; поведение внешнего корпуса на устройстве ещё не измерено |
| 8 | Полный client/SDK parity и независимое ревью | известные source findings закрыты; native-приёмка pending | Карты 567 feature IDs / 30 modules / 925 SDK routes полны; verified/ported статусы требуют своих receipts, проверок и новой unsigned IPA |

Контракт первой интеграции: [wave-1-contract.md](wave-1-contract.md).
Проверенные результаты и границы доказательства: [python-runtime.md](python-runtime.md).
Полная client/SDK реализационная волна с независимым последующим ревью:
[wave-2-contract.md](wave-2-contract.md). Инвентаризация пересматривается по Java
**и Kotlin**; прежние 159 shim-полей не являются полным списком native функций.
Проверенные snapshots, закрытия review findings и текущие передачи общих файлов:
[wave-2/progress.md](wave-2/progress.md). Исторический полный Linux gate —
`43764252538 / aca0eb38`: **712 Core + 180 Host + 30 Hooks**.
Исторический полный runtime/SDK gate **43743252038 / e16f3808 GREEN**:
**680 Core / 180 Host / 30 Hooks**, три bounded native SDK процесса,
iOS 219-call gate и unsigned device probe — до когорты `f704d76c`. Новая Telegram IPA и UIKit
XCTest/recordings проходят отдельную приёмку.

## Ключевые решения

- **api_id**: официальный Telegram-iOS (`8`) как дефолт конфига —
  схема exteraless («собирается из коробки»); в CI переопределяется
   секретами `TELEGRAM_APP_ID`/`TELEGRAM_APP_HASH`.
  Оба repository Actions secrets установлены по запросу пользователя 15.11.2026;
  значения в исходники и handoff не копируются.
- **Дистрибуция**: unsigned IPA → Sideloadly/AltStore/TrollStore
  (плагины = исполняемый код ⇒ App Store 2.5.2 закрыт).
- **DEX/Java-плагины**: не переносим (нет JVM на iOS). Только .py/.plugin.
- **Xposed-хуки**: через extension points + swizzle-реестр, покрытие —
  по статистике хуков из манифеста.

## Риски

- Паритет плагинов — измеримый, но не 100%: reflection-тяжёлые плагины
  деградируют (manifest.json показывает, какие именно);
- Bazel-сборка на GitHub Actions: тяжёлая, macOS-минуты дорогие;
- GPL: исходники публикуем;
- Поддержка: синхронизация с апстримами Telegram (Android+iOS) — навсегда.
