# Полная волна — точка стыковки 15.11.2026

## Текущая точка

- **HEAD `b1424e10`**, последний Linux gate **43693106297**: **280 Core + 89 Host
  + 16 Hooks passed**, Core execution 2.689 s. Совместная регистрация публичных
  domain schemas также проверена. Это не UIKit/native-service execution.
- `9222140b` добавил завершённые Foundation appearance/tools/pills/player/feed/
  filtering/hidden-account срезы и C remediation. Python compat job этого commit
  (`43691591367`) success. Swift-повтор исправил NSObject.hash collision
  (`b50d63e6`), throwing Pill fixture (`e89009a4`), затем реальную потерю base letters
  при Unicode deletion (`b1424e10`); теперь оба текстовых пути строят UTF-16 projection.
- C P2 **независимо закрыт**, `reviews/native-owner-token-followup.md`. Новых P1/P2
  в C не найдено. Native author's свежий Windows probe — **219 calls**, 27 terminal
  entry refusals и 2/2 freed payloads. Reviewer не повторял весь 219-call probe из-за
  изменённых parallel SDK/validator fingerprints; final native CI обязан собрать
  актуальные inputs заново.
- **Открытые review findings:** Settings SC-01…08 (1 P1, 7 P2), AI AI-01…18
  (5 P1, 13 P2). Исправляют исходный Core/settings owner, AI Core owner и отдельный
  native-AI remediator. Последний green CI предшествует этим fixes.
- Все первые domain source-handoffs получены; завершается применение shared hunks
  и независимое ревью. Ни полной новой IPA, ни записанных UIKit frames пока нет.

### Текущие передачи, приоритетнее старой таблицы

| Владение | Session / задача |
|---|---|
| ClientSettings / value / definition / secrets / tests + ClientSettingsBridgeExtension | `ses_e243feabaffewbO5DkO2qNaCMs`: SC-01…08 remediation и optional strict valueShape |
| Core AI + provider settings editors + plugin-review controller | `ses_e243e30eeffevvi6PoeDOI6HKb`: AI-04/05/11/12/13/17 fixes |
| Native AI integration/adapter/actions/results/rich mapper/Speech + Core AI engine helpers | `ses_e21e26903ffettUNcrNabLYO1D`: остальные AI findings; common changes возвращает patch |
| Network/Account/UpdateGroup/UpdateMessageService/AccountStateManagementUtils/RequestEditMessage + PluginHost/ExtensionPoints | `ses_e243a7152ffeYsQQZoLZXmyT32`: применяет TL shared mutation pipeline; сохраняет maintenance/gates |
| AppDelegate/ClientRuntime/SharedAccountContext/ApplicationContext/Passcode/NotificationService/AccountViewTracker/list projection/reaction/blocked/download hooks | `ses_e23c3fd88ffeMRAQjFJMkGEi7B`: privacy-extras integration; Root недоступен coordinator до возврата |
| Runtime/Manager/PluginSettings + PluginUI | `ses_e243ae7aeffeUQ5vuAwd50ZLES`: native services/TL transforms, schema/recovery/manager prefs, harness factories |
| GalleryUI UniversalVideoGalleryItem + Gallery subtitle bridge + ToolsIntegration | `ses_e243dc98dffe0Q86bXmQPlA0ju`: реальная subtitle clock/layout/menu/PiP integration |
| ChatController/history/list/avatar/PeerInfo story guards, узкие next/story LoadDisplayNode sections | `ses_e23a8d83effeF78mYrykWv5M0P`: dialog shared hunks; state pin-echo отдаёт TL owner |
| MtProtoKit/Rust DNS/stream host + location/map/external-navigation | `ses_e23a80a9cffeBJo6p90oWskp2w`: NetworkMaps native hooks, Network/Root hunks отдельно |
| Non-common emoji/font/picker/GIF/recents/reaction + local favourites | `ses_e23aa4ae2ffeh4R3TtaQBhKaje`: применяет готовые 37 anchors и Tools favourites |
| Identity non-conflicting name/date/profile presentation seams | `ses_e23a86f80ffep0m8LJJWGDJPxo`: 22 IDs / 152 anchors, занятые shared sections отдаёт отдельным patch |
| Cloud legacy mapping/credentials | `ses_e23a799e4ffexGANrzzE3WW4C9`: Android cloud import, согласование AI origin-bound credential API |
| Plugin pill bridge + RTT audit | `ses_e23c4f365ffein8sxkRXQqqmH1`: Runtime pill services, stable ID mapping; existing Core frozen для CI |

Chat phase 2 / SDK / retention / build / UI harness сохраняют ранее выданные scopes.
App integration не должна дважды вычитать filtered unread: `ChatListNodeLocation`
уже использует `exteralessDialogProjectList` → `exteralessFilterChatList` перед sorting.
Первый clean P2 C pass не равен повторному execution текущего SDK snapshot.

### Новые reviewers

- Settings: `ses_e22059302ffeTTkt6sccLHsEbl`, report получен, ожидает fix/re-review.
- AI: `ses_e22049f6dffeSiz0Jp8oE1BVLX`, report получен, ожидает fix/re-review.
- Tools/backup/files: `ses_e21be726affeNDjsq2yXYN3qeh`.
- Appearance: `ses_e21be7259ffetV07BXfehvmYGO`.
- Feed/player/pills: `ses_e21be714fffeFhsVulQ5XTiIuh`.

### Применённые после предыдущей точки hunks

- Feed AccountContext entry, root tab replacement/badge + appearance re-composition;
  feed update раньше appearance. Player/Pill root integration, Channel feed tab menu,
  pill header panel/visibility и external Contacts/Settings fallbacks.
- Native PiP swipe checks в Gallery; subtitle интеграция теперь у Tools owner.
- `Display.nativeWindowHostView(windowScene:)`: scene до root/controller keyboard.
- Harness BUILD filegroups/framework visibility внесены build-owner; manager/settings
  factories — у UI-owner. Harness workflow исправляет его author: **full app всегда
  собирался на `xcode-27` / Xcode 27.1**; `macos-26` / 26.6 предназначен для runtime
  component tests. `UIView.reservedRegions` требует настоящего нового SDK.
- Exact raw C-owned request JSON сохраняется при extension dispatch, предотвращая
  лишнее округление чисел до strict ClientSettingValue decoder. Forged legacy
  identity fixtures всё ещё получают authoritative native pluginId.

Ни одного активного IPA dispatch/watcher на этой точке. Новые MAC gates запускать
после закрытия P1 и стыковки текущего SDK/Host/input fingerprint.

## Проверенные снимки

| Снимок | Проверка | Результат |
|---|---|---|
| `68bb1adf` | Full IPA `43635233046`, build 23 | 67 unsigned ARM64 Mach-O, 55 Python frameworks, 1071 Python resource, 6 extensions; локальная повторная проверка SHA/layout/seal |
| `496d4262` | Linux `43645893132` | 15 Core settings + 79 PluginHost + 16 PluginHooks tests |
| `b274f4de` | Linux `43649411038` | 45 Core settings/chat/feed/link tests + 79 PluginHost + 16 PluginHooks; Core suite 0.478 s |
| `4b3f7064` | Linux `43653040458` | **122 Core + 89 PluginHost + 16 PluginHooks**, все passed; Core 1.428 s. Включает 28 settings/CAS, 40 AI и privacy-policy fixtures |
| C owner-token WIP | Windows CPython 3.12.10, debug allocator | 213 C calls, включая прежние 169; 24 bridge tests passed / 1 skipped; iOS повтор ещё нужен |

HEAD `4b3f7064`: Core/AI/privacy, settings batch/CAS, bridge discovery и bounded
native-effect leases закоммичены. `43651602940` поймал actor/autoclosure в AI review
initializer; `43652447120` — повторное имя request в LLM fallback. Исправления
`77209d28` / `4b3f7064` прошли указанный последний CI.

Последние коммиты добавляют самостоятельные Foundation-модели и тесты.
Остальная большая волна остаётся в рабочем дереве; она не входит в build 23.
Активной IPA-сборки или watcher на этой точке нет.

## Полученные первые срезы

Все 11 исходных ролей вернули source-handoff: Core/settings, appearance, chat,
privacy, AI/speech, tools, SDK, native plugin UI, TL, dependencies/build, parity.
Карта оригинала содержит 567 settings/state/templates, 30 modules, 925 SDK symbols.
После сверки незакрытые переносимые функции разнесены в следующую подволную.

## Текущее владение

| Роль | Session | Файлы / следующий результат |
|---|---|---|
| Inventory gaps — получено | `ses_e2443e129ffeJ4NxmpHRWiaEEO` | `remaining-ownership.*`: ещё 82 IDs; все назначены ниже/Chat/Extras |
| Core batch/CAS — получено, CI green | `ses_e243feabaffewbO5DkO2qNaCMs` | `applyPublic`/resetting/expected, 28 settings tests |
| Appearance phase 2 | `ses_e243f7abcffeGuUNpnkq2GkoQa` | Appearance policies/native views, навигация, styles, decorations |
| Chat phase 2 | `ses_e243f0df6ffeyOgNnZ6UAfr3px` | ChatFeatures/Policy/input/actions/links, `EnqueueMessage.swift`, privacy + explicit silent-send policy |
| Privacy fixes — получено | `ses_e243e9ec3ffeNQLS1mE6CHrtur` | Postbox boundary, bounds/cancel/expiry, central namespace, TL privacy metadata |
| AI phase 2 — получено | `ses_e243e30eeffevvi6PoeDOI6HKb` | Native boundary исправлен; shared compose/summary/auto/article/render hunks применены coordinator |
| Tools phase 2 | `ses_e243dc98dffe0Q86bXmQPlA0ju` | Backup journal/CAS/rollback, camera/tools helpers, subtitles/favourites |
| SDK/native fixture | `ses_e25088ca2ffeapc0yZ2vwlbKAh` | Python adapters/registry/tests и Swift+CPython SDK fixture |
| Plugin UI composition | `ses_e243ae7aeffeUQ5vuAwd50ZLES` | PluginUI, **ExteralessPluginRuntime.swift**, PluginSettingsController, Chat open-message/open-peer menu files |
| TL transformations | `ses_e243a7152ffeYsQQZoLZXmyT32` | TL helpers/schema/codec, new PluginTL* hooks, RPC/update mutation handoff |
| Build/resources — срез получен | `ses_e25088d28ffem4nSC3FcOP577B` | AdGuard exact pin + GPL, 203 imports/43 targets audit, iOS test labels; final staging после cohort |
| Native SDK services | `ses_e23dc0954ffeEMh9n0izZtjJbQ` | PluginServices, NativeService* helpers; queues/files/intents/logs/controllers |
| Retention | `ses_e23d7951effep2RWsy5h8oFA3t` | ExteralessRetention + RetentionFeatures; received-message edit/delete archive/media |
| Privacy extras | `ses_e23d72be2ffeRJmlhKY4LBsZxV` | Filtering/hidden accounts/panic; ExteralessPrivacyExtras |
| Host maintenance/gates | `ses_e25088ca0ffeSZG3hnR62kAl3y` | **PluginHost.swift / SubinterpreterManager.swift / PluginCallbackDispatcher.swift**, lifecycle tests |
| Player | `ses_e23c59fa3ffeQ9l6CFXD6gAPU7` | PlayerFeatures/new Player sources, native player/MediaManager/SharedMediaPlayer, lyrics/styles |
| Feed | `ses_e23c54cb8ffe3nH7QqgmL29dSQ` | ChatFeedPolicy/history + native feed screens; full media/receipts/pagination |
| Pills | `ses_e23c4f365ffein8sxkRXQqqmH1` | PillFeatures/providers + native pill screens/header handoff |
| App lifecycle — получено | `ses_e23c3fd88ffeMRAQjFJMkGEi7B` | AppDelegate/privacy/launcher и PeerInfo Ghost/phone применены; общие файлы возвращены coordinator |
| Stickers/emoji | `ses_e23aa4ae2ffeh4R3TtaQBhKaje` | P-stickers-emoji 21 IDs; Chat сохраняет shape/time, Tools — favorites |
| Dialogs/search/archive | `ses_e23a8d83effeF78mYrykWv5M0P` | P-dialog-navigation 16 IDs + два distinct sortByUnread |
| Local identity/premium presentation | `ses_e23a86f80ffep0m8LJJWGDJPxo` | P-local-identity 11 + P-local-premium 11 |
| Resolver/maps | `ses_e23a80a9cffeBJo6p90oWskp2w` | P-network-resolver 3 + P-maps 3 |
| Cloud/client API | `ses_e23a799e4ffexGANrzzE3WW4C9` | P-cloud-sync 3 + P-client-api 3 |
| UI frame harness | `ses_e23a4ef4effez9e9gzdD85RUdm` | NEW Tests/ExteralessHarness/**, его BUILD и client-ui-harness.yml — отдельное владение |

C owner-token role `ses_e25088d13ffeTRn8jKSxiC5l9R` возобновлена для исправления
подтверждённого P2 из независимого ревью: reentrant `__del__` при bulk handle clear
теряет C-ссылку. Отсоединение таблиц до DECREF/terminal gate и regression в работе.
Новый набор callback checks потребует обновить counts/fields runtime gate после
отчёта, не подменять старый 213-call artifact.

Последние 11 из 82 gaps: P-message-presentation 10 явно закреплены за Chat phase 2;
P-system-contacts 1 — за Privacy extras как exact Android AccountManager disposition.
R-runtime 16 manager/config IDs переданы UI+SDK; ExteraConfig 308 overload receipts — SDK.

После перезапуска сервера по запросу пользователя **20 незавершённых assignments
возобновлены в прежних sessions**; завершённые срезы повторно не запускались.

## Независимое ревью

| Роль | Session | Результат |
|---|---|---|
| C owner epoch | `ses_e23bd3fc4ffeaEV375EzI6saOZ` | `reviews/native-owner-token.md`: один воспроизведённый P2 bulk-clear leak; UAF/crash не подтверждены; owner-token новых дефектов не найдено |
| Settings/CAS/secret boundaries | `ses_e22059302ffeTTkt6sccLHsEbl` | read-only review готового Core-среза |
| AI original/native/provider parity | `ses_e22049f6dffeSiz0Jp8oE1BVLX` | read-only review AI после shared wiring |

Остальные независимые reviewers назначаются после стыковки соответствующих реализаций.
Результаты background задач приходят уведомлениями; не создавать polling.

## Coordinator: уже состыковано

- Shared native feature store/configuration до Account initialization; domain
  integrations создаются после выбора app-group file. Client bridge читает
  coherent redacted snapshot и использует атомарный запрет secret writes.
- Native owner UUID публикуется в HostState, затем C setter и SDK bind до load.
  BridgeServices проверяет epoch; native provider повторно сравнивает epoch при
  принятии асинхронного запроса. Terminal unload и bootstrap — отдельные admission состояния.
- Result-bearing callback dispatcher, per-owner callback/release FIFO; SDK cleanup
  идёт через `release_handles_json`, а не только C handle deletion. Mailbox gate и
  maintenance продолжаются у lifecycle-owner.
- `PluginBridgeExtension.exportedMethods`: side-effect-free discovery установленного
  provider, unknown остаётся unknown. UI/TL/services owners уведомлены о таблице.
- TL descriptor factory, TL provider composition и deep observation codecs
  подключены. Actual transformations добавляет TL-подволна.
- AI message/selected-text входы; appearance alternate icons, root contacts filter,
  chat-theme overrides и settings list styling; chat message actions и bot-command
  confirmation уже вставлены в общие файлы.
- Native effects получают `PluginNativeCallLease`; перед UI/send и после async
  подготовки повторно проверяют тот же epoch/grants. Очередь 256/plugin, 1024 total,
  32 MiB, tickets уникальны; unload не уменьшает счётчики новой lifetime.
- Legacy native runnable uses `onOwnedCallback(pluginId, ownerToken, ...) -> Bool`,
  reservation/rollback/completion привязаны к паре plugin+epoch. Runtime UI/SDK
  fixture/Host owners уведомлены о новом контракте; их части ещё собираются.
- Все три NativeServiceOpenHooks sites применены: external browser, incoming app
  URL и document preview; builtin plugin URL opener сохраняет effect lease/ticket
  до настоящего продолжения после before-handlers. UI-owner подключает provider.
- Центральный `Namespaces.CachedItemCollection.exteralessLocalState = 63` объявлен;
  privacy/retention/extras используют disjoint prefixes и удаляют только свои строки.
- Официальный PostboxImportCheck после AI boundary correction: exit 0 (отчёт AI owner).

## Следующие gate

1. Принять недостающие shared hunks, новые domain definitions/composition и schema
   registrations. Устранить коллизии keys/namespace/imports до запуска IPA.
2. Слить parity fragments с фактическими source/callsite/test evidence; проверить
   оставшийся gapset. Storage-only и platform adaptation не равны fake success.
3. Прогнать адресные suites и обновлённый macOS/iOS native SDK/runtime gate.
4. Независимые reviewers: original parity, SDK/C/lifecycle, native UI/main-thread,
   network/media/privacy и Bazel/resources. Исправить findings и перепроверить.
5. Полная unsigned IPA, проверка скачанного пакета; подпись/установка пользователем
   и визуальная приёмка по записанным кадрам. XcodeBuildMCP здесь отсутствует.
