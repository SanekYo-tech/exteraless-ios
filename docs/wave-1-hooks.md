# Wave 1: PluginHooks — handoff координатору

## Граница и регистрация

`swift/PluginHooks` — Swift 6, Foundation + собственный C11 atomic gate;
Telegram/SwiftSignalKit/UIKit/PluginHost/CPython зависимостей нет. Публичный API:

```swift
PluginHookRouter.hasSubscribers(_ kind: PluginHookKind) -> Bool
PluginHookRouter.attach(
    _ handlers: PluginHookHandlers,
    subscriptions: Set<PluginHookKind> = []
) -> PluginHookRegistration
registration.updateSubscriptions(_ kinds: Set<PluginHookKind>)
registration.detach()

PluginHookHandlers(
    sendMessage: (@Sendable (PluginSendPayload, @escaping @Sendable (PluginSendResult) -> Void)
        -> PluginHookCancellation?)? = nil,
    observe: (@Sendable (PluginHookObservation) -> Void)? = nil,
    diagnostic: @escaping @Sendable (PluginHookDiagnostic) -> Void = /* NSLog */
)
PluginHookCancellation(_ action: @escaping () -> Void)
cancellation.cancel()

PluginHookRouter.interceptSend(
    _ payload: PluginSendPayload, timeout: TimeInterval = 5.0,
    completion: @escaping (PluginSendResult) -> Void
) -> PluginHookCancellation?
PluginHookRouter.observe(
    _ kind: PluginHookKind, makeEvent: @escaping () -> PluginHookObservation
)
PluginHookRouter.reportDiagnostic(_ diagnostic: PluginHookDiagnostic)
```

Kinds: `.sendMessage`, `.preRequest`, `.postRequest`, `.update`, `.updates`.
Их rawValue — bit masks; отображать host ExtensionPointKind явным switch,
не преобразованием rawValue.
Один adapter на процесс; fanout плагинов остаётся в `PluginHost.events`.
**Удерживать registration**: deinit снимает регистрацию. Новая `attach` заменяет
старую; старый token не может выключить новую. Публиковать subscriptions из
актуального host gate после load/unload/enable/disable/watchdog/stop, включая
пустое множество. Сам факт работающего host не означает наличие подписчиков.
Kinds без соответствующего handler автоматически остаются выключенными.

Пустой gate — один atomic load статического C-хранилища, без создания Swift
registry/очередей, JSON, payload, Task или actor. Врезки проверяют его первыми.
Handlers thread-safe: роутер вызывает их на своих очередях, не на main.

`accountRecordId` всюду **Int64 = AccountRecordId.int64**. Coordinator отображает
его в host `account: Int32` через реальный registry аккаунтов; cast/clamping/
truncation не являются mapping. `peerId` — **PeerId.toInt64() с namespace**, не
Android dialog ID и не голый Telegram user ID. Неизвестный аккаунт — DEFAULT
для send / пропуск observational event с диагностикой adapter-а.

## Send: рабочий префикс и codec

В `EnqueueMessage.swift` первая проверка публичного `enqueueMessages` стоит до
media transformation и Postbox transaction. Каждый элемент batch обрабатывается
по порядку, затем все принятые элементы передаются существующему enqueue.
`CANCEL` убирает только этот элемент: выход `[MessageId?]` сохраняет исходные
размер/индексы с `nil` на отменённых позициях. Полная отмена даёт `.single([nil…])`.
При disposal ожидание прекращается, отменяется host task и поздний callback
игнорируется. После начала обычной транзакции действуют стандартные гарантии
SwiftSignalKit/Postbox; уже принятый send нельзя отозвать задним числом.

Enabled send асинхронный, callback максимум один. DEFAULT без подписчиков
синхронный и без operation object. Timeout максимум 5 s **на элемент** (конечные
положительные меньшие значения разрешены); deadline не зависит от очереди
handler-а. Timeout/detach/отключение send subscriptions дают `keepOriginal` и
диагностику, cancel/dispose подавляет callback. Host cancellation idempotent и
вызывается с отдельной очереди; adapter возвращает `PluginHookCancellation {
task.cancel() }`. Уже исполняющийся callback невозможно отозвать.

`PluginSendPayload.jsonString()` кодирует прямой объект params (не TL):

| Поля | Тип / смысл |
|---|---|
| `schemaVersion` | Int, 1 |
| `accountRecordId`, `peerId` | Int64, идентичности выше |
| `messageIndex`, `messageCount` | Int, индекс с нуля и исходный размер batch |
| `kind`, `text` | `message` / `forward`; String? |
| `silent`, `disableLinkPreviews` | Bool, текущие supported attribute flags |
| `canModifyText` | Bool, проверенная в Core возможность заменить текст |
| `hasMedia`, `hasTextEntities`, `hasInlineStickers`, `hasRichText` | Bool |
| `attributeTypes` | [String], только имена native типов; не сериализованные значения |
| `threadId`, `localGroupingKey`, `correlationId` | Int64? |
| `replyToMessageId`, `forwardSource` | `{peerId: Int64, namespace: Int32, id: Int32}`? |
| `hasReplyQuote`, `hasReplyInnerSubject`, `hasReplyToStory` | Bool |
| `scheduleTime`, `scheduleRepeatPeriod` | Int32?, read-only |

Optional nil поля при encode отсутствуют. Все поля, кроме трёх ниже, read-only.
Результат handler-а: `PluginSendResult.keepOriginal / cancel /
modify(PluginSendMessagePatch) / modifyFinal(PluginSendMessagePatch)`.
`PluginSendMessagePatch.init(text: String? = nil, silent: Bool? = nil,
disableLinkPreviews: Bool? = nil)` — sparse patch к **исходному** EnqueueMessage.
Параметры Enum, reply/quote, media, grouping, correlation, inline stickers и
неизвестные attributes сохраняются; у двух supported flags сохраняются прочие
биты. Текст меняется только у plain message без media/entities/rich/opaque
attributes, пустая замена отклоняется. Флаги поддержаны для `.message` (включая
media); изменение forward params отклоняется.

```swift
try PluginSendResultCodec.decode(_ json: String, original: PluginSendPayload)
    -> PluginSendResult
PluginSendResultCodec.decodeOrKeepOriginal(_ json: String, original: PluginSendPayload)
    -> PluginSendResult // diagnostic + DEFAULT при ошибке
try PluginSendResultCodec.validate(_ patch: PluginSendMessagePatch, original: PluginSendPayload)
```

Wire: `{ "strategy": "DEFAULT|CANCEL|MODIFY|MODIFY_FINAL", "params": {...} }`.
MODIFY требует params. Разрешены sparse params или полный echoed snapshot с
неизменными read-only полями. Неизвестное поле (`entities`, `media`, …), попытка
сменить peer/account, неверный тип или неподдержанный text edit отклоняют **всю**
модификацию; `decodeOrKeepOriginal` диагностирует отказ. Int64 не проходит через
Double/Int32. Router повторно валидирует typed результаты, минующие JSON.

Coordinator должен доставить **strategy вместе с params**, а не старый
`preSendMessage -> HookStrategy`, терявший тело. MODIFY_FINAL останавливает
цепочку на стороне host; в Core применяется та же полная sparse patch.

### Plugin-origin native effect: обход send hooks

```swift
public func enqueueMessagesFromPlugin(
    account: Account, peerId: PeerId, messages: [EnqueueMessage]
) -> Signal<[MessageId?], NoError>
```

Публичный entry в `EnqueueMessage.swift` напрямую передаёт аргументы в
`enqueueMessagesWithoutPluginHooks`: применяется обычный media/Postbox/outgoing
pipeline. Это explicit native effect плагина; permissions проверяет
`BridgeServices` до входа. Coordinator подключает к этому entry native
`Runtime.sendMessage` / `TelegramPluginServices.sendMessage`.

**Подавляется вся цепочка send-message hooks всех плагинов**, что предотвращает
рекурсивный вход и повторные hook effects при отправке из `on_send_message_hook`.
Пользовательские отправки входят в обычный `enqueueMessages` с перехватом.
Граница bypass — send-message hooks: RPC/update observations используют свои
обычные gates. Исходная пользовательская отправка определяется результатом её
hook; новый native effect сам по себе не отменяет её и не дедуплицирует повторные
вызовы native API.

## RPC / updates: observational

`PluginHookObservation` cases: `preRequest(PluginRequestObservation)`,
`postRequest(PluginRequestObservation)`, `update(PluginUpdateObservation)`,
`updates(PluginUpdateObservation)`. `event.kind` и `try event.jsonString()`
доступны adapter-у; JSON содержит associated payload напрямую. `Data` кодируется
base64, не hash/description. **Все эти payload имеют schemaVersion=1,
observational=true** и не имеют канала возврата CANCEL/MODIFY.

- Request: `phase` = `beforeSubmission|completed`; `metadata` =
  `{accountRecordId:Int64, requestId:String, requestName:String, datacenterId:Int,
  automaticFloodWait:Bool, usesAdditionalInfo:Bool}`. `requestId` создан при
  подписке на cold Signal; pre/post используют один ID. Остальные поля:
  `serializedTLBytes:Data?`, `tlBytesEncoding`, `responseTypeName:String?`,
  `response:{timestamp:Double,duration:Double,networkType:Int32}?`,
  `error:{code:Int32,message:String}?`.
- Update/container: `accountRecordId:Int64`, `name:String` (schema constructor),
  `source:incomingContainer|difference|acceptedUpdateBatch`,
  `stage:beforeGrouping|beforeDifferenceApplication|beforeUpdateApplication`,
  `serializedTLBytes:Data`, `tlBytesEncoding:boxedTL`, `batchIndex:Int?`,
  `batchCount:Int?`.
- Encoding: `requestBody` — существующий API Buffer до MTProto framing;
  `responseBody` — исходный Data, поступивший parser-у после MTProto/gzip;
  `boxedTL` — настоящий `serialize(buffer, true)`, не исходный сетевой packet;
  `unavailable` — байт нет. Успешные primitive/vector ответы тоже имеют
  responseBody, если post gate был открыт при parse. Parsing/RPC failure не
  фабрикует TL; metadata/error доступны. При включении post после parse есть
  fallback boxedTL только для `TLObjectBacked`.

Оба `Network.request` и `requestWithAdditionalInfo` используют общие observer
helpers; success/error/verification-error и обычные terminal events сохранены.
Ack/progress и retry policy сохранены. Network хранит исходный record ID и
передаёт его `UpdateMessageService` до публикации sink.

Container hook — `UpdateMessageService.addUpdates` до grouping (socket и
AccountStateManager); difference container — `finalStateWithDifference` до
применения. Single update — **только общий** `finalStateWithUpdates`: accepted
live + difference.otherUpdates, после continuity filtering, до интерпретации.
В groupUpdates второго hook нет, поэтому live update не дублируется. Snapshot
не означает commit: actual callback может исполниться после изменения state.

TL serialization и factories выполняются на отдельной serial observation queue,
не на network/postbox очередях. Лимит 256 pending observations на регистрацию;
overflow даёт diagnostic и отбрасывает только observation. Отписка подавляет
ещё не начатые callbacks. Нет ожидания plugin, semaphore или изменения pts.

## Bazel — build-agent

Потребитель Core: `//submodules/TelegramCore:TelegramCore` →
`//third-party/exteraless:PluginHooks` → `@exteraless//swift/PluginHooks:PluginHooks`.
Coordinator в TelegramUI импортирует тот же PluginHooks через этот alias.
Сам `@exteraless//swift/PluginHooks:PluginHooks` **требует `:CPluginHookShims`**:
module name `CPluginHookShims`, C11 source
`Sources/CPluginHookShims/PluginHookGate.c`, header
`Sources/CPluginHookShims/include/PluginHookGate.h`, includes этот include dir,
`-std=c11`, modules enabled (по образцу CPluginHostShims). CPython deps нет.
Одна копия gate/registry должна жить в TelegramCoreFramework; TelegramUI
использует его экспорт, а не вторую статическую копию. BUILD/MODULE здесь не
редактировались.

`telegram-ios/submodules/TelegramCore/Package.swift` также объявляет local package
`../../../swift/PluginHooks` и product `PluginHooks`; минимальный macOS самого
lightweight package сохранён 10.13, как у Core.

## Проверки и реальные границы

`git diff --check` четырёх изменённых Core-файлов завершился успешно; в новых
Swift/C/header/doc файлах trailing whitespace не найден. Это статические проверки.
Swift/clang локально не найдены. 16 SwiftPM tests добавлены как чистые fixtures,
но **не запускались**; full app build и runtime/account/network не запускались.
Нужен `swift test --package-path swift/PluginHooks` на доступном Swift 6 host.

Send охватывает публичный enqueueMessages; resendMessages, welcome templates и
прямые внутренние transaction-вызовы обходят hook. Media/rich/entity rewriting,
смена peer/thread/reply/schedule не поддержаны. Packet-level RPC/pts mutation
не поддержаны. Download/multiplexed/engine-internal RPC идут вне двух Network
методов. Channel-difference отдельного контейнера здесь нет; newMessages в
обычном difference видны в container, не синтезируются как фиктивные Api.Update.
Post не выдаётся для request, который стартовал с обоими request gates закрытыми,
или был disposed до ответа. Observation delivery best-effort, не state barrier.
