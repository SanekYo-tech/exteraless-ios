# План: порт exteraless (Android) → iOS

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
| 4 | PluginHost Swift + менеджер суб-интерпретаторов | **IPA build 23 проверена** | `43635233046`, `68bb1adf`, runtime в основном bundle |
| 5 | Extension points по частотам корпуса | baseline observations в IPA; новые transformations в source | native parsing/order/pts/seq, pre/post/update MODIFY/CANCEL; новая Apple-проверка ожидается |
| 6 | UI менеджера плагинов (Display/UIKit) | скомпилирован, визуальная приёмка pending | импорт/включение/настройки/permissions/лог; требуется запись кадров |
| 7 | Отчёт совместимости в CI | частично | fixture/native suites; поведение внешнего корпуса на устройстве ещё не измерено |
| 8 | Полный client/SDK parity и независимое ревью | реализация и remediation | 567 original feature IDs, 30 modules, 925 SDK symbols; все receipts, проверки и новая unsigned IPA |

Контракт первой интеграции: [wave-1-contract.md](wave-1-contract.md).
Проверенные результаты и границы доказательства: [python-runtime.md](python-runtime.md).
Полная client/SDK реализационная волна с независимым последующим ревью:
[wave-2-contract.md](wave-2-contract.md). Инвентаризация пересматривается по Java
**и Kotlin**; прежние 159 shim-полей не являются полным списком native функций.
Проверенные snapshots, открытые review findings и текущие передачи общих файлов:
[wave-2/progress.md](wave-2/progress.md). Последний полный Linux gate —
`43759513734 / 1880b663`: **704 Core + 180 Host + 30 Hooks**.
Полный runtime/SDK gate **43743252038 / e16f3808 GREEN**: три bounded native SDK
процесса, iOS simulator и unsigned device probe. Новая Telegram IPA и UIKit
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
