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
    └── _exteraless_bridge (C, ~8 функций, versioned protocol)
        └── CPython 3.12 (PEP 684, суб-интерпретаторы на плагин)
            ├── virtual-java: манифест-прокси классов (генерируется tools/compat)
            ├── SDK: порт TMessagesProj/src/main/python (elyx_runtime, extera_utils, ui/*)
            └── packaged stdlib / PEP 730 frameworks, bundled wheels, батчинг событий
```

Принципы:
1. **Совместимость — в Python, не в Swift.** Один узкий мост; все шимы —
   прокси по генерируемому манифесту (данные, не код).
2. **Манифест — единственный источник правды.** Генерируется из корпуса
   плагинов (реальное использование) + исходников Android-форка.
3. **Приоритеты по частотам корпуса.** Extension points и Swift-цели —
   сначала те, что чаще всего дёргают плагины.
4. **Изоляция суб-интерпретаторами.** Зависший плагин выбрасывается,
   приложение живо. Watchdog — только для RSS/таймаутов.
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
| 4 | PluginHost Swift + менеджер суб-интерпретаторов | интегрирован, CI pending | Bazel/runtime/lifecycle, сохранение и загрузка плагинов |
| 5 | Extension points по частотам корпуса | первые врезки реализованы | send CANCEL/MODIFY; RPC/updates пока observational |
| 6 | UI менеджера плагинов (Display/UIKit) | реализован, визуальная приёмка pending | импорт/включение/настройки/permissions/лог; требуется запись кадров |
| 7 | Отчёт совместимости в CI | частично | fixture/native suites; поведение внешнего корпуса на устройстве ещё не измерено |

Контракты текущей большой волны: [wave-1-contract.md](wave-1-contract.md).
Проверенные результаты и границы доказательства: [python-runtime.md](python-runtime.md).

## Ключевые решения

- **api_id**: официальный Telegram-iOS (`8`) как дефолт конфига —
  схема exteraless («собирается из коробки»); в CI переопределяется
  секретами `TELEGRAM_APP_ID`/`TELEGRAM_APP_HASH`.
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
