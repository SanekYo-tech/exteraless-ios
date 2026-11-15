# TL/network — independent review

2026-11-15. **11 findings: 3 P1, 8 P2.** Основание — реальные applied sources.

Review начат на `dcc13004cd296e6e46bb60a0d286283a203e0426`; во время чтения другая сессия передвинула HEAD на `ddc25d696a8a27e63e1e8f6b0bfb2d53ed4a62b8`. Ниже зафиксированы raw-file hashes прочитанного working tree. Полученный от координатора green Linux Host/Hooks receipt: **run 43698196787, dcc13004**. Он не является typecheck/runtime receipt для TelegramCore/TelegramUI. Apple-проверки этих callpaths остаются pending.

Прочитаны `telegram-ios/AGENTS.md`, `telegram-ios/CLAUDE.md`, `docs/tl-shared-integration.md`, `docs/wave-2/tl.md`, `docs/wave-2/tl-schema.md`. Реализация в этой review-сессии не изменялась; результат — этот файл.

Сокращения путей:

- `C/` = `telegram-ios/submodules/TelegramCore/Sources/`
- `U/` = `telegram-ios/submodules/TelegramUI/Sources/`
- `H/` = `swift/PluginHost/Sources/PluginHost/`
- `K/` = `swift/PluginHooks/Sources/PluginHooks/`
- `A/` = `third_party/exteraless-android/TMessagesProj/src/main/`

## P1

### TLN-01 — Post MODIFY может уничтожить encrypted payload при сохранённом qts

**Место:** `C/ExteralessRuntime/TLTransformCodec.swift:37–40,63–88`; вызывается из `TLNetworkRequest.swift:366–389`.

`response` проверяет только `preserveContinuity`. Для неконтрольного по имени поля рекурсия выполняется лишь когда его поддерево содержит `pts/pts_count/qts/seq/seq_start/state/intermediate_state`. У `EncryptedMessage` нет таких полей. Поэтому `new_encrypted_messages` можно удалить целиком или изменить ciphertext, оставив `state.qts` прежним. Это schema-valid MODIFY; исходный TelegramApi parser также принимает его.

**Callpath:** `AccountStateManager.swift:874–900` → Network post transform → `initialStateWithDifference` уже от изменённого ответа → `TLUpdateBarrier.swift:358–380` считает этот ответ оригиналом → `AccountStateManagementUtils.swift:743–752,802–804` записывает новый qts, но не добавляет удалённые secret operations. Следующий difference запрашивается с уже продвинутым qts. Более строгая защита encrypted полей в `tlDifferenceCandidate:315–331` срабатывает слишком поздно.

**Canned repro:** ответ `updates.getDifference` ниже; вернуть MODIFY того же объекта с `new_encrypted_messages: []`, не меняя `state`:

```json
{"_":"updates.difference","new_messages":[],"new_encrypted_messages":[{"_":"encryptedMessageService","random_id":7,"chat_id":9,"date":100,"bytes":{"__bytes__":"AA=="}}],"other_updates":[],"chats":[],"users":[],"state":{"_":"updates.state","pts":10,"qts":11,"date":100,"seq":1,"unread_count":0}}
```

Конструкторы/поля существуют в `TelegramApi/swift_scheme.tl:495,498–499,546`. Ciphertext — неприменяемый к аккаунту тестовый байт. Аналогично post MODIFY способен менять ciphertext внутри `updateNewEncryptedMessage`, сохранив qts; запрет CANCEL у state-hook этого не закрывает.

**Fix/test:** запретить изменение/удаление encrypted и protocol-control поддеревьев уже в post validator, до передачи ответа native caller. Добавить pure codec fixtures для удаления и изменения ciphertext в Difference и Updates, затем native canned replay: исходные secret operations сохраняются вместе с исходными counters. Нельзя считать сохранение численного qts достаточной защитой.

### TLN-02 — Обычный send_text теряет ancestry и создаёт рекурсивные request-hook sends

**Место:** `U/Exteraless/TelegramPluginServices.swift:266–284,357–363`; вход `python/exteraless_runtime/_tl.py:402–407`.

Plain `client_utils.send_text` вызывает старый `Runtime.sendMessage`, а не новый TL text provider. `H/BridgeServices.swift:739–765` создаёт `PluginTextMessageRequest`; этот DTO и `PluginNativeCallLease` не несут TL origin (`PluginServiceModels.swift:207–235`). Перед main-actor/EngineData hops origin не захватывается. В enqueue передаётся **`correlationId: nil`**.

**Repro/callpath:** plugin `alpha` в `pre_request_hook` для `messages.sendMessage` вызывает `client_utils.send_text(peer, "child")` и возвращает DEFAULT. Host установил scope `[alpha]` (`PluginHost.swift:1409–1416,1492–1511`), но указанный send его теряет. PendingMessageManager отправляет child через `Network.requestWithAdditionalInfo` (`C/State/PendingMessageManager.swift:1821,1904`); `TLRequestOrigin.swift:170–198` не находит ни descriptor origin, ни correlation. Hook `alpha` вызывается снова и создаёт следующий child. Depth-32 guard не помогает: каждый раз получается новый root без ancestors.

`enqueueMessagesFromPlugin` обходит только send-message hook; request-hooks остаются активными (`C/PendingMessages/EnqueueMessage.swift:810–813`). Это не эквивалентно causal ancestry. В Android `ConnectionsManager.java:419–454` plugin requests также входят в request chain.

**Fix/test:** захватывать native origin на worker до планирования старого text service и передавать его до correlation leases, либо перевести этот публичный helper на существующий `sendMedia(kind:"text")` provider. Canned test с двумя plugins и fake enqueue/request service: child пропускает `alpha`, вызывает `beta`, unrelated plain send вызывает обоих; ancestor depth не сбрасывается. Никаких реальных sends для reproducer не требуется.

### TLN-03 — Native peer/reference validation пропускает scalar peer IDs в Update/MessageAction

**Место:** `C/ExteralessRuntime/TLTransformCodec.swift:7,98–118,124–150`.

Список protected references неполон: например, нет `inviter_id` и peer-ID vector `MessageAction.users`. Range checks зависят только от типов `User/Chat/Peer/InputPeer/InputUser/InputChannel/MessageEntity`, поэтому `Update` и `MessageAction` с теми же native peer IDs их обходят.

**Canned repro:** исходный `updateChatParticipantAdd(chat_id:1, user_id:2, inviter_id:3, date:100, version:1)`; hook возвращает тот же constructor с `inviter_id:9223372036854775807`. Поменять 3 на другой корректный ID также разрешено, хотя state был инициализирован по прежним references. Schema: `swift_scheme.tl:337`.

`canMutate`/channel eligibility пропускают этот update (`TLUpdatePolicy.swift:22–28,39–42`). `ExteralessTLTransformCodec.update` принимает replacement: constructor, chat_id/user_id и counters прежние, inviter_id — непроверяемый scalar. После parse `AccountStateManagementUtils.swift:1433–1437` передаёт его в `PeerId.Id._internalFromInt64Value`. Реальная декларация `Postbox/Sources/Peer.swift:85–96` содержит assert 56-bit range. **В assertion-enabled native build это crash до replay verifier**; release-сборке утверждение о таком же trap не приписывается, но недопустимый native ID и retarget остаются.

Второй короткий путь: `updateNewMessage.messageService.action.messageActionChatAddUser.users = [Int64.max]`; scalar-array исключение `preserveReferences:111–118` пропускает его, а `C/ApiUtils/TelegramMediaAction.swift:14–16` строит PeerId для каждого элемента.

**Fix/test:** валидировать и сохранять все реально потребляемые peer references по constructor/field role, включая scalar/vector IDs, а не только несколько имён и sum types. Pure replacement fixtures должны отвергать оба примера и положительный retarget inviter_id; native fixture должна подтвердить отказ до `StoreMessage`/state interpretation, с исходным update в fallback.

## P2

### TLN-04 — Выключение subscriptions позволяет fast path обогнать незавершённый prefix

**Место:** `C/ExteralessRuntime/TLNetworkRequest.swift:7–18,26–30,44–51`; `C/Network/Network.swift:1400–1404,1461,1475–1478,1528`.

Submission ticket резервируется только когда **сейчас** включён transform gate. Fast path не учитывает ранее зарезервированные tickets этого account.

**Repro:** подписать A=`messages.readMessageContents`; после pre hook удержать его final Postbox privacy lookup (`TLRequestPrivacy.swift:182–193`). Выключить subscriptions и подписать B того же account. B получает nil из transforming branch и сразу вызывает `requestService.add`; A добавится лишь после окончания lookup. `K/PluginTLSubmissionOrder.swift:27–33,68–84` упорядочивает только владельцев tickets, поэтому порядок становится B,A. Это также может лишить B зависимости от ещё не добавленного A.

Проверка membership внутри холодного Signal сама по себе правильна; дефект — переход с активного ordered prefix на empty-gate fast path.

**Fix/test:** сохранить ordered admission для новых запросов, пока у account есть pending prefixes, атомарно с проверкой/резервированием lane. Native fake-service fixture: held A → subscriptions off → B; ожидать A,B. Дополнительно cancel A до add → только B; другой account продолжает независимо. Существующий `testPrivacyPrefixCompletionOrderCannotReorderNativeAdds` резервирует оба tickets и этот переход не проверяет.

### TLN-05 — Cancel во время pre-enqueue ожидания оставляет origin lease до закрытия аккаунта

**Место:** `C/ExteralessRuntime/TLMediaServices.swift:291–350`; `TLRequestOrigin.swift:62–70,139–149`.

Correlation регистрируется до подписки на `enqueueMessagesFromPlugin`. Cleanup есть для синхронных ошибок подготовки и для полученного массива IDs, а message-view tracker устанавливается только после получения IDs. Disposal ожидающего enqueue не выполняет ни один из этих путей.

**Repro/callpath:** hook-origin text/media send к cached bot; включить native bot authorization и удержать его handler. После `exteralessTLRegisterEnqueueOrigin` отправка ждёт `ExteralessBotSendAuthorization.check` (`C/PendingMessages/EnqueueMessage.swift:938–945`; `C/TelegramEngine/Privacy/ExteralessBotPrivacy.swift:113–130`). Выполнить tlCancel либо дождаться короткого request timeout. Registry disposes signal (`TLRequestRegistry.swift:130–152`), но local message/RPC/view не существовали и correlation остаётся в `pending`. После 1024 таких отмен account упирается в `TL_ORIGIN_QUOTA_EXCEEDED`; unload этого plugin не очищает account store.

Есть и второй window: enqueue transaction уже закоммичен, а subscriber отменён до получения IDs — tracker не устанавливается. Если request hooks затем выключены, завершение/удаление сообщения также не освобождает этот origin.

**Fix/test:** provisional lease должен освобождаться при отмене до commit и передаваться commit-owned tracking после реального enqueue, независимо от клиентского subscriber. Простое удаление origin в каждом `afterDisposed` неверно для уже поставленного сообщения. Два bounded native fixtures: pending authorization + cancel → ноль origins; commit + dispose до next → origin живёт до завершения/удаления сообщения, включая выключенные hooks.

### TLN-06 — SDK закрывает callback, даже когда native tlCancel вернул false

**Место:** `python/exteraless_runtime/_tl.py:240–250`; `python/exteraless_runtime/_callbacks.py:24–28,50–64`.

`Requests.cancel` сначала удаляет pending entry, затем безусловно вызывает `lease.close()` в `finally`. Native false означает в том числе, что completion уже выиграл гонку и его callback ещё стоит в FIFO (`TLRequestRegistry.swift:130–152`; `U/ExteralessClient/TL/PluginTLBridgeExtension.swift:114–123,393–408`). Такой callback должен остаться действительным.

**Выполненный canned repro:** production AST nodes `Requests.cancel`, `Lease.wrap/close`, `CallbackLeases` с fake platform, у которой единственный `tlCancel` возвращает false. Получено:

```text
cancelled=False, lease_open=False, pending=False
callback belongs to a closed plugin generation
```

Это потеря законного терминального callback из-за преждевременного закрытия SDK lease.

**Fix/test:** не pop/close до положительного результата отмены; false сохраняет lease до callback или native `release_handles_json`. Regression: native completion выигрывает, cancel возвращает false, callback доставляется ровно один раз и затем handle освобождается. Проверить также исключение при cancellation dispatch.

### TLN-07 — Rich/reply text и text edit всё ещё обходят новые native outgoing services

**Место:** `python/exteraless_runtime/_tl.py:409–450,474–480`.

`rich_text` делает `getPeer` → raw `messages.sendMessage` через `tlRequest`. Text-only `edit_message` делает raw `messages.editMessage`. `send_request:287–290` не передаёт `applyUpdates`, поэтому `C/ExteralessRuntime/TLNativeServices.swift:43–61,70–83` отдаёт data, но не применяет Updates. Для нового сообщения не создаётся local outgoing message вообще.

**Source repro:** `send_text(42, "**text**", parse_mode="Markdown", replyToMsg=7)` либо text edit с подходящим InputPeer. Следуемая DTO route — `tlRequest`; ветка успешного RPC не вызывает native enqueue/apply-state. Кроме того, message-send permission теперь недостаточно: промежуточный getPeer требует messages.read, а raw request — network.

Исходный high-level путь `A/python/client_utils.py:488–504,507–551,723–767` вызывает `SendMessagesHelper.sendMessage/editMessage`. Handoff также требует native text enqueue (`docs/wave-2/tl.md:688–695`). Текущий SDK fixture `tools/compat/tests/test_sdk_adapter_wave2.py:734–740` закрепляет неправильный raw route.

**Fix/test:** направить rich/reply/scheduled text в существующий `sendMedia(kind:"text")`, text edit — в `editMedia(kind:"text")`, сохраняя presence и scope. Fixtures должны проверять endpoint, native local IDs/Updates и failure path с одной messages.send permission; paid/restricted case не должен обходить native preparation.

### TLN-08 — Изменение Boolean TL field не обновляет его authoritative flags

**Место:** `python/exteraless_runtime/_tl.py:34–43,57–68`; final rejection в `C/ExteralessRuntime/TLCodec.swift:424–459`.

Decode приносит и flags, и Boolean fields. Setter меняет только `_values[name]`, serializer отдаёт старую маску. Например, hook меняет `request.silent = True` на decoded `messages.sendMessage` с flags=0 и возвращает MODIFY. Native mask authoritative, поэтому modification отклоняется, Host продолжает с исходным несilent запросом (`H/PluginHost.swift:1430–1445`).

**Выполненный canned repro** на production `TLObject`, `Schema.decode`, `to_wire`:

```text
FLAG_FIXTURE: silent=True but flags=0; schema=flags.5?true
```

В исходном Java serializer этот бит пересчитывается из Boolean (`A/java/org/telegram/tgnet/TLRPC.java:52827–52838`).

**Fix/test:** синхронизировать `flags.n?true` при mutation/serialization по generated schema, сохранив строгую проверку value-optionals и shared-bit companions. Hook fixture с `silent false→true→false`, flags2 Boolean и Bot shared-bit должен проходить именно native normalization; счётчик следующего plugin должен видеть нормализованное изменение.

### TLN-09 — Existing-media spoiler edit теряет spoiler в fast reference branches

**Место:** `C/PendingMessages/PendingMessageUploadedContent.swift:252–259,303–338`; новый вызывающий путь — `C/ExteralessRuntime/TLMediaEditServices.swift:68–88`.

Для обычного, не hook-origin, `editMedia(kind:"text", spoiler:true)` provider выбирает `.update(.standalone(originalMedia))` и передаёт `MediaSpoilerMessageAttribute`. Но cloud-photo fast branch возвращает `inputMediaPhoto(flags:0, ...)`, а cloud-document branches читают только emoji query/video timestamp. Spoiler attribute не учитывается. Required-upload guard видит nonnil inputMedia и считает seam успешным.

**Repro:** cached cloud photo/document с валидным reference; `kind:"text"`, новая caption и `spoiler:true`. В конечном edit RPC spoiler bit отсутствует (`swift_scheme.tl:33,37`), caption меняется, native `.done(true)` превращается в `{status:"edited"}` (`RequestEditMessage.swift:399–401`; `TLMediaEditServices.swift:97–103`). Это конкретный caption-only success при запрошенном media effect. При неизменной caption возможен `MESSAGE_NOT_MODIFIED` вместо spoiler edit.

**Fix/test:** переносить spoiler intent во все reference branches, включая retry/revalidation, с настоящей message media reference. Canned capture final edit body для photo/document, spoiler on/off и изменённой/сохранённой caption. Для непрезентуемого пути возвращать named failure до RPC. Hook-origin reference refusal `EDIT_HOOK_REFERENCE_UPLOAD_UNSUPPORTED` уже есть и этот обычный путь не закрывает.

### TLN-10 — Entities-only edit отвергается до чтения сохранённой caption

**Место:** `U/ExteralessClient/TL/PluginTLModels.swift:267,169–177`; правильное deferred разрешение уже есть в `C/ExteralessRuntime/TLMediaEditServices.swift:59–66`.

`PluginTLEditMediaModel` повторно использует send model. Если caption отсутствует, тот подставляет `""` и немедленно проверяет entities относительно пустого UTF-16 текста. До Core, где должен использоваться `message.text`, операция не доходит.

**Repro:** cached caption `"ab"`; model `{schemaVersion:1, account:0, peer:{type:"user",id:1}, message:{id:7}, kind:"text", entities:[{_:"messageEntityBold",offset:0,length:1}]}` без caption. Контракт разрешает сохранение cached caption и новое форматирование, но `tlMediaEntities:86–89` отклоняет length=1 относительно length=0.

**Fix/test:** отделить edit presence от send defaults и отложить caption-dependent entity checks до чтения cached message. Проверить entities-only success, out-of-range относительно реальной caption, явно пустую caption и правило «caption supplied, entities omitted → очистить entities».

### TLN-11 — Root Vector response выдаётся как ArrayList, не как Android Vector

**Место:** `python/exteraless_runtime/_tl.py:138–153,171–180,222–228`.

Любой JSON array декодируется как ArrayList; request result type при callback adaptation не используется. `TLVector` лишь добавляет context к list и также не предоставляет `.objects`. Объявления/регистрации `org.telegram.tgnet.Vector` в applied Python sources нет.

**Repro:** `users.getUsers` с canned response `[{"_":"userEmpty","id":1}]`; исходный callback читает `response.objects`. Выполненный production-node fixture: `decoded_root=ArrayList, objects_member=False`. Android `A/java/org/telegram/tgnet/Vector.java:7–44` возвращает TLObject Vector с `objects`; primitive wrappers находятся там же. Контракт закреплён в `docs/wave-2/tl-schema.md:115–119`.

**Fix/test:** различать root result Vector и nested vector fields по объявленному result type; root wrapper должен сохранять TL context и сериализоваться обратно в wire array. Проверить users.getUsers, primitive root vector, post-hook modification и nested field, который остаётся ArrayList. Нынешний SDK fixture `test_sdk_adapter_wave2.py:712–714` проверяет list indexing и не является Android parity oracle.

## Проверенные механизмы и границы доказательства

- **Pre/post ordering:** ветка вставлена внутрь обоих cold Signal generators после weak-self проверки и до privacy. Pre CANCEL приводит к error без add/willSubmit. Operation gate даёт одного terminal winner; completion/ACK/progress идут через private queue, поздние события отсекаются. Обнаруженный переход gate-off описан в TLN-04.
- **FINAL privacy:** `TLRequestPrivacy.swift:154–195` заново декодирует final bytes; side metadata привязаны к слабым Network + FunctionDescription identities. Original descriptor сохраняется только при byte equality (`TLNetworkRequest.swift:247–250`), поэтому explicit-read identity не переносится на replacement. Global contents-read сверяет множество requested/resolved IDs и все peers; consumer `ExteralessPrivacyPolicy.swift:38–61` и `PrivacyPolicy.swift:113–117` не разрешает unresolved IDs за счёт чужого peer exemption. Последний guard стоит непосредственно перед add, willSubmit — после принятого add.
- **Parser/errors/transport metadata:** engine parse по-прежнему вызывает исходный `data.2.parse`; post replacement парсится им повторно. Так сохранена native parse-failure/init-invalidation policy, включая Rust retry handling (`RustNetworkSession.swift:887–930`). RPC error replacement не может произвести success (`TLNetworkRequest.swift:405–418`); code/text и response timestamp/duration/networkType доступны в metadata. Dependency tag, error policy, automaticFloodWait/onFloodWaitError передаются в тот же request service; ACK/progress имеют явный opt-in. Recording wrapper возвращает исходный disposable.
- **Host contract:** actual SDK priorities, descending priority/id tie-break, same captured interpreter handle, permission/owner predicate на worker, normalization между plugins и MODIFY_FINAL читаются в `PluginHost.swift:1308–1447,1485–1518`. Canonical RPC name передаётся явно. Native callback origin хранится по owner+уникальному handle, scheduled callback origin передаётся до main hop. Release проходит общий callback/control FIFO. Это не распространяется автоматически на старый sendMessage service — TLN-02.
- **Accepted live/difference:** UpdateGroup sidecar не дублирует updates/users/chats; оригинальные member objects удерживаются для identity matching. Global acceptance предшествует transform. Channel ledger и interpreter используют один sorted order; cancellation channel update превращается в пустой `updateDeleteChannelMessages` с исходными pts/count. Cancellation распознанных encrypted/control constructors в **state barrier** запрещена. Version recheck присутствует; `AccountStateManager.swift:900–915,1045–1104,1502–1524` сохраняет FIFO и `skipVerification:false`; `verifyTransaction` сохранён. Это не компенсирует более раннюю post mutation (TLN-01) и неполные reference roles (TLN-03).
- **Native short updates:** `UpdateMessageService.swift:79–99` действительно хранит generated fromId/media. `TLNativeSnapshots.swift:13–20` использует настоящие description fields, `TLCodec.swift:325–350` восстанавливает optional presence перед roundtrip. Это source proof; существующий fixture проверяет искусственный dictionary, не реальный generated Api.Message.
- **Upload/edit:** оба основных `uploadMedia` RPC и initial/retry edit RPC передают явный origin; local file edit не заимствует ancestry от другого edit того же MessageId. Upload errors/отсутствующий inputMedia блокируются `RequestEditMessage.swift:115–117,182–184`. Success требует `.done(true)`. Existing reference branches дают отдельный дефект TLN-09.
- **TTL/albums/paid:** cloud TTL не потерян из-за имени attribute: `EnqueueMessage.swift:365–387` преобразует requested Autoremove в Autoclear, а secret сохраняет Autoremove. Native TL preparation проверяет target/type/range TTL, homogeneous album families, 2…10 items/32 MiB, secret negotiated layer, peer restrictions и paid-price cases (`TLMediaServices.swift:154–168,195–279`). Scalar native-value guard за пределами media preparation неполон — TLN-03.
- **Bounds/schema:** codec ограничивает binary 8 MiB, JSON 16 MiB, field 4 MiB, vector 100000, depth 64, total values 200000; счётчик учитывает zero-byte true flags. Проверяются padding, signatures, full consumption, exact integer/finite double, shared flags и unknown fields. Router и Host имеют самостоятельные 256/32-MiB reservations; callback registry держит terminal lease до control admission. Такие component bounds не доказывают peak memory/latency всего native pipeline; Apple stress/terminal fixtures ещё не получены. Отдельный подтверждённый lifetime leak — TLN-05.
- **DNS/Rust transport seams:** прочитаны реальный TCP factory до base capture/WEB override, backup primary source и signed decode, native DNS-SD cancellation, Happy-Eyeballs winner/loser/read ordering, Rust worker IDs/epochs/cache expiry/TTL=0 и stream-generation guards. FFI blocking lookup остаётся на resolver worker; TLS сохраняет serverName/ALPN и системную trust validation; WEB branch сохраняет свой carrier. В этих прочитанных seams отдельного подтверждённого transport finding не выделено. Это source review, не живой DNS/TLS/Telegram test.

### Что реально запускалось

1. `python -B tools/compat/tests/tl_bridge/test_generator.py`, process limit **30 s**: **7/7 PASS, 1.926 s**. Включает byte-for-text generation drift check обоих outputs, native layout hash, schema/alias/flag fixtures. Текущие counts: 1720 constructors, 860 methods / 849 supported, 2402 Android aliases.
2. Один bounded **30 s** in-memory Python AST fixture: production data/lease nodes из `_tl.py`, `_callbacks.py`, `_java_types.py`, generated schema и fake platform. Подтвердил TLN-06/08/11. Дополнительно выявил раздельные class caches для двух id-matched aliases; этот диагностический результат не объявлен самостоятельным finding без более узкого callback-identity oracle.
3. Toolchain discovery: **swift=None, swiftc=None**. Native Swift fixtures/typecheck здесь не запускались. JSON repro TLN-01 и TLN-03 — спецификации коротких regressions, а не заявленные результаты исполнения Swift.

Live Telegram/HTTP/account sends, CI launches и external plugins отсутствовали.

<details>
<summary>Повторяемый loginless Python fixture для TLN-06/08/11</summary>

Из repo root передать этот текст в `python -B -`; использованный внешний process timeout — 30 s. Загружаются только указанные production AST definitions; `install`, SDK loader и plugin code не исполняются. Platform/handle store — локальные stubs.

```python
import ast, base64, json, math, threading, traceback
from pathlib import Path
from types import SimpleNamespace, MappingProxyType
from collections.abc import MutableSequence

ns = dict(base64=base64, json=json, math=math, threading=threading,
          traceback=traceback, Path=Path, MappingProxyType=MappingProxyType,
          MutableSequence=MutableSequence)
ns["RuntimeStateError"] = type("RuntimeStateError", (RuntimeError,), {})
ns["UnsupportedSurfaceError"] = type("UnsupportedSurfaceError", (RuntimeError,), {})

def load(path, names):
    tree = ast.parse(Path(path).read_text(encoding="utf-8"))
    nodes = [n for n in tree.body
             if isinstance(n, (ast.ClassDef, ast.FunctionDef)) and n.name in names]
    assert {n.name for n in nodes} == set(names)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), path, "exec"), ns)

load("python/exteraless_runtime/_java_types.py",
     ["_ClassAccess", "Object", "ArrayList", "Iterator"])
load("python/exteraless_runtime/_callbacks.py", ["Lease", "CallbackLeases"])
load("python/exteraless_runtime/_tl.py",
     ["TLObject", "to_wire", "Schema", "TLVector", "RequestToken", "Requests"])
metadata = json.loads(Path("python/runtime/tl-schema.json").read_text(encoding="utf-8"))
schema = ns["Schema"].__new__(ns["Schema"])
schema.definitions = {r["name"]: r for r in metadata["constructors"] + metadata["methods"]
                      if r["supported"]}
schema.classes, schema.type_bases, schema.aliases = {}, {}, {}
request = schema.decode({"_": "messages.sendMessage", "flags": 0,
    "peer": {"_": "inputPeerSelf"}, "message": "fixture", "random_id": 1, "silent": False})
request.silent = True
wire = ns["to_wire"](request)
assert wire["silent"] is True and wire["flags"] == 0
vector = schema.decode([{"_": "userEmpty", "id": 1}])
assert type(vector).__name__ == "ArrayList" and not hasattr(vector, "objects")

handles, calls = {}, []
class Bridge:
    def xt_register_handle(self, value):
        key = len(handles) + 1
        handles[key] = value
        return key
    def xt_release_handle(self, key):
        handles.pop(key, None)
def call(member, *args):
    calls.append(member)
    assert member == "tlCancel"
    return {"cancelled": False}

platform = SimpleNamespace(owner_token="fixture-owner", plugin_id="fixture",
    check_worker=lambda: None, bridge=Bridge(), call=call)
platform.callbacks = ns["CallbackLeases"](platform)
platform.callbacks.begin()
lease = platform.callbacks.new("tlRequest")
lease.id = "fixture-ticket"
callback = lease.wrap(lambda response, error: None, account=0, terminal=True)
lease.native_owned = True
requests = ns["Requests"](platform, schema)
requests.pending[1] = lease
assert requests.cancel(1) is False
assert not lease.open and 1 not in requests.pending
try:
    callback(None, None)
except ns["RuntimeStateError"] as error:
    assert "closed plugin generation" in str(error)
else:
    raise AssertionError("Expected the current closed-lease failure")
assert calls == ["tlCancel"]
print("Confirmed: stale Boolean mask, missing root Vector.objects, false-cancel closes callback")
```

</details>

### Native compile gap — без вымышленных missing-symbol diagnostics

Проверены фактические объявления: `BoxedMessage` — наследуемый class (`C/State/Serialization.swift:248`); `Disposable: AnyObject` и singleton `EmptyDisposable` существуют (`SSignalKit/SwiftSignalKit/Source/Disposable.swift:3,39–44`); `FunctionDescription` — class, `DeserializeFunctionResponse`/`TypeConstructorDescription` объявлены в `TelegramApi/Sources/DeserializeFunctionResponse.swift`; `Int128` и `Int256` реально есть в `TelegramApi/Sources/Buffer.swift:3,13`. `tlBridgeFunctionDescription` реализован (`TLObjectSupport.swift:185–194`), а текущая UI composition вызывает существующий `services.context(recordId:)`.

Recursive Core/Host/Hooks build globs включают новые sources. Но Foundation contract filegroup (`TelegramCore/BUILD:5–13`) содержит лишь codec/schema/registry; standalone native fixture driver компилирует pure policy helpers, не Network/State/UI adapters. Linux green не закрывает этот Apple integration gate. Подтверждённых отсутствующих symbols по этим декларациям не найдено; перечисленные выше findings основаны на поведении callpaths.

## Source pins

Raw SHA-256, без нормализации CRLF; относятся к working-tree снимку на HEAD `ddc25d696a8a27e63e1e8f6b0bfb2d53ed4a62b8`. Nested Rust base: `da4b2170210aab0430c4ff18c032991f3030cf45` плюс applied working-tree changes. Hash metadata генератора может отличаться от raw hash `.tl` из-за нормализации переводов строк при чтении.

<details>
<summary>TL / applied Core / UI / Host / SDK / original sources</summary>

```text
c22611ed58f5594e27e8087da14f272eabed38e5c5b8306049d224af9c710863  C/ExteralessRuntime/TLCodec.swift
b9d19767d7d9862147d5c142921290a4fd50f28716ff63aa245f94753ba363b5  C/ExteralessRuntime/TLMediaEditServices.swift
e54ebe22855d36a7df8267f7d31969b8db91299500342d570ed199e226c3440d  C/ExteralessRuntime/TLMediaServices.swift
0339c9fb844afffcaa0e13e60c534596e00c52cade417f0e6fd9ac2433ccb49c  C/ExteralessRuntime/TLNativeServices.swift
66b626ee65b45c02462f98b7b4c7d7ebd914e3b4423cd51c6c089d3db0afeacf  C/ExteralessRuntime/TLNativeSnapshots.swift
a51236c295526fc23eb80507deb225e25c594e83cc08a11eb024f18a503f5ea9  C/ExteralessRuntime/TLNetworkRequest.swift
193c65244b730482a992afad4f08f12a14251d4b3371605259e29ceac8355d24  C/ExteralessRuntime/TLRequestOrigin.swift
44723a38b3a7a47eb8b0550b38405359537a0011a0f3f2abc773a1bf89a72361  C/ExteralessRuntime/TLRequestPrivacy.swift
72a1802822809abc9d7e02e971bff98fdb1158578b43f9ed94e69fbc131d6620  C/ExteralessRuntime/TLRequestRegistry.swift
494428b67c12c23478afcd8f971959253703fee65e0bc3d8bc8a5ad101df0cf9  C/ExteralessRuntime/TLSchemaGenerated.swift
c88c708e2abe0054500b048a927d0f8906f62efda97d8b64df09742bd92d1964  C/ExteralessRuntime/TLTransformCodec.swift
0a11a08a9d90e5aa05f1e1e0814d39cfe4cbcabc1e329badc19c32470a9d730c  C/ExteralessRuntime/TLUpdateBarrier.swift
a9cc84d7a51b01cda2201ea7b17898a2aad941fa930626bd649ef3b1d31dacfc  C/ExteralessRuntime/TLUpdatePolicy.swift
0b01e37edc69c0f8c1aea20a35774940e5186d224c78f21258840f4ce2a03769  C/Account/Account.swift
62dd8ded54d5aa6a67a25781df003a0580c8965e052e6bf7d23e5fdbc1b079c3  C/Network/Network.swift
c296a3c94e75da7050fc099690988db5e5c8bdc8c0a570879ca4ed3e7aa7ae1b  C/PendingMessages/EnqueueMessage.swift
6d7fc788131c17a91434b47bf51e3818243e0b345b7f95e7850a678a70a5b409  C/PendingMessages/PendingMessageUploadedContent.swift
ea11a029a8946b4944fe8bc01b0f20d1c79c7568e46dd5d1f54a0bed50397541  C/PendingMessages/RequestEditMessage.swift
a9e51176fe6ed4ec232f80a03b90419ad6e523e6785aee09a923c423f4b4ad88  C/State/AccountStateManagementUtils.swift
125459ae610b05753c9ecd72a5be3854a8ee2516867ba26b85e0fd06df4ce39e  C/State/AccountStateManager.swift
bd1f7d1323c11ee01a4c981318fd5550dbce1de24a7f2b87c8e00b37c142a067  C/State/ExteralessOutgoingPrivacy.swift
02b546e14c9858e134f29d60eb9c3b592471728275b19da109b18a0d4e1b5c42  C/State/ExteralessPrivacyPolicy.swift
e5fd04ed9a3d11f615d9eee5f17fa184768fa1c51ced79103b0068f1ffbc92c2  C/State/PendingMessageManager.swift
6180255b0a28aa09e6dfe95c329f938255189551a10798afe3b94d2a03347e36  C/State/UpdateGroup.swift
54a59c42aba591bc9c2963c15b594823ed869fccf473b9c0e557ca961226ff16  C/State/UpdateMessageService.swift
0f70d82e30d864df0698b5062277806a4fc6b03623301f54ea980d87361ba21a  U/Exteraless/ExteralessPluginRuntime.swift
8d2ae89632b702b9dfe62aa5e8a48407be163bfffae813081177bb587d70ee1f  U/Exteraless/TelegramPluginServices.swift
1e68e32adc383e9b2cc93c5b4f7923a4a87074584c4bd084eb2f87dc2168e873  U/ExteralessClient/TL/PluginTLBridgeExtension.swift
ad8f0818e11dde7e9c860f3d3064a5702cc0633ba69bd3663669d0da91d0b8fc  U/ExteralessClient/TL/PluginTLMediaPreparation.swift
dd1546c1482d92e09b198e19207d62b69fc2f61926104f2bbf1878c891fcc47b  U/ExteralessClient/TL/PluginTLModels.swift
c42e7ad4815c3e380ae07b34c95fd455c3c01ee88637121f2d98a78a8729813b  U/ExteralessClient/TL/PluginTLObservationCodec.swift
2d721b6c8594e1fe4c0f882faf732e11d0b82cfba7990c83fd8255886a2e9857  U/ExteralessClient/TL/PluginTLTransformIntegration.swift
d866530403ba8a3edd590f15bf5f7c94cc406cae5a39226cd3405b91a6c7011f  K/PluginTLSubmissionOrder.swift
9156d7eaa848e1f26848f2710a42551456e84244e5e138cafddcb87d7db11769  K/PluginTLTransform.swift
d59b6d90607a974b92d7e2f3eb1638c9c9bc36c56069e7fbbdae18446ebde7d7  K/PluginTLTransformRouter.swift
e8f707dc7b4f38a76876d4eb846ecce1da067a5ac61f30d835d9e60820738711  H/BridgeServices.swift
d5b07cc23421a8ac131bb3fdca82598d33891cf7f6fc9409f8285a063e17eb0f  H/ExtensionPoints.swift
7cccd1c47193d3b07fe62cbb0c5006fd2bf207046808df6700c51fc60d33b651  H/PluginCallbackDispatcher.swift
de12a551304fc7e7391ba7e1c17b846f54852f1db219387036584ca2189483c6  H/PluginEventQueue.swift
1484a3be2f031557018f08081031c2d2d95c0d48fae7438b82c16305c29be39b  H/PluginHost.swift
bb5e47a1e9d69751bd87eb1a6132004dbac21ea6ba0b77cbc7cd977a8a0a2231  H/PluginServiceModels.swift
e3935c527f2ed969ebd1898bdf85b817454563b504532216e508953498b96d76  H/PluginTLHostPayload.swift
95597ed103ef96c59a5217fc453c2524d7a97858fa8277e588742e382284b667  H/PluginTLInvocationOrigin.swift
fc344c361bb8a6ffa70d1fbe673e0ff5c62247925229611681a8c4d6faafd17f  python/exteraless_runtime/__init__.py
70497a280c5ebc081e662fc72c656bb907df721981c19e2929f7c815e638c481  python/exteraless_runtime/_callbacks.py
f833e043d5321c7479ba1fa95d58b3c316a34d754aba8a3c40d2a59406a495dd  python/exteraless_runtime/_tl.py
12e0e8df111c43f6ee553f7b668c92cbaa5efc2eceb65589a52dd5b661635dc2  python/exteraless_runtime/_java_types.py
e02140d484cabcafbaa0545a017c5be9f6904c74ab0a9e74c3848af8b7ecd221  python/runtime/tl-schema.json
ef74516887b15653d7b970b99b69966b0f49700b2f4cfdba9c10c4f5b455ec5a  telegram-ios/submodules/TelegramApi/Sources/TLObjectSupport.swift
4b67ac34ce795e08a897b8ab3c764c664994f72265971c5ad1cf09680ee4b3a2  telegram-ios/submodules/TelegramApi/swift_scheme.tl
274fe30b01f5a57d09c93a305f29af0a5a024102f3a79a16e87630977536f694  tools/compat/generate_tl_bridge.py
a7605153677483271c3a602129985fd9f2514bfad22f77e182e0f5089464723a  telegram-ios/submodules/Postbox/Sources/Peer.swift
60e53d9fa32a1b1ba47897467077cf22fcdc0458c20b646a35c75fb76484209b  telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Disposable.swift
768c26015ce7338cacfe83216e5e539906fd73880f07c2241a518c91d53eb82c  telegram-ios/submodules/TelegramApi/Sources/Buffer.swift
8f9b797e90027e371f81e8b59d5846b2268c09b1caa111676f915cdfd28a2274  telegram-ios/submodules/TelegramApi/Sources/DeserializeFunctionResponse.swift
3fde763f0c7ed59045b0662b6c344264fce95008f1b8a4fc17d87f92c68de3c2  C/ApiUtils/TelegramMediaAction.swift
c6edfd85e0b0d328f8c2d25ad4451b4c25ab9aea86ea80d7d05f934984f05dda  C/TelegramEngine/Privacy/ExteralessBotPrivacy.swift
e938fcb540015f6e1901c4b96357392837dbc9bce187b4bc2eafcd499e172ac4  swift/ExteralessCore/Sources/ExteralessCore/PrivacyPolicy.swift
2bcddbaf03cc67bf8fb8a2bd3019000804103396c03d6a8112ddc9afb262d462  tools/compat/tests/tl_bridge/test_generator.py
27173a37a8d38e0659f972e5bc69ace0590ef3a809b693bcad1ed388d5b830a4  tools/compat/tests/tl_bridge/NativeFixtures.swift
9edacd94dc4869271edfa0b080bc9d01a1804d040d36bc4a4e836a1e7c3712b7  swift/PluginHost/Tests/PluginHostTests/PluginTLHostTests.swift
a14a84d489ca5e6fb575c455cb4831fc04de9f73c5496c4a35c24b2d22b2a72f  swift/PluginHooks/Tests/PluginHooksTests/PluginTLTransformTests.swift
e8e1ab9b0517b4de9b1b1bdcbff938e87c677e7b76f3edcac53c348266601595  A/java/app/exteraless/plugins/PluginsController.java
efabedf13374686802db37f292ec62f781b404b04f8390db692ffca9f0f626be  A/java/org/telegram/tgnet/ConnectionsManager.java
86692ba869c36e8f96bb0ae33b9cd33f73ab810deff68bb9e3fc8bd3f68eec75  A/java/org/telegram/tgnet/TLRPC.java
b587a58fa7525d062d1602e3289bed35d3d41e8b50e23116ca7d72b9fa99d824  A/java/org/telegram/tgnet/Vector.java
25a85112e3be4d6afbbedf42c405f91cd2ee373c2a7735b9329cc664a410843b  A/python/base_plugin.py
689c05722c691c767ba34f9187c468dd3f29b4d99414560caa60e35b4b528d88  A/python/client_utils.py
```

</details>

Transport corpus pin: **22 files**, SHA-256 `72bcaa4bc547b6606d5b62e6d2eead0f13202fd4b57d062a13de437607507908`. Формула: отсортированные полные repo-relative POSIX paths, для каждого `path + NUL + raw_sha256_hex + LF`, затем SHA-256 UTF-8 конкатенации. Состав:

- `C/ExteralessNetwork/*.swift` (6);
- `swift/ExteralessCore/Sources/ExteralessCore/NetworkResolver*.swift` (4);
- `telegram-ios/submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTAppNetworkResolver.h`;
- `telegram-ios/submodules/MtProtoKit/Sources/{MTAppNetworkResolver,MTBackupAddressSignals,MTContext,MTDiscoverConnectionSignals,MTTcpConnection}.m`;
- `telegram-ios/submodules/MTProtoRustEngine/Sources/MTProtoRustEngine/{RustEngineRuntime,RustNetworkSession,RustStreamHost}.swift`;
- `telegram-ios/third-party/mtproto-engine/crates/mtproto-engine/src/{resolver,session_runtime,worker}.rs`.
