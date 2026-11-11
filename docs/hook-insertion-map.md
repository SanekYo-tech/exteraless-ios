# Карта вставки extension points

Проверено по дереву `C:\exteraless-ios` (номера строк — текущие, не из `swift/PluginHost/README.md`). Патчи не применялись.

Живой Android-диспетчер — `app.exteraless.plugins.PluginsController`. Класс `com.exteragram.messenger.plugins.PluginsController` — абстрактный шим для dex (`executeOnAppEvent` объявлен и не реализован). Флаги `handles*` живут в `app.exteraless.plugins.Plugin` (строки 75–80) и выставляются при загрузке в `PluginsController` (строки 773–778): если объекта `handles` нет, все `handles*` становятся `true`. `hasSettings` (строка 68, комментарий «есть ли create_settings») ставится отдельно, по умолчанию `false` (`optBoolean("has_settings", false)`, строка 771). В Swift то же соответствие: `Plugin.handles(_:)` в `swift/PluginHost/Sources/PluginHost/PluginHost.swift:547` отдаёт для `.createSettings` поле `hasSettings`.

Гейт на каждой точке — до любой сериализации и до входа в актор:

```swift
guard host.events.subscribers.hasSubscribers(kind) else { return }
```

`host.events` — `PluginEventBus` (`PluginHost.swift:179`). `SubscriberGate.hasSubscribers` — `ExtensionPoints.swift:87`. Методы `emit*` / `preSendMessage` / `requestCreateSettings` повторяют этот гейт внутри себя; гейт на месте вставки нужен, чтобы не строить JSON, когда подписчиков нет.

Строка `enqueueMessages` из README (`EnqueueMessage.swift:730`) совпадает с текущей сигнатурой. Файла `PluginSettingsScreen` в `submodules/SettingsUI` нет.

---

## 1. create_settings

**Android.** Экран открывают только при `plugin.hasSettings && plugin.loaded` — `PluginsActivity.showPluginMenu`, `TMessagesProj/src/main/java/app/exteraless/plugins/ui/PluginsActivity.java:583`. Сам хук стреляет из `PluginSettingsActivity.fetchJson` (`.../ui/PluginSettingsActivity.java:446`): `PluginsController.getPluginSettingsJson` (`PluginsController.java:1348`) → `PythonPluginsEngine.getSettingsJson` (`PythonPluginsEngine.java:433`) → `loader.callAttr("get_settings_json")`. В Python это `get_settings_json` (`python/sdk/extera_utils/plugin_loader.py:3420`), строка 3427: `items = instance.create_settings()`. Имя константы — `PluginsConstants.CREATE_SETTINGS = "create_settings"` (`PluginsConstants.java:116`). Отдельного `handlesCreateSettings` нет: условие — `hasSettings`. Внутри `fetchJson` флаг повторно не проверяется.

**iOS.** `PluginSettingsScreen` в дереве нет. Пункт списка плагинов ставится в уже существующий сборщик главного экрана настроек (он в TelegramUI, не в SettingsUI):

`func settingsItems(data: PeerInfoScreenData?, context: AccountContext, presentationData: PresentationData, interaction: PeerInfoInteraction, isExpanded: Bool) -> [(AnyHashable, [PeerInfoScreenItem])]`

`telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift:32`

Функцию зовёт `PeerInfoScreen.swift:5670`. Ряд «Плагины» — перед сборкой `result` на строке 355. Вызов `requestCreateSettings` в эту синхронную функцию не кладётся: его место — загрузка нового экрана настроек конкретного плагина, которого в репозитории нет. `SettingsUI/Sources/SettingsController.swift` такого экрана не содержит (`makePrivacyAndSecurityController` на строке 14 — чужая фабрика).

**Kind и гейт.** `ExtensionPointKind.createSettings` (`ExtensionPoints.swift:51`), `protocolName` = `"create_settings"`.

```swift
guard host.events.subscribers.hasSubscribers(.createSettings) else { return }
```

Дальше, уже на экране плагина: `try await host.events.requestCreateSettings(CreateSettingsPayload(pluginId:account:))` (`ExtensionPoints.swift:336`).

**Payload.** Тип есть: `CreateSettingsPayload` (`ExtensionPoints.swift:179`), поля `pluginId: String`, `account: Int32`. Ответ — сырая JSON-строка (`PluginEventResult.settingsJSON` / `.string`), не модель строк. Типов полей `PluginsConstants.Settings` (`type` / `key` / `text` / `subtext` / …, `PluginsConstants.java:125`) в `ExtensionPoints.swift` нет.

**Риск.** `settingsItems` крутится на проходе раскладки настроек. `await requestCreateSettings` внутри неё замораживает экран (таймаут зависания плагина — 5 с, интерпретатор после этого бросается). Гейт по `.createSettings` завязан на `hasSettings`, а он по умолчанию `false`: пункт без этого флага не должен появляться, иначе экран зовёт `create_settings` у плагинов без настроек. Пустой ответ шины — `"[]"`, экран обязан пережить его.

---

## 2. send message

**Android.** Точка выстрела — `SendMessagesHelper.sendMessage(SendMessageParams originalParams)`, `org/telegram/messenger/SendMessagesHelper.java:4500`. Условие на входе (строка 4503): `PluginsController.getInstance().hasSendMessageHooks()` (реестр не пуст, `PluginsController.java:1940`). Дальше `executeOnSendMessageHook` (`PluginsController.java:1962`): сразу выход, если `sendMessageHooks.isEmpty()` или движок не стартовал. На плагин (строка 1970): `p == null || !p.loaded || !p.handlesSendMessage` — пропуск. `CANCEL` возвращается из `sendMessage` до разбора `SendMessageParams` (строки 4506–4507). `MODIFY` подменяет `params`.

**iOS.** Сигнатура, строка всё ещё 730:

`public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError>`

`telegram-ios/submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift:730`

Гейт и `preSendMessage` — на первой строке тела, до `let signal` (строка 731) и до `account.postbox.transaction` (строка 739). Внутренний `func enqueueMessages(transaction:account:peerId:messages:disableAutoremove:transformGroupingKeysWithPeerId:) -> [MessageId?]` (строка 865) уже внутри транзакции Postbox; хук туда не ставится.

**Kind и гейт.** `ExtensionPointKind.sendMessage` (`ExtensionPoints.swift:50`), `protocolName` = `"on_send_message_hook"`.

```swift
guard host.events.subscribers.hasSubscribers(.sendMessage) else { /* исходный Signal, без paramsJSON */ }
```

После гейта — `try await host.events.preSendMessage(SendMessagePayload(account:paramsJSON:))` (`ExtensionPoints.swift:326`). Метод уже возвращает `.default`, если подписчиков нет. `CANCEL` — не открывать транзакцию и вернуть `Signal` с `[MessageId?]` из `nil`. `MODIFY` на шине сейчас нечем применить: см. payload.

**Payload.** Тип есть: `SendMessagePayload` (`ExtensionPoints.swift:169`), поля `account: Int32`, `paramsJSON: String`. Нет отображения `EnqueueMessage` → JSON (в README это TODO этапа 5) и нет `Int32`-индекса аккаунта на аргументе `account: Account`. `preSendMessage` возвращает только `HookStrategy` (`ExtensionPoints.swift:191`: `DEFAULT` / `CANCEL` / `MODIFY` / `MODIFY_FINAL`). Подменённые params наружу не выходят: ветка `.strategy` забирает стратегию и отбрасывает тело (`ExtensionPoints.swift:328–331`).

**Риск.** Это очередь исходящих. Хук внутри замыкания транзакции (строка 739) или внутри функции на строке 865 блокирует очередь Postbox: сообщения остаются в «отправке», сторож через 5 с бросает интерпретатор. Хук после `transaction` уже не отменяет запись: `PendingMessageManager` сообщение увезёт. `preSendMessage` — `async`; `enqueueMessages` синхронно возвращает `Signal`. Ожидание надо вшить префиксом сигнала, а не блокировать поток вызова. Обход публичной функции: `resendMessages` (строка 806) пишет через внутренний `enqueueMessages` на строке 859; `enqueueWelcomeMessages` (строка 776) — отдельный путь. Хук только на строке 730 эти отправки не видит. `return` без `Signal` здесь не компилируется; `Signal`, который не шлёт `next`, подвешивает UI отправки.

---

## 3. updates

Два хука. Оба fire-and-forget: `CANCEL` / `MODIFY`, как в Android, текущая шина не возвращает.

**Android, контейнер.** `MessagesController.processUpdates(final TLRPC.Updates originalUpdates, boolean fromQueue)`, `org/telegram/messenger/MessagesController.java:18269`. Условие (строка 18271): `hasAnyUpdatesContainerHooks()` (`PluginsController.java:2063`), иначе `HookResult.DEFAULT`. Иначе `executeOnUpdatesHook` (`PluginsController.java:2099`). На плагин (строка 2107): `p == null || !p.loaded || !p.handlesUpdates`. `CANCEL` — `return` до `processUpdatesInternal` (строка 18275).

**Android, один апдейт.** `MessagesController.processUpdateArray(...)`, строка 18841. Условие (строка 18855): `hasAnyUpdateHooks()` (`PluginsController.java:2059`). Дальше `executeOnUpdateHook` (`PluginsController.java:2068`). На плагин (строка 2076): `p == null || !p.loaded || !p.handlesUpdate`. `CANCEL` выкидывает апдейт из копии списка до разбора.

**iOS, контейнер (`on_updates`).** Единая воронка:

`func addUpdates(_ updates: Api.Updates)`

`telegram-ios/submodules/TelegramCore/Sources/State/UpdateMessageService.swift:34`

Сюда приходят и сокет (`networkSessionDidReceive`, строка 28), и `AccountStateManager`. Внешний `func addUpdates(_ updates: Api.Updates)` (`AccountStateManager.swift:2176`) только зовёт `Impl.addUpdates` (строка 491), а тот — `updateService?.addUpdates`. Гейт на строке 2176 живые апдейты с сокета пропускает. Ставить на первой строке `UpdateMessageService.addUpdates`, до `switch` и до `groupUpdates`.

Дальше по конвейеру, уже без второго хука контейнера: `pipe` → подписка в `AccountStateManager.reset` (строка 438) → `addUpdateGroups` (строка 2182) → операция `.processUpdateGroups` в `startFirstOperation` (строка 1028) → `finalStateWithUpdateGroups` (`AccountStateManagementUtils.swift:581`).

**iOS, один апдейт (`on_update`).** Отдельного `processUpdateArray` нет. Живой поток режется в

`func groupUpdates(_ updates: [Api.Update], users: [Api.User], chats: [Api.Chat], date: Int32, seqRange: (Int32, Int32)?) -> [UpdateGroup]`

`telegram-ios/submodules/TelegramCore/Sources/State/UpdateGroup.swift:206`

Цикл `for update in updates` — строка 211, до записи состояния. `getDifference` этот цикл не проходит: `finalStateWithDifference` (`AccountStateManagementUtils.swift:708`) собирает `otherUpdates` и на строке 782 зовёт `finalStateWithUpdates` (строка 917), туда же после фильтра дыр pts приходит и живой путь (строка 705). Чтобы видеть и difference, второй гейт — первая строка `finalStateWithUpdates` (917), до `finalStateWithUpdatesAndServerTime` (925), где начинается разбор конструкторов (`updateNewMessage` с строки 1146).

**Kind и гейт.**

Контейнер — `ExtensionPointKind.updates` (`ExtensionPoints.swift:49`), `protocolName` = `"on_updates_hook"`:

```swift
guard host.events.subscribers.hasSubscribers(.updates) else { return }
```

Затем `host.events.emitUpdates(container:account:updatesJSON:)` (`ExtensionPoints.swift:319`).

Один апдейт — `ExtensionPointKind.update` (`ExtensionPoints.swift:48`), `protocolName` = `"on_update_hook"`:

```swift
guard host.events.subscribers.hasSubscribers(.update) else { return }
```

Затем `host.events.emitUpdate(name:account:updateJSON:)` (`ExtensionPoints.swift:312`). Очередь склеивает N событий в `PluginEvent.coalescedUpdates`.

**Payload.** Типы есть: `UpdatesPayload` (`ExtensionPoints.swift:157`: `containerName`, `account`, `updatesJSON: [String]`) и `UpdatePayload` (`ExtensionPoints.swift:145`: `updateName`, `account`, `updateJSON`). Кодировщика `Api.Updates` / `Api.Update` в JSON в `ExtensionPoints.swift` нет. `emitUpdate` / `emitUpdates` не возвращают `HookStrategy`.

**Риск.** `addUpdates` идёт с потока сети. Кодирование каждого контейнера в JSON на этом потоке тормозит MTProto. `await` или выкидывание групп без `.reset` рвёт pts: клиент уходит в бесконечный `getDifference`. Гейт только в `AccountStateManager.addUpdates:2176` не видит сокет. Гейт только в `groupUpdates` не видит `otherUpdates` из difference. Бросать апдейт из `finalStateWithUpdates` после того, как pts уже сдвинут, оставляет дыру, которую Android закрывает отменой до обработки.

---

## 4. pre/post request

**Android.** Оба хука в `ConnectionsManager.sendRequestInternal`, `org/telegram/tgnet/ConnectionsManager.java:427`.

Pre, строки 441–454: `hasAnyRequestHooks()` (`PluginsController.java:1957`), затем `executePreRequestHook` (`PluginsController.java:1992`). На плагин (строка 2000): `p == null || !p.loaded || !p.handlesPreRequest`. `CANCEL` — `return` до `serializeToStream`. `MODIFY` подменяет `TLObject`.

Post, строки 522–541, в колбэке ответа на `stageQueue`: снова `hasAnyRequestHooks()`, затем `executePostRequestHook` (`PluginsController.java:2023`). На плагин (строка 2031): `p == null || !p.loaded || !p.handlesPostRequest`. `CANCEL` не зовёт `onComplete`.

**iOS.** Два параллельных входа, `request` не вызывает `requestWithAdditionalInfo`.

`func request<T>(_ data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), tag: NetworkRequestDependencyTag? = nil, automaticFloodWait: Bool = true, onFloodWaitError: ((String) -> Void)? = nil) -> Signal<T, MTRpcError>`

`telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift:1420`

`func requestWithAdditionalInfo<T>(_ data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), info: NetworkRequestAdditionalInfo, tag: NetworkRequestDependencyTag? = nil, automaticFloodWait: Bool = true, onFloodWaitError: ((String) -> Void)? = nil) -> Signal<NetworkRequestResult<T>, MTRpcError>`

`Network.swift:1374`

Pre — внутри `Signal { }`, до `let request = NetworkEngineRequest` (строка 1423 и строка 1377). Имя запроса уже есть: `data.0.name` (`FunctionDescription.name`, `TelegramApi/Sources/DeserializeFunctionResponse.swift:12`). Post — в замыкании `completed`: успех и ошибка (`Network.swift:1438` и `1448` для `request`; `1400` и `1410` для `requestWithAdditionalInfo`), до `subscriber.putNext` / `putError`.

**Kind и гейт.** `ExtensionPointKind.preRequest` (сырое значение 1) и `.postRequest` (сырое значение 2), `ExtensionPoints.swift:46–47`. Имена: `"pre_request_hook"`, `"post_request_hook"`.

```swift
guard host.events.subscribers.hasSubscribers(.preRequest) else { /* слать NetworkEngineRequest как сейчас */ }
```

```swift
guard host.events.subscribers.hasSubscribers(.postRequest) else { /* putNext/putError без JSON ответа */ }
```

Дальше `host.events.emitPreRequest(RequestPayload(...))` (`ExtensionPoints.swift:300`) и `host.events.emitPostRequest(RequestResponsePayload(...))` (`ExtensionPoints.swift:306`). Оба возвращаются сразу и стратегию не отдают.

**Payload.** Типы есть: `RequestPayload` (`ExtensionPoints.swift:118`: `requestName`, `account`, `requestJSON`) и `RequestResponsePayload` (`ExtensionPoints.swift:130`: `requestName`, `account`, `responseJSON`, `errorMessage`). Сериализатора `Buffer` / результата `T` в JSON нет. Подмены запроса и ответа, как `replacement(TLObject.class)` на Android, в шине нет.

**Риск.** Эти функции — весь RPC, включая `getDifference` и авторизацию. Ожидание плагина внутри `Signal` останавливает запросы. `emitPreRequest` не умеет `CANCEL`: запрос уйдёт, даже если плагин хотел его снять. Если post-хук съест `putNext`/`putError`, вызывающий сигнал висит. Правка байт payload без того же `DeserializeFunctionResponse` ломает разбор ответа (`TL_VERIFICATION_ERROR` на строке 1408 / 1445). Гейт только в одном из двух методов оставляет второй класс запросов без хука.

---

## 5. app event

**Android.** `PluginsController.executeOnAppEvent(String event)`, `PluginsController.java:1902`. Ранний выход, если движок не стартовал (строка 1903). На плагин (строка 1909): `p.loaded && p.handlesAppEvent`. Имена — `PluginsConstants.EVENT_APP_*` (`PluginsConstants.java:90–93`).

Кто зовёт:

| событие | место |
|---|---|
| `app_start` | колбэк после старта движка в `PluginsController.init`, строка 164 (`executeOnAppEvent(EVENT_APP_START)`) |
| `app_pause` | `LaunchActivity.onPause`, `org/telegram/ui/LaunchActivity.java:7111` |
| `app_resume` | `LaunchActivity.onResume`, строка 7360 |
| `app_stop` | `LaunchActivity.onDestroy`, строка 7238 |

`app_pause` и `app_stop` дополнительно зовут `PluginsWatchdog.onAppBackgrounded` (`PluginsController.java:1926`).

**iOS.** `AppDelegate` не реализует `applicationDidEnterBackground` / `applicationWillResignActive`. Их вызывает `SceneDelegate` (`telegram-ios/submodules/TelegramUI/Sources/SceneDelegate.swift`): `sceneDidBecomeActive` строка 27, `sceneWillResignActive` строка 34, `sceneDidEnterBackground` строка 41, `sceneWillEnterForeground` строка 48. Методы `AppDelegate`, куда ставить `emitAppEvent`:

| событие | сигнатура | строка |
|---|---|---|
| `app_start` | `func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool` | `AppDelegate.swift:353` |
| `app_pause` | `func handleWillResignActive()` | `AppDelegate.swift:2044` |
| `app_resume` | `func handleDidBecomeActive()` | `AppDelegate.swift:2150` |
| `app_stop` | `func applicationWillTerminate(_ application: UIApplication)` | `AppDelegate.swift:2179` |

`app_start` на Android стреляет после старта движка (`PluginsController.java:164`), не в момент создания процесса. На строке 353 хост плагинов ещё может не существовать: вызов — после успешного `host.start()`, иначе это падение на старте. `handleDidEnterBackground` (строка 2071) — уход в фон, не `app_stop`. `handleWillEnterForeground` (строка 2118) — раньше `app_resume`.

**Kind и гейт.** `ExtensionPointKind.appEvent` (`ExtensionPoints.swift:45`), `protocolName` = `"on_app_event"`.

```swift
guard host.events.subscribers.hasSubscribers(.appEvent) else { return }
```

Затем `host.events.emitAppEvent("app_start")` (и `"app_pause"` / `"app_resume"` / `"app_stop"`), `ExtensionPoints.swift:294`. Метод сам выходит, если подписчиков нет.

**Payload.** Тип есть: `AppEventPayload` (`ExtensionPoints.swift:112`), одно поле `name: String`. Комментарий на строке 111 перечисляет `app_start` / `app_stop` / `app_pause` / `app_resume`. Отдельного enum этих четырёх строк в `ExtensionPoints.swift` нет: `emitAppEvent` принимает `String` и сам собирает `AppEventPayload`.

**Риск.** `app_stop` из `handleDidEnterBackground` для плагина выглядит как смерть процесса, хотя пользователь только свернул приложение; на Android `onAppBackgrounded` зовут и для pause, и для stop, но имя события разное. `applicationWillTerminate` iOS вызывает не всегда: процесс могут убить без этого метода. Вызов `host.events` до создания хоста в `didFinishLaunching` роняет запуск. Работа без гейта на этих методах удлиняет старт и уход в фон при нуле плагинов.

---

## Сводка file:line

| хук | Android (выстрел) | iOS (куда гейт) | kind |
|---|---|---|---|
| create_settings | `PluginSettingsActivity.fetchJson:446` (`hasSettings` на `PluginsActivity.java:583`) | `PeerInfoSettingsItems.settingsItems:32` (экрана нет) | `.createSettings` |
| send message | `SendMessagesHelper.sendMessage:4500` (`handlesSendMessage` на `PluginsController.java:1970`) | `EnqueueMessage.enqueueMessages:730` | `.sendMessage` |
| updates | `MessagesController.processUpdates:18269`, `processUpdateArray:18841` | `UpdateMessageService.addUpdates:34`, `UpdateGroup.groupUpdates:211`, `finalStateWithUpdates:917` | `.updates`, `.update` |
| pre/post request | `ConnectionsManager.sendRequestInternal:443` и `:525` | `Network.request:1420`, `Network.requestWithAdditionalInfo:1374` | `.preRequest`, `.postRequest` |
| app event | `PluginsController.init:164`, `LaunchActivity.java:7111`, `:7360`, `:7238` | `AppDelegate.swift:353`, `:2044`, `:2150`, `:2179` | `.appEvent` |
