# CMC-01…15 — проверка source closure

2026-11-15. **REQUEST CHANGES: остаются 1 P1 и 1 P2.** Из исходных 15 findings **13 закрыты по source**, CMC-03 и CMC-05 закрыты частично. Запрошенный terminal хвост Photos / ShareControllerNode уже присутствует в production и подключён.

Проверены только counterexamples из `docs/wave-2/reviews/chat-media-composer.md` и их remediation call chains. Контрольное чтение рабочего дерева: HEAD `8395d6be3d8fdc62035839c9c9d0adcad403d1e8`; учитывались также незакоммиченные файлы. Во время проверки HEAD менялся. Изменение reviewer — этот новый документ; реализация и прежний report read-only.

**Source closure** здесь означает, что исходный counterexample перекрыт на фактическом production-пути. Swift/XCTest, Apple typecheck, UIKit/device/frames не выполнялись. Наличие injectable helper, authored test или applied patch само по себе не засчитано как closure.

## Остаточные findings

### CMC-03 — P1, частично открыт: Forward проверяет permit до отдельной записи destination draft

**Source:**

- `telegram-ios/submodules/TelegramUI/Sources/ChatControllerForwardMessages.swift:502–508` — `permit.perform` находится внутри transform, переданного в `ChatInterfaceState.update`.
- `telegram-ios/submodules/ChatInterfaceState/Sources/ChatInterfaceState.swift:949–970` — сначала отдельный get, затем `f(previousState)`, кодирование и отдельный `setOpaqueChatInterfaceState`.
- `telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/TelegramEnginePeers.swift:1177–1242` — write-transaction выполняет `setPeerChatThreadInterfaceState` / `setPeerChatInterfaceState` без исходного permit/commit predicate.
- `telegram-ios/submodules/Postbox/Sources/Postbox.swift:3388–3415,4810–4818` — production transaction ставится через `justDispatch`; её body не отменяется disposal, внутренний disposable — `EmptyDisposable`.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessForwardExport.swift:21–36` — внешний wrapper отменяет подписку, но не добавляет admission внутрь этой write-transaction.

**Минимальный сценарий:** More → Forward разрешённого сообщения → выбрать другого peer/thread, которого нет в navigation stack. Дать `ChatInterfaceState.update` прочитать destination draft и выполнить разрешённый transform. Удержать уже поставленную конечную write-transaction; отозвать тот же permit, например сменой primary account; отпустить transaction. `guardSignal` уже может быть disposed, но сохранённый `updatedState` всё равно записывается. Проверка перед transform не является проверкой перед этой записью.

**Impact:** отозванная операция продолжает менять persistent destination draft, включая `forwardMessageIds`. Запись несёт весь snapshot прочитанного состояния и может перезаписать более новый draft. При этом поздняя navigation continuation уже отклоняется; permit привязан к controllers и не сохраняется вместе с этим draft. Это остаток исходного Forward/permission counterexample на конечной draft boundary.

**Что уже исправлено:** saved More Copy/Combine заново читают eligibility и Core restrictions; Copy пишет текущий native rich/plain payload. Combine повторяет admission после Replace draft confirmation. Forward enqueue проводит тот же permit до `beginCommit` существующей send-transaction. Forward packet применён; отдельный persistent draft setter остаётся без terminal admission.

**Fix:** провести admission/cancellation от исходного permit до существующей write-transaction `setOpaqueChatInterfaceState` и проверять/claim непосредственно перед native draft writes; проверку source version/protection также связывать с конечной admission. Отказ должен завершать операцию без записи прочитанного старого состояния. Сохранить peer namespace, thread и исходную identity permit.

**Meaningful regression:** bounded in-memory Postbox fixture через настоящий destination-draft путь: барьер между transform и write-transaction → revoke/cancel → release → ноль native draft writes и byte-identical прежний rich/media/reply/forward draft. Повторить для peer и thread; positive control сохраняет разрешённый forward ровно один раз. `telegram-ios/submodules/TelegramUI/Tests/ChatMedia/ChatMediaRemediationNativeTests.swift:101–131` сейчас вызывает `session.read` и считает effects, но не проходит через `ChatInterfaceState.update` и конечный setter, поэтому эту дыру не проверяет.

### CMC-05 — P2, частично открыт: media scheduler теряет explicit audible false

**Source:**

- `telegram-ios/submodules/ChatSendMessageActionUI/Sources/ChatSendMessageContextScreen.swift:613–631` — Schedule создаёт parameters без notification override.
- `telegram-ios/submodules/AccountContext/Sources/AccountContext.swift:1751–1767` — значение по умолчанию `notificationOverride: Bool? = nil`.
- `telegram-ios/submodules/TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift:1561–1565` — полный schedule result сжимается до `(result.time, result.silentPosting)`.
- `telegram-ios/submodules/MediaPickerUI/Sources/MediaPickerScreen.swift:289,1519–1559,2388–2392` — sound передаётся как `Bool`, старые parameters сохраняются; выбранный sound не записывается в `notificationOverride`.
- `telegram-ios/submodules/TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift:534–540,1583–1584` — native completion доходит до `enqueueMediaMessages`.
- `telegram-ios/submodules/TelegramUI/Sources/ChatController.swift:9435`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatSendOptions.swift:14–20` — `parameters?.notificationOverride ?? (silentPosting ? true : nil)` превращает выбранное false в nil; затем снова применяется native/global default.

**Минимальный сценарий:** `chats.silentMessageByDefault=true`, выбрать фото обычным media picker, Schedule, явно выключить silent posting в picker и подтвердить. Callback возвращает false, но до final options доходит nil; итоговый `NotificationInfoMessageAttribute` содержит `.muted`. Тот же результат при native chat silent=true и global default=false. Это тот же sound-presence контракт CMC-05 на реальном media/schedule producer.

**Impact:** явно выбранная audible отправка становится silent. На этом же DTO boundary теряется `result.repeatPeriod`: у bridge только time/sound, а media transform не получает period.

**Что уже исправлено:** обычные inline-GIF taps передают nil; round completion сохраняет optional override; text schedule seed учитывает effective default; rich attachment schedule передаёт sound/time/period; повторный default transform сохраняет ранее записанный explicit false. Остаток расположен перед исправленным общим helper.

**Fix:** перенести полный schedule result через media producer. Результат picker должен становиться явным sound intent, включая false, с приоритетом над предыдущими parameters; обычный tap должен сохранять отсутствие override. Провести repeatPeriod вместе с time, сохранив effect/caption/media fields.

**Meaningful regression:** вызвать actual media Schedule completion и actual conversion/enqueue adapter с fake enqueue: native/global defaults × выбранные false/true, затем повторный `sendMessages` transform; проверить конечный единственный notification attribute и schedule period. Отдельный ordinary-tap control проверяет nil/default. `telegram-ios/submodules/TelegramUI/Tests/Chats/ChatSoundProducerTests.swift:31–74` подаёт intent прямо в `ExteralessChatSendOptions`, минуя этот `Bool` bridge, поэтому нынешняя матрица не закрывает остаток.

## Состояние каждого исходного counterexample

### CMC-01 — SOURCE CLOSED

`telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:3829–3914` захватывает native Date request до picker и в native completion проверяет panel/chat/edit identity, вызывает `nativeEdit.apply`, затем восстанавливает input mode. Flat `ChatTextInputState(inputText:)` rebuild больше не находится на native add/remove пути.

`telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift:5503–5524` и `telegram-ios/submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer/Sources/RichTextEditorChatInputNode.swift:993–1089` связывают apply с реальными document/selection revisions и single-use snapshot. Add/remove доходят до native link mutation; `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Links.swift:33–110` объединяет mutation в один undo step. Change notification flush синхронно обновляет host до восстановления input mode (`telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView.swift:1589–1610,1699–1723`).

### CMC-02 — SOURCE CLOSED

`telegram-ios/submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift:763–806,944–1007` возвращает различимые local admission slots для CANCEL/bot denial/retained-reply failure и сохраняет partial IDs. Postcommit publisher выдаёт `.single(messageIds)` также для all-nil результата, поэтому rejection доходит обратно до Chat (`telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/NativeServiceAccountEvents.swift:165–172`). Legacy `[MessageId?]` API — adapter; результат означает local admission.

Настоящий text sender передаёт captured operation (`telegram-ios/submodules/TelegramUI/Sources/ChatControllerNode.swift:5451–5517`); оба history callbacks вызывают только `cleanupIfAdmitted` (`telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:900–919,1119–1131`). `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatSendAdmission.swift:94–111,144–176,179–192` требует `allEnqueued`, текущий draft/revision и single-use cleanup, снимает только принадлежащий operation layout slot и показывает typed failure. Nil correlation / Reduce Motion больше не авторизует очистку rejected draft; partial batch его сохраняет.

### CMC-03 — PARTIAL / OPEN P1

Saved Copy/Combine и fresh private restrictions исправлены в `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessSelectionActionSession.swift:33–60` и `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessSelectionActions.swift:32–52,161–185`. Forward destination-draft tail остаётся открытым по finding выше.

### CMC-04 — SOURCE CLOSED

`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatExportAccess.swift:18–59,166–179,234–278,355–367` использует настоящий Core scope, immutable source baseline, повторную validation, account/presentation lifetime и current Chat protection. Core acquisition читает effective associated peer и оба cached-user flags: `telegram-ios/submodules/TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift:98–151,161–173,209–216`.

Проверена цепь до effects: `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessImageActionOperation.swift:47–124` повторяет admission после fetch/decode, в QR Copy/Open, после profile confirmation и own-peer read; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessMessageMediaActions.swift:20–29,72–99` повторяет её после controller readiness, до pasteboard / `updateProfilePhoto`. Последний вызывает реальный upload entry (`telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenAvatarSetup.swift:827–880`). Исходный held-decode / held-prompt counterexample перекрыт.

### CMC-05 — PARTIAL / OPEN P2

Applied fixes видны в `telegram-ios/submodules/TelegramUI/Components/ChatEntityKeyboardInputNode/Sources/GifPaneSearchContentNode.swift:233`, `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerMediaRecording.swift:185–230,685–762`, `telegram-ios/submodules/TelegramUI/Sources/ChatController.swift:9013–9014,9118–9122,9593–9594,9629–9634,10947–10956` и `telegram-ios/submodules/TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift:1208–1213`. Нижний explicit-false attribute существует (`telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/OutgoingMessageWithChatContextResult.swift:29–34`). Обычный media Schedule bridge остаётся открытым по finding выше.

### CMC-06 — SOURCE CLOSED

Native Translate/Mention берут `SelectionSnapshot`, а не `composerSelectedRange`: `telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift:5496–5555,5658–5686`; `telegram-ios/submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer/Sources/RichTextEditorChatInputNode.swift:1012–1082`. Exact covered `DocumentTree` text nodes включают cell/caption/details/author, UTF-16 slicing сохраняет атрибуты. Completion повторно проверяет node/document/selection/revisions/IME и не может заменить другой draft.

Translate доходит до native `replaceRange` с одним undo (`telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+ArticleHost.swift:297–314`). Media `displayMode` теперь переносится при kernel splice (`telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorCore/Model/DocumentFragment.swift:105`). Частичное пересечение media/table unit явно disabled и повторно отклоняется на apply (`RichTextEditorChatInputNode.swift:962–988,1075–1076`); отдельные cell/caption и owned text regions работают на своей оси. Это documented capability boundary, а не прежний flat-zero fallback.

### CMC-07 — SOURCE CLOSED

Все шесть caption consumers вызывают общий producer: `telegram-ios/submodules/LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift:479,569,636,705,757,998`. Native media picker использует этот asset-result путь (`telegram-ios/submodules/MediaPickerUI/Sources/MediaPickerScreen.swift:1547–1559`). Edit вызывает `exteralessComposerMarkdown(..., respectDisableMarkdown: false)` в `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:2151`; Forward comment — `exteralessComposerForwardComment` в `telegram-ios/submodules/TelegramUI/Sources/ChatControllerForwardMessages.swift:154–164`.

`telegram-ios/submodules/TextFormat/Sources/ExteralessComposerMarkdown.swift:9–49,54–65` сохраняет отдельный ordinary-send disable contract, selected grammar, protected code/date/mention/link/custom-emoji spans и native trim/split/entity generation. Pending Edit delta из composer handoff фактически applied.

### CMC-08 — SOURCE CLOSED

Literal destination проверяется до transformer: `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Clipboard.swift:417–445`, `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorUIKit/Canvas/DocumentCanvasView+Clipboard.swift:79–125` и legacy panel `telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift:5891–5898`.

Actual host wiring (`ChatTextInputPanelNode.swift:1226–1236`) сначала передаёт исходные bytes Markdown parser. `telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ExteralessChatInputHelpers.swift:56–197` защищает raw code/labels при disabled Markdown и чистит разрешённые prose spans после parsing; code blocks/inline code не переписываются. Raw-source undo сохранён; deferred canvas step проверяет document revision/selection до mutation (`DocumentCanvasView+Clipboard.swift:232–253`).

### CMC-09 — SOURCE CLOSED

`telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift:1822–1837` передаёт отдельный playback sampler с item/player identity guard. `telegram-ios/submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift:988–1007` читает native status как Double без ten-minute threshold: paused 20 s / 8.25 s остаётся 8.25, missing status возвращает nil.

`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessGalleryChatActions.swift:53–62` передаёт этот sample в image operation; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessMessageMediaActions.swift:51–67` строит реальный `AVAssetImageGenerator` request с subsecond CMTime и zero tolerances. Share-link Int32 DTO больше не источник времени для Copy current frame.

### CMC-10 — SOURCE CLOSED

`telegram-ios/submodules/GalleryUI/Sources/ExteralessGalleryMessageActions.swift:10–49` хранит exact native subject/reference и сравнивает выбранный medium повторно, включая rich named miss. Native footer создаёт selection из текущего `mediaSubject` и инвалидирует item generation при изменении/выходе (`telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift:119–121,927–930,1226,1819–1863`).

Gallery image actions передают `selection.reference(in:)` прямо в production fetch/decode path (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessGalleryChatActions.swift:29–59`). Share/Save selection branch также использует `.media(reference, ...)`, сохраняя оригинальный MessageReference; rich message не пересобирается и first-media fallback для named selection отсутствует.

### CMC-11 — SOURCE CLOSED

Actual entry `telegram-ios/submodules/TelegramUI/Sources/AccountContext.swift:1014–1015` вызывает новый flow. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatCallConfirmation.swift:8–64` подаёт continuous primary-account/foreground validity; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatCallFlow.swift:36–95` проверяет sticky scope после обоих peer reads, перед prompt/call и в каждой OK callback. Prompt identity single-use, A→B→A не возобновляет retired operation (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatSendAdmission.swift:19–36`).

### CMC-12 — SOURCE CLOSED

Actual browser root удерживает `ExteralessBrowserGestures(navigationView: self.displayNode.view)` (`telegram-ios/submodules/BrowserUI/Sources/BrowserScreen.swift:1724–1730`). `telegram-ios/submodules/BrowserUI/Sources/ExteralessBrowserGestures.swift:13–32` связывает preference с horizontal gate, modal gate и per-page WebKit preference, включая live reset.

Modal consumer действительно читает root `disablesInteractiveModalDismiss` и отключает свой scroll recognizer (`telegram-ios/submodules/Display/Source/Navigation/NavigationModalContainer.swift:585–632`). NSNumber getter repaired: `telegram-ios/submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UIViewController+Navigation.m:920–925` возвращает `boolValue`, поэтому false снова означает false. Проверка жестов на кадрах остаётся native acceptance.

### CMC-13 — SOURCE CLOSED

`telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:2095–2154,2219–2250` захватывает полный edit snapshot до обоих reads; media/preview берутся из A. State changes увеличивают draft revision и отменяют pending token (`telegram-ios/submodules/TelegramUI/Sources/ChatController.swift:290–299`).

`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatEditAdmission.swift:16–28` повторно проверяет current scope/token/source после обоих reads. `telegram-ios/submodules/TelegramCore/Sources/PendingMessages/PendingUpdateMessageManager.swift:176–188` передаёт token до manager queue; `telegram-ios/submodules/TelegramCore/Sources/PendingMessages/PendingMessageUpdateAdmission.swift:5–11` claim расположен непосредственно перед `impl.add`. Cleanup требует admitted/unchanged и тот же current A. Held read → Edit B, missing A и cancellation до claim не закрывают B.

### CMC-14 — SOURCE CLOSED

`telegram-ios/submodules/TelegramUI/Sources/SharedMediaPlayer.swift:18–22,57–63,217–268,309–312,450–543` регистрирует callback с identity реального audio/round player, инвалидирует её до Next/replacement/stop и перевооружает при reuse native object другим playlist item.

`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerEndActionGate.swift:25–79` проверяет token на worker, после main hop и до effects; advance consume — single-use. Mode/effects читают main-owned state. Queued end A после установки B не может pause/advance B; loop/stop/advance текущего A сохранены по source.

### CMC-15 — SOURCE CLOSED

`telegram-ios/submodules/TelegramCore/Sources/PendingMessages/ExteralessOutgoingChatText.swift:7–41` исключает весь `text.hasPrefix("/")` до Pangu, независимо от BotCommand entity. Production enqueue вызывает этот stage (`telegram-ios/submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift:763–765,818–821`). Это соответствует original `third_party/exteraless-android/TMessagesProj/src/main/java/tw/nekomimi/nekogram/utils/StringUtils.kt:39–47`; command arguments и UTF-16 entities не проходят spacing rewrite.

## Applied handoffs и запрошенный FU-02 tail

| Стык | Фактическое состояние |
| --- | --- |
| `chat-review-integration.patch` | **APPLIED: 6 файлов / 13 hunks.** Все post-patch fragments сопоставлены с production source read-only. GIF optional API, call entry, typed pending edit и custom-content adapters присутствуют. |
| Composer Edit parser delta | **APPLIED**, включая `respectDisableMarkdown: false`; старая pending запись handoff устарела. |
| Forward packet | **APPLIED**, включая permit до enqueue transaction. Семантический остаток CMC-03 выше находится после applied draft transform guard. |
| Gallery packet | **APPLIED** в actual footer: exact selection, live Double sampler, item generation и inherited permit; `.media(reference, ...)` Share branch подключён. |
| Photos terminal guard | **APPLIED и подключён**; цепочка ниже. |
| ShareControllerNode timestamp-link / success continuation | **APPLIED и подключён**; цепочка ниже. |

Проверенная цепь для запрошенного terminal хвоста:

1. Gallery → `presentRootShare` удерживает тот же permit и source validator, проверяет независимые item/player generation до и после readiness: `telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift:143–165,1843–1863`. `ExteralessChatExportAccess.handoffNativeExport` сохраняет validators на descendant controller (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatExportAccess.swift:282–315`).
2. Share `.media` → `SaveToCameraRoll.saveToCameraRoll(..., exportPermit:, exportReference:)`: `telegram-ios/submodules/ShareController/Sources/ShareController.swift:2671–2685`. Saver сохраняет owner reference и проверяет message scope/permit identity (`telegram-ios/submodules/SaveToCameraRoll/Sources/SaveToCameraRoll.swift:367–415`).
3. После authorization и preparation повторяются guards, а финальный `permit.perform(.exportEffect)` вызывается **изнутри** отложенного Photos change block: `telegram-ios/submodules/SaveToCameraRoll/Sources/SaveToCameraRoll.swift:175–257,340–363`. Это охватывает image, video и paired live-photo resource; только claimed successful save выдаёт terminal 1.0.
4. `ShareControllerNode.transitionToAdmittedProgress` требует этот receipt и проверяет generation/permit после animation completion (`telegram-ios/submodules/ShareController/Sources/ShareControllerNode.swift:34–64,2093–2109`). Actual timestamp Copy callback вызывает guarded helper, включая проверку перед pasteboard write и copied notification (`ShareControllerNode.swift:68–90,837–846`).

Следовательно, известный на момент запроса отсутствовавший Photos/Share guard больше не является pending source stitch. Этот вывод относится к двум запрошенным terminal boundaries; UIKit/Photos execution им не сертифицирован.

## Regression evidence и выполненные проверки

Прочитаны authored native regressions:

- CMC-01/06: `telegram-ios/Tests/ComposerHarness/Tests/HarnessComposerSelectionActionTests.swift:118–254` — actual Format Date/Translate, production Mention completion, whole rich document/one undo, same-flat-range ABA, replacement draft и partial-unit refusal.
- CMC-07/08: `telegram-ios/submodules/TextFormat/Tests/ExteralessComposerProducerTests.swift:19–79`; `telegram-ios/Tests/ComposerHarness/Tests/HarnessComposerPlainPasteTests.swift:41–168` — grammar/UTF-16/explicit attributes, actual plain-paste входы и raw-code undo.
- CMC-02/13: `telegram-ios/submodules/TelegramUI/Tests/Chats/ChatAdmissionProducerTests.swift:17–108`, `telegram-ios/submodules/TelegramUI/Tests/Chats/ChatEditProducerTests.swift:11–42`, `telegram-ios/submodules/TelegramCore/Tests/EnqueueAdmissionTests.swift:8–37` — typed rejection/partial batch, operation-owned cleanup, held reads и token cutover.
- CMC-03/04/09/10: `telegram-ios/submodules/TelegramUI/Tests/ChatMedia/ChatMediaRemediationNativeTests.swift:15–270` — Core in-memory permission reads, held media/prompt callbacks, exact 8.25 sample и rich medium B. Ограничение destination-draft coverage указано в остаточном CMC-03.
- CMC-05: `telegram-ios/submodules/TelegramUI/Tests/Chats/ChatSoundProducerTests.swift:31–74` — shared options matrix; media Schedule bridge coverage отсутствует.
- CMC-11/12/14/15: `telegram-ios/submodules/TelegramUI/Tests/Chats/ChatCallProducerTests.swift:12–74`, `telegram-ios/Tests/Exteraless/BrowserGestureContractsTests.swift:11–47`, `telegram-ios/submodules/TelegramUI/Tests/Player/PlayerEndActionGateTests.swift:8–239`, `telegram-ios/submodules/TelegramCore/Tests/ExteralessOutgoingChatTextTests.swift:61–77`.
- Запрошенный FU-02 tail: `telegram-ios/submodules/TelegramUI/Tests/FeedTests/FeedTerminalExportTests.swift:69–186` — held authorization/preparation/Photos callback, receipt и timestamp sink. Fixtures authored, execution не выполнялся.

Выполнено offline, с timeout 30 s на команду:

- `python -B docs/wave-2/tests/chat_composer_remediation.py` — **PASS source wiring**, `Edit owner handoff: APPLIED`.
- Read-only сопоставление post-patch fragments `chat-review-integration.patch` — **APPLIED: 6 files / 13 hunks**.
- Toolchain discovery — `swift=None`, `swiftc=None`, `xcodebuild=None`.
- Проверка документа — **PASS**: UTF-8/whitespace, все 15 статусов, существование full-path references и допустимые номера строк; hash старого report совпал.

Новый executable fixture не создавался. CI, network, real accounts и external plugins не использовались. Native regression execution и visual acceptance остаются непроверенными.

Контроль read-only старого отчёта: `docs/wave-2/reviews/chat-media-composer.md`, SHA-256 `b97a1e4bf89ebc400405adf3297209377776db5b78075875e42e72fa9c606c7a`.

Контроль cited source/test snapshot: **93 full-path references / 71 уникальный файл**. SHA-256 отсортированного списка `path + NUL + SHA256(file bytes) + LF`: `5a8a4a838f9b5be06a0d1b69181822674e70d1a203868f09869c944ce711be11`. Повторная проверка ранее снятых 69 source hashes перед финализацией совпала.
