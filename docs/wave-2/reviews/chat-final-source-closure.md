# CMC-03 / CMC-05 — final source closure

2026-11-15. **2/2 SOURCE CLOSED. Остаточных P1/P2 по двум проверенным counterexamples не обнаружено.**

Область проверки — только два остатка из `docs/wave-2/reviews/chat-source-closure.md:11–50`: held persistent Forward write после transform и media Schedule с explicit false при silent default=true. Проверено рабочее дерево, включая незакоммиченные изменения; HEAD на контрольном чтении — `4476f853e27d011ee7acc43cadccf5f7da9f7eb1`. Вывод основан на shipping call chains и прочитанных native fixtures. **Apple typecheck/build, XCTest и UIKit/device/frames не выполнялись.**

## CMC-03 / прежний P1 — SOURCE CLOSED

**Прежний сценарий:** More → Forward → новый destination peer/thread; transform уже прочитал и изменил draft, конечная Postbox write-transaction ещё ожидает исполнения. Отозвать исходный permit / отменить operation, dispose подписку и отпустить transaction. Ранее setter всё равно записывал сохранённый snapshot.

### Фактическая production-цепь

1. **Native caller.** `telegram-ios/submodules/TelegramUI/Sources/ChatControllerForwardMessages.swift:502–505` теперь вызывает typed `ChatInterfaceState.update(..., admission:)`; admission создаётся через исходный `exportAccess` с записанными permit/account/source IDs и настоящими destination peer/thread. Transform содержит только изменение forward IDs/options. Продолжение navigation принимает `ChatInterfaceStateWriteResult` через `exteralessForwardDraftCompletion`.
2. **Исходная операция.** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatExportAccess.swift:234–241` проверяет identity `recordedPermit === self.permit`, account/source IDs и передаёт immutable baseline плюс прежний lease. Cancellation access также отменяет admission. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessForwardDraftWrite.swift:7–26` создаёт non-actor executor, удерживающий **тот же** permit и lease; запись выполняется синхронно внутри `permit.perform` → `lease.withActive`.
3. **Read snapshot → transform → write.** `telegram-ios/submodules/ChatInterfaceState/Sources/ChatInterfaceStateUpdate.swift:19–51` использует реальный `engine.peers` и при nonnil admission автоматически передаёт read snapshot как CAS operand. Guarded decode/encode failure возвращает rejection. Disposal вызывает `admission.cancel()`. Старый overload делегирует этому implementation (`telegram-ios/submodules/ChatInterfaceState/Sources/ChatInterfaceState.swift:949–950`).
4. **Native engine facade.** `telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/TelegramEnginePeers.swift:1177–1189` получает snapshot в Postbox и передаёт expected state/admission в `_internal_setOpaqueChatInterfaceState`. Старый setter также делегирует этому native writer.
5. **Проверка внутри отложенного body.** `telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/ChatInterfaceStateWriteAdmission.swift:147–192` исполняет CAS/source checks и `admission.perform(write)` **внутри фактической Postbox transaction**. Оба terminal setters — `setPeerChatInterfaceState` и `setPeerChatThreadInterfaceState` — находятся внутри admitted `write`, вместе с `addSynchronizeChatInputStateOperation` (`:170–180`). Queued body после disposal больше не получает безусловное право записи.
6. **Одноразовый commit и результат.** В том же файле `:81–119` claim отклоняет cancelled/duplicate execution до write. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessForwardDraftWrite.swift:29–33` разрешает continuation только при `isWritten`; caller дополнительно проходит существующую presentation admission (`ChatControllerForwardMessages.swift:505–551`).

**Почему прежний counterexample закрыт:** после release уже поставленная transaction действительно может исполниться, но revoked permit, cancelled lease или cancelled admission не вызывают native `write`. Permit и lease остаются удержанными на протяжении синхронного admitted write: `telegram-ios/submodules/AccountContext/Sources/ExteralessContentExportPermit.swift:49–58`; `swift/ExteralessCore/Sources/ExteralessCore/AINativePolicy.swift:21–36`. Claim имеет один ordering point; cancellation после выигранного claim относится уже к выполненной local mutation.

**Новый draft не затирается:** final CAS сравнивает account/полный peer ID/namespace/thread и весь `StoredPeerChatInterfaceState`, включая absent state (`ChatInterfaceStateWriteAdmission.swift:138–157`). Его equality сравнивает bytes, timestamp, scroll index и associated message IDs: `telegram-ios/submodules/Postbox/Sources/PeerChatInterfaceState.swift:52–65`. Изменившийся destination возвращает `.destinationChanged` до synchronization/setter; старый transform не повторяется поверх нового draft.

**Fresh source policy:** в той же transaction заново проверяются source stable ID/version, thread/content/native attributes (`ChatInterfaceStateWriteAdmission.swift:95–135`; native equality — `telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/Message.swift:190–242`). Private cached flags читаются через существующий effective-peer predicate (`telegram-ios/submodules/TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift:134–151`). Закрытие не зависит от того, успел ли UI observer сообщить об изменении protection.

### Regression evidence

`telegram-ios/submodules/TelegramUI/Tests/ChatMedia/ChatForwardFinalAdmissionTests.swift:14–238,251–324` содержит **8 authored XCTest methods**. Прочитан exact regression `:14–47`: transform → barrier перед queued write → original permit revoke + disposal → release; fixture наблюдает выполнение disposed body, ноль successful setter receipts, прежние stored bytes и ноль navigation для peer и thread.

Дополнительные cases проверяют отдельную operation cancellation, intervening destination write/CAS, оба cached flags без UI observer, source edit/delete/thread, one-shot positive controls, identity/decode и absent-state CAS (`:49–238`). `ForwardDraftStore` использует настоящий Postbox read и **тот же production transaction factory/writer**, с отдельной receipt после native write body (`:251–324`). Это устраняет прежний пробел formatter/effect-only spy. **Fixtures не запускались.**

## CMC-05 / прежний P2 — SOURCE CLOSED

**Прежний сценарий:** global silent default=true либо native chat silent=true → выбрать фото → Schedule → явно выбрать `silentPosting=false`. Ранее полный result сжимался до Bool/time, а media conversion превращал false в nil и снова применял default. Там же пропадал repeatPeriod.

### Фактическая production-цепь

1. **Schedule menu.** `telegram-ios/submodules/ChatSendMessageActionUI/Sources/ChatSendMessageContextScreen.swift:25–32,623–641` использует общий parameter factory: effect/caption placement сохраняются, sound до ответа picker отсутствует.
2. **Полный результат настоящего picker.** `telegram-ios/submodules/TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift:47–50,1568–1577` устанавливает `presentSchedulePickerWithResult`; adapter копирует `time`, `repeatPeriod`, `silentPosting`. Existing explicit override передаётся в seed picker, затем `done` получает весь DTO.
3. **Actual MediaPicker completion.** `telegram-ios/submodules/MediaPickerUI/Sources/MediaPickerScreen.swift:41–49,347–355,2423–2436` вызывает `mediaPickerScheduleCompletion` и передаёт `parameters.withUpdatedSchedule(result)` в настоящий `interaction.sendSelected` → `Node.send`. Typed callback установлен на shipping attachment host, поэтому этот путь использует полный result.
4. **Presence и приоритет выбора.** `telegram-ios/submodules/AccountContext/Sources/AccountContext.swift:1760–1795` хранит полный `Schedule`; `withUpdatedSchedule` заменяет его целиком и присваивает `notificationOverride = schedule.silentPosting`, включая **false**. `Node.send` сохраняет parameters через normalization и actual asset-signal/legacy completion (`MediaPickerScreen.swift:1572–1607`). Attachment forwarding передаёт их в `enqueueMediaMessages` (`ChatControllerOpenAttachmentMenu.swift:541–547,1590–1591`).
5. **Conversion после native asset preparation.** `telegram-ios/submodules/TelegramUI/Sources/ChatController.swift:9306–9330,9368–9377,9448–9450` вызывает production `prepareMediaEnqueueMessages`. Приоритет — `schedule.silentPosting` → старый notification override → legacy true/nil. В native transform поступают также `schedule.time` и `schedule.repeatPeriod`; effect/caption attributes сохраняют native projection.
6. **До final message attributes.** `ChatController.swift:9534–9561,9275–9284,9015–9016` проводит сообщения в `sendMessages`; повторный transform получает nil override и сохраняет уже принятое explicit false. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatSendOptions.swift:14–20` записывает единственный notification attribute и полный schedule attribute. Core default-only-if-absent не переписывает `flags=[]` (`telegram-ios/submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift:827–832`).

**Итог прежнего сценария по source:** `result.silentPosting=false` остаётся nonnil false на каждом значимом conversion boundary и даёт `NotificationInfoMessageAttribute(flags: [])` при любом native/global default. Time/period доходят до `OutgoingScheduleInfoMessageAttribute`. Новый result с nil period удаляет прежний repeat; обычный tap без result сохраняет nil/default semantics.

Проверена и транспортировка того же DTO через уже затронутые picker adapters: оба gallery callbacks и nested-album handoff (`telegram-ios/submodules/MediaPickerUI/Sources/MediaPickerScreen.swift:1468–1484,1522–1537,3142–3150`). Local `MediaPickerLegacyScheduleBridge` держит result на время синхронного schedule-done → completed вызова (`:52–67`; actual callback — `telegram-ios/submodules/MediaPickerUI/Sources/LegacyMediaPickerGallery.swift:382–387`), после чего очищает его. `Node.send` уже получил value parameters, поэтому последующий ordinary tap не наследует старое расписание.

### Regression evidence

`telegram-ios/submodules/TelegramUI/Tests/Chats/ChatMediaScheduleProducerTests.swift:34–156` содержит **4 authored XCTest methods** (`:80–156`). Они проводят настоящий `ChatScheduleTimeScreen.Result` через production attachment adapter, media Schedule completion, `Node.send` normalization и `ChatControllerImpl.prepareMediaEnqueueMessages` (`:34–48,86–103`), затем повторный sound transform и fake local enqueue.

Матрица включает false/true × оба native/global defaults × previous nil/false/true; controls — ordinary nil/default, замена старого time/period/intent, nil period и ограниченный lifetime gallery DTO. Проверяются notification/schedule attributes и сохранение media/rich/entities/reply/thread/grouping/correlation/effect/caption fields (`:55–77`). По сравнению с прежним helper-only тестом бывший lossy bridge теперь участвует в regression chain. **Fixtures не запускались.**

## Integration и проверки

| Стык | Фактическое состояние |
| --- | --- |
| CMC-03: Forward caller / ChatInterfaceState update / Core setter | **DIRECT APPLIED** во всех трёх shared sections; permit/CAS достигают общего native writer. |
| Новые production-файлы | Включаются существующими source globs: `telegram-ios/submodules/ChatInterfaceState/BUILD:8–10`, `telegram-ios/submodules/TelegramCore/BUILD:36–40`, `telegram-ios/submodules/TelegramUI/BUILD:126–130`. |
| CMC-05: complete Schedule DTO и production adapters | **APPLIED** в пяти production-файлах, цепь проверена выше. |
| Build handoffs обеих regressions | **APPLIED**: direct dependencies и оба test globs в `telegram-ios/submodules/TelegramUI/BUILD:813–845`; required-source entries в `telegram-ios/Tests/Exteraless/native-tests.json:100–103`. |
| Старый `chat-review-integration.patch` | Read-only сопоставление post-patch fragments: **6 files / 13 hunks по-прежнему APPLIED**. |
| Apple/native/frames execution | **Не выполнено**; source closure не означает compile, XCTest или visual pass. |

Выполненные offline checks (timeout ≤30 s на команду):

- Проверено наличие всех post-patch fragments старого integration packet в текущих production files.
- `chat-media-schedule-frozen.sha256`: **6/7 hashes совпали**. Whole-file hash `ChatController.swift` отличается: текущий `faf5d386800945d8dbda26f732239996c054845d19b5a27f47be6f043c0ba7d9`. Вывод CMC-05 основан на повторном чтении актуальных conversion/callsite/re-entry regions, а не на frozen fingerprint.
- Toolchain discovery: `swift=None`, `swiftc=None`, `xcodebuild=None`.
- Проверка отчёта: UTF-8/whitespace, ровно два closure-статуса, существование full-path references и диапазоны строк — **PASS**. Source census подтвердил 8+4 authored methods; hashes обоих прежних отчётов совпали.

Собственный executable fixture не понадобился. CI, accounts, network и external plugins не использовались. Единственное изменение reviewer — этот новый документ.

Read-only контроль прежних отчётов, SHA-256:

- `docs/wave-2/reviews/chat-source-closure.md`: `1c260550f22f27605f9b0d998ecbbde4fe74350ae1d4efb896ed33f4c1b9a79d`.
- `docs/wave-2/reviews/chat-media-composer.md`: `b97a1e4bf89ebc400405adf3297209377776db5b78075875e42e72fa9c606c7a`.

Контроль cited source/test/build snapshot: **29 full-path references / 26 файлов**. SHA-256 отсортированного списка `path + NUL + SHA256(file bytes) + LF`: `1b6b3c442ddad5779d113346d56b9f08a500e97f617e8f386f5dfdfd4cd2f1d9`. Во время финализации изменились TelegramCore/TelegramUI BUILD и native-tests.json; относящиеся к этим двум fixes globs/dependencies/mappings повторно сверены, ссылки обновлены.
