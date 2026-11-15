# TLN-01–11 — focused source closure

2026-11-15. **Исходные 11 counterexamples закрыты в source. Найдены два новых P2 на пересечении validators; новых P1 нет.** `CLOSED-SOURCE` ниже относится к конкретному исходному дефекту. Native Apple execution и full parity этим verdict не подтверждаются.

Основание: `tl-network.md`, `../tl-review-remediation.md`, `../tl-text-origin-remediation.md`, `../sdk-tl-remediation.md` и фактические sources/consumers. Исходный report сохранён. HEAD при начале follow-up: `0ceafb7bc7c12774f40fcb9f4947e593c05aab0b`; при фиксации pins: `ffdb2833d68bbb7c0f51e684f109a494999a8e21`. Между ними работали другие сессии; pins ниже фиксируют конкретные файлы.

Пути относительно repo root:

- `C/` — `telegram-ios/submodules/TelegramCore/Sources/`
- `U/` — `telegram-ios/submodules/TelegramUI/Sources/`
- `H/` — `swift/PluginHost/Sources/PluginHost/`
- `K/` — `swift/PluginHooks/Sources/PluginHooks/`
- `P/` — `python/exteraless_runtime/`

## Проверка applied integration

| Packet / seam | Фактический результат |
|---|---|
| `tl-review-network.patch` | **11/11** уникальных exact-line postimages найдены в текущем `TLNetworkRequest.swift`. Reservation, private/no-event branch и `canCancelResponse` действительно подключены. |
| `tl-review-enqueue-commit.patch` | **Все пять смысловых insertion points сохранены** после Chat typed-result refactor. Legacy array API → `enqueueMessagesFromPluginWithAdmission` → общая authorization/media/transaction implementation. `tlCommit` передаётся на каждом переходе (`EnqueueMessage.swift:814–821,944–967`). |
| `tl-execution-guard-integration.patch` | **4/4** уникальных exact-line postimages: Runtime callback forwarding, обе Network fast paths и ordered final add. Последний проверяет исходный и final descriptor перед body-aware privacy guard (`TLNetworkRequest.swift:293–302`). |

`EnqueueMessagesResult` оборачивает результат той же transaction. `allowsContinuation` стоит после bot authorization, `beginCommit` — внутри transaction до privacy/reply rewrite и inserts (`EnqueueMessage.swift:946–974`). Postcommit NativeServices publication возвращает прежний typed result (`:1001–1007`), поэтому committed ID не превращается в cancellation после записи.

## Verdict по исходным findings

| Finding | Source verdict и доказательство |
|---|---|
| **TLN-01 / P1** encrypted payload при неизменном qts | **CLOSED-SOURCE.** `TLTransformCodec.response:104–110` проверяет protocol subtrees до выдачи bytes исходному parser. `hasProtocolSubtree/preserveProtocolSubtrees:128–154` обнаруживает inserted/deleted/reordered encrypted nodes и требует полного equality protocol payload. `TLUpdatePolicy:7–18` включает EncryptedMessage/Chat/File, encrypted/control updates и другие явные protocol types. `canCancelResponse:122–124` подключён в `TLNetworkRequest:390`; state member matching вызывает тот же protector (`TLUpdatePolicy:76–102`), Difference CANCEL проверяет обе semantic vectors и encrypted emptiness (`TLUpdateBarrier:315–319`). Исходный `new_encrypted_messages=[]` теперь отвергается до replacement parse. |
| **TLN-02 / P1** legacy text теряет ancestry | **CLOSED-SOURCE.** `H/BridgeServices.swift:762–766` синхронно захватывает native scope по C-owned plugin/token; `PluginTLInvocationOrigin.swift:47–63` отказывает несовпадающему, закрытому и depth-limited scope. DTO имеет immutable `origin` (`PluginServiceModels.swift:207–226`). Реальный consumer `U/Exteraless/TelegramPluginServices.swift:374–390` передаёт его в общий `exteralessTLSendText`, затем `TLMediaServices:292` → `TLRequestOrigin:231–261` резервирует correlations до enqueue. Main/EngineData hops больше не создают новый root. Ordinary nil-origin остаётся nil. |
| **TLN-03 / P1** unchecked inviter/users peer IDs | **CLOSED-SOURCE для исходных inviter/vector counterexamples.** Явные constructor/field roles включают `inviter_id` и `MessageAction.users` (`TLTransformCodec:12–69`). Проверяется фактический native диапазон `[-0x007fffffffffffff, 0x00ffffffffffffff]` без `abs(Int64.min)` (`:236–246,292–321`); opaque file/document/random IDs не получают такой диапазон. `referenceShape` защищает роли, включая optional subtrees и positions vectors (`:204–233`), поэтому также отвергается положительный inviter retarget `3→4`. Новые пересечения этого protector — **TLN-F01/F02** ниже. |
| **TLN-04 / P2** gate-off обгоняет prefix | **CLOSED-SOURCE.** `K/PluginTLSubmissionOrder.swift:38–47` проверяет gate и наличие lane и резервирует ticket под одним lock. Head остаётся видимым до возврата `add` (`:94–106`). Обе Network generators вызывают adapter при subscription (`Network.swift:1398–1407,1479–1488`); adapter делает `reserveIfNeeded` даже при выключенных transforms (`TLNetworkRequest:33–59`). Gate-off follower ждёт A, cancel A освобождает слот, другой account может bypass. Private requests могут ждать без decoder/plugin events (`:192–196`). |
| **TLN-05 / P2** provisional correlation leak | **CLOSED-SOURCE.** `TLRequestOrigin:234–251` резервирует correlations в cold subscription и создаёт один `ExteralessTLEnqueueCommit`. Provisional disposal освобождает correlations и native authorization/preparation subscription (`TLEnqueueCommit:64–79`). Claimed commit сохраняет native completion; `complete(track:)` выполняет tracking до проверки client delivery (`:48–61`). `exteralessTLRetainedEnqueue:203–226` остаётся подписанным после client disposal, а `:252–259` устанавливает настоящий Postbox view либо освобождает rejected slots. Это покрывает оба исходных окна: до commit и commit-before-next. Typed wrapper и оба permit checks реально присутствуют. |
| **TLN-06 / P2** false cancel закрывает callback | **CLOSED-SOURCE.** `P/_tl.py:351–364` делает lookup, не pop; только настоящий Bool true закрывает lease. False, malformed reply и exception оставляют его completion winner. `submit:326–349` использует identity-checked removal и не публикует уже закрытый early-completion lease. `P/_callbacks.py:50–64,94–106` сохраняет native-owned handle до control release. Tiny production-node fixture ниже проверил false/throw/malformed/true и single release. |
| **TLN-07 / P2** high-level rich/edit идёт raw RPC | **CLOSED-SOURCE.** `P/_tl.py:523–549` строит `sendMedia(kind:"text")`; `:571–589` — `editMedia(kind:"text")`. `native_media:467–492` требует messages.send и вызывает выбранный native endpoint; getPeer/raw-request detour отсутствует. `U/.../PluginTLBridgeExtension.swift:294–301,376–396` подключает реальные Core services с origin/execution predicate. Core text проходит общий enqueue/Updates path; text edit — `_internal_requestEditMessage` (`TLMediaEditServices:127–146`). |
| **TLN-08 / P2** Boolean не меняет flags | **CLOSED-SOURCE.** Setter вызывает `_boolean_masks`, и serializer повторяет его (`P/_tl.py:36–50,59–77,87–96`). Переписываются только bits `?true`; чужие/unknown bits, value-optionals и shared companions сохраняются для строгой native проверки. `silent false→true→false`, flags2 и сохранение/отсутствие `bot_info_version` подтверждены tiny fixture. Native mask/shared-bit rejection остаётся в `C/.../TLCodec.swift:424–459`. |
| **TLN-09 / P2** reference spoiler теряется | **CLOSED-SOURCE.** Photo/document fast builders теперь используют `exteralessTLReferencePhotoInput/DocumentInput` (`TLMediaEditServices:6–15`; `PendingMessageUploadedContent:257–274,323–367`). Bit выставляется и очищается по attributes; retry использует тот же builder. Edit хранит настоящую `MessageReference` (`TLMediaEditServices:106–124`), передаёт её uploader (`RequestEditMessage:70`); photo force-revalidation больше не возвращает прежний reference без попытки (`PendingMessageUploadedContent:263–271`). Перед RPC проверяются nonnil uploaded input и его actual spoiler (`RequestEditMessage:186–193`). Неподдерживаемые live-photo/video-cover reference cases получают named failure; success требует `.done(true)`. |
| **TLN-10 / P2** entities-only проверяется по пустой caption | **CLOSED-SOURCE.** `PluginTLModels.swift:271` включает defer только при отсутствии caption; `:177–180` делает schema/native-range check с `caption:nil`. Core `exteralessTLResolveEditText:60–69`, вызываемый в `TLMediaEditServices:96–100`, проверяет UTF-16 относительно cached text. Явные `caption:""`, отсутствующие entities и полностью omitted caption/entities сохраняют разные значения. |
| **TLN-11 / P2** root Vector без `.objects` | **CLOSED-SOURCE для исходного callback representation defect.** Зарегистрирован настоящий SDK data surface `org.telegram.tgnet.Vector` и Int/Long wrappers (`P/_tl.py:139–142,243–301`). `Requests.submit` фиксирует declared result type, `decode_response` оборачивает только root (`:213–222,318–336`); nested fields остаются ArrayList. Post dispatch передаёт canonical request name в `hook_value` (`P/__init__.py:313–317`), context остаётся read-only. Source serialization переводит `.objects` обратно в wire array (`_tl.py:80–96`). Отдельный native post-mutation join ещё содержит **TLN-F02**. |

### Legal lifetime / execution пересечение

TL provider теперь захватывает `PluginNativeExecutionContext.captureGuard()` до native/main hop и хранит guard в ticket (`PluginTLBridgeExtension:212–240`). `nativeCancellation:255–258` передаётся в real text/media/album/edit/query/RPC routes; common enqueue checks получают именно его. Legacy text отдельно использует common `PluginNativeCallLease` и опубликованную AccountContext identity (`TelegramPluginServices:281–300,383–389`).

Ownership не зависит от execution predicate: `TLRequestRegistry.contains/complete/cancelRetainingLease:134–178` работает по ticket identity, освобождает native resources после unlock и сохраняет completion quota. Queued successful callback проверяет `ticket.permitsExecution`, **не** удалённую registry membership (`PluginTLBridgeExtension:465–479`); release остаётся на FIFO (`:515–520`). Claimed enqueue завершает tracking после revocation/dispose. В этих пересечениях исходных TLN-02/05/06 нового P1/P2 не найдено; отдельные CBCP/HNS verdicts этим follow-up не переоткрываются.

## Новые remaining findings

### TLN-F01 — P2 — Optional peer-ID `null` отвергается раньше canonical absence normalization

**Связь:** новое пересечение TLN-03 role validator с существующим TL optional-presence contract.

**Место:** `C/ExteralessRuntime/TLTransformCodec.swift:88–91,104–106,236–246,297–299`.

`candidate` вызывает `validateNativeValues` до codec normalization. Наличие ключа role-field с `.null` приводит к `validatePeerRole(.null)` и ошибке `TL peer role must contain integer ids`. Между тем wire contract допускает omitted **или null** для absent optional; сам production codec считает их отсутствием (`TLCodec.swift:442–459,481–488`).

**Короткий source repro:** исходный `updateShortMessage`:

```json
{"_":"updateShortMessage","flags":0,"id":1,"user_id":2,"message":"before","pts":3,"pts_count":1,"date":4}
```

Post MODIFY меняет только `message` на `"after"` и добавляет `"via_bot_id":null`. Native схема (`TelegramApi/swift_scheme.tl:503`) объявляет `via_bot_id:flags.11?long`; bit 11 выключен. Ни peer, ни counters, ни presence не изменены. Codec может закодировать такой candidate, но новая role-валидация отвергает его до `response:106`. Без null-key тот же text edit проходит. SDK setter допускает `None` для этого optional и оставляет его в `_values` (`P/_tl.py:45–50,95–96`), поэтому это достижимый hook result.

**Impact:** корректная семантически отсутствующая optional reference отменяет весь MODIFY/MODIFY_FINAL и возвращает original; эффект hook теряется. Исходные overflow/retarget counterexamples TLN-03 при этом действительно исправлены.

**Fix/test:** проверять native roles/reference equality после schema normalization отсутствующих optionals либо явно учитывать declared optional absence. Не разрешать enabled-bit+null и не ослаблять диапазон/nonnull retarget. Pure `TLTransformCodec.response/update` regressions: omitted и null при disabled bit эквивалентны; text edit сохраняется; enabled bit+null и настоящий retarget по-прежнему rejected. Этот Swift repro здесь не исполнялся.

### TLN-F02 — P2 — Global post reference-shape guard блокирует заявленную Vector<User> mutation

**Связь:** TLN-03 reference projection теперь вызывается для любого RPC response и пересекается с TLN-11 SDK/native-probe contract.

**Место:** `C/ExteralessRuntime/TLTransformCodec.swift:104–110,204–233`; более слабый probe validator — `python/runtime/smoke/swift_sdk_tl_probe.swift:41–53,360–369`.

**Source repro:** `users.getUsers` возвращает `[{"_":"userEmpty","id":7}]`. Post hook добавляет через `response.objects` `userEmpty(id:29)` и возвращает MODIFY. Оба ID корректны; result type остаётся `Vector<User>`, protocol/counters отсутствуют. SDK wrapper и binary codec это представляют, но unconditional `preserveReferences` сравнивает reference arrays длины 1 и 2 и отвергает replacement. Удаление одного User из counter-free результата также отвергается.

**Реальный callpath:** `TLNetworkRequest.swift:390–403` → `U/.../PluginTLTransformIntegration.swift:32–37` → `H/PluginTLHostPayload.swift:90–108` → `ExteralessTLTransformCodec.response`. Поэтому отказ происходит уже при normalization между plugins; следующий plugin получает прежний vector.

Это конкретно тот User append, который remediation native probe требует увидеть в следующем plugin (`swift_sdk_tl_probe.swift:362–364`) и описывает `sdk-tl-remediation.md:58–60`. Но probe вызывает только `codec.normalize`, без `response`/reference policy (`:49–50`). Его positive result не подтверждает работу этого сценария в actual Core adapter. Primitive root vectors не обнаруживают расхождение: их элементы не имеют reference shape.

**Fix/test:** ограничить readonly-reference правило теми response/state contexts, где references уже принадлежат принятому snapshot; сохранить native ID ranges, immutable encrypted/protocol/counter subtrees и исходный typed parser. Добавить тот же User append/filter через **production `ExteralessTLTransformCodec.response`** и actual adapter normalization; counter-bearing Updates retarget должен оставаться отрицательным control. Probe для этого сценария должен использовать тот же validator. Это новое расхождение policy join, не повтор исходного отсутствия `.objects`.

## Проверки и предел closure

- **Полученный контекст:** current Foundation CI green; **11 Python codec/role fixtures PASS**, **14 native fixtures предоставлены, не исполнены**. Эти числа не превращены в Apple runtime receipt.
- **В этом follow-up:** bounded source checks подтвердили 11 Network и 4 execution postimages, а также пять Enqueue semantic joins после typed refactor. Первые попытки служебного checker ошибочно искали отсутствие context/prefix старых строк; после перехода к exact-line postimages проверка прошла. Это была ошибка checker, не missing integration hunk.
- **Один tiny production-node Python check**, внешний лимит 30 s, PASS: false/throw/malformed cancel оставляет completion; true закрывает; четыре native-owned handles имеют по одному simulated control release; Boolean/shared flags; User/Int/Long root Vector; nested ArrayList; final `.objects` и read-only context. Загружались только выбранные AST definitions и generated metadata, с маленькими platform/handle stubs. SDK loader, C bridge, плагины, accounts, RPC/HTTP не запускались.
- `swiftc` локально отсутствует. TLN-F01/F02 — короткие source/callpath доказательства и native regression specifications, без приписанного результата Swift execution.

**Prepared fixture scope, прочитанный в source:**

| Source | Что реально доказывает его построение |
|---|---|
| `tools/compat/tests/tl_bridge/NativeFixtures.swift:276–364` | Original encrypted payload rejection, inviter/vector roles и opaque long controls, deferred caption, provisional/claimed ownership. Foundation policy/commit helpers. |
| `TelegramCore/Tests/ExteralessTLReviewTests.swift:30–260` | 8 coded native tests: Api parse/serialization, AccountMutableState secret operations, reference builders, настоящий temporary Postbox tracking, cached edit text. Полный `Network.request` / public enqueue transaction не запускается. |
| `TelegramUI/Tests/PluginTLEditModelTests.swift:11–31` | 3 actual DTO presence cases. |
| `PluginHooks/Tests/.../PluginTLSubmissionOrderTests.swift:19–66` | 3 lane cases: gate-off follower, cancelled head, head retained до add return. Actual Network stitching дополнительно проверен в source. |
| `PluginHost/Tests/.../PluginTextOriginTests.swift:52–147` | Real Host/BridgeServices scope → recording platform DTO, child fanout, token/depth/closed-scope refusal. TelegramPluginServices/Core consumer проверен отдельно по callpath. |
| `TelegramUI/Tests/PluginTLExecutionGuardTests.swift` | Real provider admission и передаваемый commit predicate в bounded owned-engine scenarios; эта HNS fixture readiness не повышена до native execution. |
| `tools/compat/tests/test_sdk_tl_remediation.py:96–205` | SDK-only false-cancel/routes/vector/flags assertions с recording transport. Native codec/controller acceptance не следует из этих assertions; TLN-F02 показывает конкретную недостающую стыковку. |

Итог: all-11 original source remediation присутствует. Remaining scope этого follow-up — **TLN-F01/F02 (P2)** и непройденная Apple execution граница. Full parity, live Telegram behavior и broader CBCP/HNS acceptance не объявлены.

## Source pins

Raw SHA-256 без нормализации line endings. Сокращения раскрываются как выше; `P/` — только Python runtime package. Проверяемые pins включают исходный report, который эта сессия не редактировала.

<details>
<summary>48 scoped source / handoff / fixture pins</summary>

```text
95e740b878ba1c2f981e7d879484537937404036c3149bbeb623e3da0f752475  docs/wave-2/reviews/tl-network.md
c50ee7ec25367fee917560c61b236c02bb196624113ee87c624d4bcb54722e58  docs/wave-2/sdk-tl-remediation.md
0c4a4426579727f8d1bd0dffc30443c58bbfe033ca805812035bb2e91ca75e3c  docs/wave-2/tl-execution-guard-integration.patch
d06ef8c69c83bff10ef4861113238200fb4294c8d00c6493b282ad2e6c6564a9  docs/wave-2/tl-review-enqueue-commit.patch
5ed4e70e573d7d23fec29c2455a3920cd5cf3125a55003ff35f7efa36fa4fa60  docs/wave-2/tl-review-network.patch
96fa7fdd5aa2ba39cb1bb784a56c3d8948ffb9fd916b7f04962485ecb0b8b671  docs/wave-2/tl-review-remediation.md
38a8daffb5ec1dba864f5d37df960bd7958892d2bcf8ffd515088143b8b750b3  docs/wave-2/tl-text-origin-remediation.md
02526f84911a0dfdbcb9927885f947730cbf4671e37f79ea28d44a656a3f16c6  P/__init__.py
70497a280c5ebc081e662fc72c656bb907df721981c19e2929f7c815e638c481  P/_callbacks.py
30a1ed6fd51fef50587029ca692c1005067cad7ceba54a212163f50b4c314f56  P/_java_types.py
6108bc28915113b7927696a11588f55fd4783c35f2238b108f6584d050801ba7  P/_tl.py
646272183ee57f8d5c5d00f27b27fadba2ac9053d01975ba7962d13785cf6e54  python/runtime/smoke/swift_sdk_tl_probe.swift
e02140d484cabcafbaa0545a017c5be9f6904c74ab0a9e74c3848af8b7ecd221  python/runtime/tl-schema.json
c5157094b5f6ccab46ba254e16a623243cbd8f73c76f5b5ddf1ba414b68e3a16  K/PluginTLSubmissionOrder.swift
d59b6d90607a974b92d7e2f3eb1638c9c9bc36c56069e7fbbdae18446ebde7d7  K/PluginTLTransformRouter.swift
e93d4b9a90c93db4d2907ffb3ef8e1e435d6d12e57f8a9f7a6fd250fb161e58a  swift/PluginHooks/Tests/PluginHooksTests/PluginTLSubmissionOrderTests.swift
c817d28bd8de0b7f942b790e7a7f060c27089d6a5352769dbcf9d0c1add0cb0a  H/BridgeServices.swift
d5cf1997b54359323a38db2dbe39002a59a59642514b8fc27db66dc7184c3815  H/PluginServiceModels.swift
e3935c527f2ed969ebd1898bdf85b817454563b504532216e508953498b96d76  H/PluginTLHostPayload.swift
328d6f819ae6141529d334cb4ab9eb94536aad29617541ef2d9c92de18e12383  H/PluginTLInvocationOrigin.swift
7ada43a02bb0075e9fd87be5a1a5c1d7aa6d384f9dcc2865350b76814b12b281  swift/PluginHost/Tests/PluginHostTests/PluginTextOriginTests.swift
4b67ac34ce795e08a897b8ab3c764c664994f72265971c5ad1cf09680ee4b3a2  telegram-ios/submodules/TelegramApi/swift_scheme.tl
c22611ed58f5594e27e8087da14f272eabed38e5c5b8306049d224af9c710863  C/ExteralessRuntime/TLCodec.swift
8a6bf5d1280ce119723ac381efc3fa44fc063338cad406ea0f4c66ec80882ec6  C/ExteralessRuntime/TLEnqueueCommit.swift
32081bed061ef977da64aea4f6b5d25830c2b07fe7f956dc53166b22620ac8be  C/ExteralessRuntime/TLMediaEditServices.swift
b5f6e204fd839267b36181479a22daacb0df8ef55c8473c67a33c1240e4eac3c  C/ExteralessRuntime/TLMediaServices.swift
ad4e1a8154581e9de89ef413af4dee16a10c9a0a06db47f6943e59f07aba3823  C/ExteralessRuntime/TLNativeServices.swift
468aebbb567a665ce93d54f24e4e816c88519a48f3b1f228ad7e625597c5c9ab  C/ExteralessRuntime/TLNetworkRequest.swift
413ae07748fc228dc2a0b271768f2812e8d4ece0061d0c88c22a3bb1f7ff0182  C/ExteralessRuntime/TLRequestOrigin.swift
a7ba8101615f8ac6753fe683c115321fb61ebb4c478e88a11fcd3eaa699c93f0  C/ExteralessRuntime/TLRequestRegistry.swift
b9bcf2192f071ce490ab6553dc2d546fc8ab68099703c90236150976c526beb2  C/ExteralessRuntime/TLTransformCodec.swift
aaeba281b2ceaf4abe0ff61c35678dcbc215d49ca53c274095ac5e8cdbd3d427  C/ExteralessRuntime/TLUpdateBarrier.swift
ba6ad1462fc5d1dfce5ddc3fd619178ff1c4b0b5a8a5bd57650a0ec5166f3b2b  C/ExteralessRuntime/TLUpdatePolicy.swift
d77c9983d248b7fa97d95645bff61e9db5d4ff8f2f8f3c9a8cbe7065c1741d8a  C/Network/Network.swift
f67e1f05f49418392d2781201c07b2f0a48e40e3803a38d39fab544df0fc3cfb  C/PendingMessages/EnqueueMessage.swift
2b0f4bda3a578dd4d546379cbd97dc3f14a70f0b5a3038799a228700a1d89eb0  C/PendingMessages/PendingMessageUploadedContent.swift
69bcbd2d49d81a2e30f570f19c42cb339b67d953bcb8538e61c671f883969a05  C/PendingMessages/RequestEditMessage.swift
246b25147271781c17dcf76d7357e09cadbea0afdf638fbdb7eef2f9f46d2778  telegram-ios/submodules/TelegramCore/Tests/ExteralessTLReviewTests.swift
6998d97a25376dcdc8f9b965ef5fcc4f1a3309b309b30fd74e9c90ed13f019ee  U/Exteraless/ExteralessPluginRuntime.swift
291507fe97af636bfd2aff7cfc60f1410712c3ec04468a6926523f9f0959ee87  U/Exteraless/TelegramPluginServices.swift
60b9129f9424ada9d4a626336e01e69af2ce2044e04652b43fb07546de3a613c  U/ExteralessClient/TL/PluginTLBridgeExtension.swift
ba406f0888a2bdf80a455c2d1b1cef79e308a4273b774804ba380ec7209bd061  U/ExteralessClient/TL/PluginTLModels.swift
2d721b6c8594e1fe4c0f882faf732e11d0b82cfba7990c83fd8255886a2e9857  U/ExteralessClient/TL/PluginTLTransformIntegration.swift
19aff2a0b5f7d6808924a8357733a3bbe903719a62bb4338b6fd3003578a96a6  telegram-ios/submodules/TelegramUI/Tests/PluginTLEditModelTests.swift
1bc7522f378645a117298f286907e959f2a6d100fad0f61ae5c32e61b372da6d  telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift
1505c6e2db8ea4a6cbb41b94076257c52d2eb3092bc9608c6f1c5cec05d8ac44  tools/compat/tests/test_sdk_tl_remediation.py
3e651c4df3fac24e0c6c488fe4180affddaa08626ad6d4a29cc72f1af5665805  tools/compat/tests/tl_bridge/NativeFixtures.swift
d281ec05247918c4893db4237b5c89c40af7ccc0cf3015564a38a70a53ec9449  tools/compat/tests/tl_bridge/test_native_role_schema.py
```

</details>
