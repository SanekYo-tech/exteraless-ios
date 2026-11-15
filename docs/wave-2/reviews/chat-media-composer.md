# Chat / media / browser / composer — независимое ревью

2026-11-15. **REQUEST CHANGES: 4 P1, 11 P2; P0 не установлен.** Выводы ниже подтверждены исходниками, а не выполнением UIKit. Проверен рабочий tree, включая незакоммиченные файлы; HEAD на контрольном чтении — `4431b7dc48cef1f2b9f2dac9601dc900953abc0d`. Другие владельцы продолжали интеграцию во время ревью.

Прочитаны `telegram-ios/AGENTS.md`, полный `telegram-ios/CLAUDE.md`, полный RichTextEditor `CLAUDE.md`, инструкции его engine host, `Tests/ComposerHarness/CLAUDE.md`, Chat freeze/handoff/ledger/receipts и соседние AF/TLN/PR reviews. Изменение reviewer — только этот файл.

`A/` ниже означает `third_party/exteraless-android/TMessagesProj/src/main/`. Число receipts и наличие setter/callsite не использованы как доказательство parity. FPP-01 оставлен отдельному reviewer; AF-01…06, TLN-01…11 и PR01…14 не заведены повторно. Отдельно обозначены дефекты существующих native consumers, в которые теперь входят новые Chat actions.

## P1

### CMC-01 — P1: Date из native Format пересоздаёт весь rich draft через legacy projection

**Source:** `telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift:5431–5432`; `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:3811–3825,3851–3868`; `telegram-ios/submodules/ChatPresentationInterfaceState/Sources/ChatTextFormat.swift:154–176`.

**Минимальный сценарий:** native composer содержит heading, обычный абзац с выбранным словом и таблицу/inline photo. Format → Date → подтвердить дату. Новая кнопка вызывает `openDateEditing`, где нет native-ветки, аналогичной `openLinkEditing`. `chatTextInputAddDateAttribute` берёт `state.inputText` и возвращает новый `ChatTextInputState(inputText:)`. Затем `:3867` повторяет такой rebuild ради перемещения caret; это происходит также при Remove.

**Impact:** таблица, media, details и button rows исчезают; heading/list теряют структуру, quote author/nesting не сохраняются. Это намеренно lossy projection, что видно непосредственно в `telegram-ios/submodules/TextFormat/Sources/ChatInputContentConversion.swift:113–158`. Потерянный draft затем и отправляется. Перед этим изменением native Date был no-op; объявление timestamp codec существует, отсутствие API здесь не предполагается.

**Fix/test:** native Date должен работать с native selection и `applyRichTextLink(dateMarkdownURL(timestamp:))` / removal, с проверкой identity и revision после picker; перемещать caret без `inputText` rebuild. Реальные объявления: `RichTextEditorChatInputNode.swift:950–957`, `TextFormat/Sources/MentionDateMarkers.swift:34–39`. Regression через actual Format/picker callback: emoji перед selection, authored quote, table, media reference, date add/remove; все блоки и внешние UTF-16 ranges сохраняются, один undo возвращает исходный document. Существующие conversion tests не вызывают этот обработчик.

### CMC-02 — P1: отказ deleted-quote enqueue оставляет вооружённую очистку draft и не возвращает ошибку Chat

**Source:** `telegram-ios/submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift:957–965`; `telegram-ios/submodules/TelegramUI/Sources/ChatControllerNode.swift:5478–5510`; `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:900–916,1111–1127`; `telegram-ios/submodules/TelegramUI/Sources/ChatHistoryListNode.swift:4830–4853`.

**Минимальный сценарий:** включить reply-to-deleted-as-quote, подготовить reply, дождаться remote delete исходного сообщения с сохранением retained snapshot; заполнить body до native length limit и отправить при Reduce Motion. `RetentionPolicyQuote.prefix` не может добавить author/quote к полному body и возвращает failure (`swift/ExteralessCore/Sources/ExteralessCore/RetentionPolicyQuote.swift:13–18`). Enqueue не вставляет сообщение и выдаёт `[nil]`. Однако очистка уже зарегистрирована с nil correlation: Reduce Motion выключает создание transition correlation (`ChatControllerNode.swift:5658–5661`). Следующее обычное обновление history вызывает её без проверки отправленного ID и стирает текст/reply/forward state.

**Impact:** неотправленный draft теряется; в Chat нет ошибки, объясняющей отказ. `report(error)` обновляет retention error stream, который читает archive controller, а не send caller. `NoError` + nil slots не передают причину. Аналогичный pending cleanup остаётся после полного plugin CANCEL / отказа bot authorization. Это consumer-дефект после уже применённого H8, а не повтор PR о missing hook.

**Fix/test:** передать типизированный результат admission до Chat, отменять только принадлежащие этой операции cleanup/transition при отказе; очищать captured draft только после фактического local enqueue и при совпадении revision. Tiny native fixture: prefix failure → `[nil]` → unrelated history insertion; draft/media/reply остаются, показана native error. Отдельные cases полного CANCEL и частичного batch admission. Local ID означает постановку в очередь, не подтверждённую доставку сервером.

### CMC-03 — P1: Selection More копирует по устаревшим permissions

**Source:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessSelectionActions.swift:16–26,33–46,60–63`.

**Минимальный сценарий:** выбрать сообщение, открыть More при разрешённом Copy; пока sheet открыт, обновить peer/message copy protection, сохранив те же selected IDs. `canCopy`/`canForward` вычислены только при построении sheet. При нажатии wrapper проверяет лишь `selectedIds == ids`; Copy непосредственно пишет сохранённый текст или rich fragment в pasteboard.

**Impact:** локальный Copy/export restriction обходится после отзыва, включая rich content. Forward и Combine также используют уже сохранённые capabilities/content; наличие native destination picker не валидирует сохранённую selection sheet. Изменение protection не обязано менять selected IDs.

**Fix/test:** при действии заново разрешать сообщения и effective peer restrictions в account/thread/presentation scope, проверять версии и eligibility непосредственно перед Copy/Forward/Combine. Regression: показать sheet → включить protection или заменить исходное content → вызвать сохранённый action; ноль pasteboard writes/forward effects, новый разрешённый action работает. Это другой путь, чем исправляемый AI `withCopyCapability`.

### CMC-04 — P1: media action reauthorization не видит private-chat protection

**Source:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessMessageMediaActions.swift:36–46,49–79,118–124`; `telegram-ios/submodules/TelegramCore/Sources/Utils/PeerUtils.swift:255–263`; `telegram-ios/submodules/TelegramCore/Sources/Utils/MessageUtils.swift:538–547`.

**Минимальный сценарий:** начать Copy photo/current frame в разрешённом private chat, задержать fetch/decode; включить защиту чата до completion. `authorize` повторно читает только Peer и Message. `Peer.isCopyProtectionEnabled` для user всегда false, `Message.isCopyProtected()` не читает CachedUserData. `isCurrent` проверяет location/window, но не актуальный `presentationInterfaceState.copyProtectionEnabled`.

**Impact:** завершение записывает media в clipboard несмотря на текущую защиту. Настоящий Chat predicate учитывает оба cached flags (`ChatControllerContentData.swift:984–985`), native toggle пишет `.myCopyProtectionEnabled` (`TelegramCore/Sources/TelegramEngine/Peers/CopyProtection.swift:35–46`). Здесь пропущены оба private-chat flags, а не только второй. Исправление AF-01 в AI scope этот независимый helper не меняет.

У отложенных выходов есть ещё один проход той же границы: QR dialog Copy (`:65`) вообще не вызывает `valid`, а profile confirmation (`:72–79`) повторяет только lifetime check, не protection. Отзыв после показа этих prompts также не учитывается.

**Fix/test:** единый current effective-protection/message-version/account validator перед каждым export и после async hop, включая подтверждение QR/profile. Fixtures с held decode и с уже показанным prompt: `.copyProtectionEnabled`, `.myCopyProtectionEnabled`, message deletion/replacement, account replacement/cancel → ноль clipboard/profile effects. Не подменять это проверкой старого message object.

## P2

### CMC-05 — P2: Bool→Bool? перенос не завершён у реальных send producers

**Source:** `telegram-ios/submodules/TelegramUI/Sources/ChatController.swift:2730–2749,9004–9006,9264,9422,10927–10936`; `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerMediaRecording.swift:232–236,410–413,755–756`; `telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/OutgoingMessageWithChatContextResult.swift:29–34`.

Нижний `withNotificationOverride(false)` и default-only-if-absent исправлены, но вызывающие пути продолжают смешивать отсутствие выбора с false:

1. **Обычный tap по GIF inline-search** передаёт `false` (`TelegramUI/Components/ChatEntityKeyboardInputNode/Sources/GifPaneSearchContentNode.swift:231–235`; также `ChatEntityKeyboardInputNode.swift:1701,2320`). Через `sendBotContextResultAsGif` он становится explicit audible attribute. При `chats.silentMessageByDefault=true` GIF получает `flags=[]`, тогда как обычный text получает `.muted`. Android tap уже разрешает default: `A/java/org/telegram/ui/Components/EmojiView.java:2139–2146`.
2. **Обычная отправка круглого видео** вызывает `sendVideoRecording()` без override, но callback превращает nil в stored chat Bool `false` до `transformEnqueueMessages`. Получается тот же audible attribute вместо применения общего default.
3. **Schedule text без изменения sound checkbox:** picker seed берётся только из native `interfaceState.silentPosting`, без общего default; false возвращается как явный override. Обратная потеря есть в rich attachment schedule: `ChatControllerOpenAttachmentMenu.swift:1206–1215` выбирает overload `(time, repeatPeriod)`, игнорирует весь sound choice и передаёт hardcoded false; repeatPeriod также теряется. Даже выбранное пользователем silent=true там не доходит до enqueue.
4. **Explicit Send with sound для media при native chat silentPosting=true:** первый transform сохраняет false из parameters, затем `sendMessages` повторно вызывает default transform и заменяет его на true (`:9005,9264`).

**Impact:** выбранный/ожидаемый audible-versus-silent intent меняется в зависимости от вида сообщения. Это вывод о native атрибутах и будущем request flag, не утверждение об исполненной сервером доставке.

**Fix/test:** протянуть optional intent до каждого producer, разрешать default один раз, seed schedule UI эффективным default и сохранять его явный результат целиком; повторный transform не должен переписывать уже явный override. Один producer-level matrix: text/photo/round/GIF/inline/forward/schedule × nil/true/false × global/native defaults, с fake enqueue и проверкой окончательных attributes. Нынешний outgoing test проверяет нижний value helper, а не эти вызовы.

### CMC-06 — P2: native Translate/Mention используют flat selection, в которой нет table/caption/details

**Source:** `telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift:5449–5454,5499–5518,5604–5615`; `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Selection.swift:48–85,154–167,204–207`.

**Минимальный сценарий:** выделить слово в таблице или media caption native composer, открыть Format. Меню строится по настоящему nonempty engine selection; новые действия доступны. Но `composerSelectedRange` для этих регионов возвращает конец flat text с length 0. Mention выходит до открытия picker из-за `node.selectedRange.length > 0`; Translate передаёт пустую строку из `current.inputText`, а не выделенное слово. Details и quote author имеют тот же off-axis статус.

**Impact:** добавленные действия не работают в обычных rich regions. Кроме того, translation apply использует уже текущую selection, не исходную; при её изменении ветка length 0 заменяет весь current draft новым plain state (`:5514–5518`). Это не AF-03/05 о display resolver: здесь ошибка на composer coordinate boundary.

**Fix/test:** native selected fragment/range + revision lease, kernel mutation для Mention и структурный replace для Translate. Проверить реальные menu actions на cell/caption/details/author, на обычном paragraph и после смены selection/draft. `ChatTextInputStateReplaceRangeTests` проверяет адресуемые flat replacements и не покрывает off-axis selection.

### CMC-07 — P2: выбранный Neko Markdown parser обходится в captions, edits и forwarding comment

**Source:** `telegram-ios/submodules/LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift:479,570,638,708,761,1003`; `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:2129`; `telegram-ios/submodules/TelegramUI/Sources/ChatControllerForwardMessages.swift:149`.

**Минимальный сценарий:** default `chats.markdownParser=1`; набрать `x**bold**y [title](https://example.test/)` как photo/video caption или новый текст при Edit. Эти producers вызывают `convertMarkdownToAttributes`, обходя `exteralessComposerMarkdown`. Обычный новый text использует выбранную Neko grammar, caption/edit/forward comment — старую Telegram grammar.

**Original:** `A/java/org/telegram/messenger/MediaDataController.java:7652–7653` выбирает Neko внутри общего `getEntities`; grammar задана `A/java/tw/nekomimi/nekogram/helpers/EntitiesHelper.java:19–28`. Различие именно на этом маленьком тексте уже закреплено в `telegram-ios/submodules/TextFormat/Tests/ExteralessComposerPolicyTests.swift:15–24`. Глобальное действие Android disableMarkdown на captions здесь не предполагается: основание finding — выбор grammar.

**Impact:** одно пользовательское значение parser даёт разные текст/entities при разных основных действиях; редактирование не следует grammar, которой сообщение было создано.

**Fix/test:** общий native attributed parsing entry на соответствующих new-send/edit/caption/comment boundaries, сохраняя отдельные правила explicit formatting/disable. Tests должны вызывать actual producers, проверять текст и UTF-16 entities с emoji prefix, а не только два parser functions.

### CMC-08 — P2: plain paste очищает URL внутри literal code до срабатывания code guard

**Source:** `telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift:1232–1239,5942–5955`; `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Clipboard.swift:417–424,609–621`.

**Минимальный сценарий:** native body paragraph содержит inline code; поставить caret в него и вставить plain `https://example.test/?utm_source=x`. `pasteTransformedPlainText` проверяет только block shape/style и вызывает host transformer. Тот сначала очищает неатрибутированную строку, поэтому возвращает изменённый fragment даже при отключённом Markdown. `isLiteralTextDestination` из surface gate на этом пути не вызывается. В legacy composer panel preclean (`:5943`) также выполняется до передачи в text view, уже потерянный query его `insertText` guard не восстановит.

Второй простой вариант — paste fenced code в обычный paragraph: URL очищается до CommonMark parser, пока ещё нет code атрибутов. Destination-only `Document.rewritingLinkTargets` позднее сохраняет уже изменённое code body.

**Impact:** literal code/source URL меняется вопреки заявленному code skip; protected rich-fragment и final-IME tests этого не проверяют.

**Fix/test:** проверять literal destination до plain transformer; для markdown сначала выделять структуру/code и чистить только допустимые URL destinations/spans. Реальные plain-paste fixtures обеих input веток: inline code, fenced code, plain URL control, authored link label; raw code bytes и соседние entities сохраняются, undo не теряет исходник.

### CMC-09 — P2: Copy current frame берёт timestamp из share-link DTO с порогом 10 минут

**Source:** `telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift:1748–1751`; `telegram-ios/submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift:1072–1093`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessGalleryChatActions.swift:32–36`.

**Минимальный сценарий:** открыть 20-секундное video, остановить на 8-й секунде, Copy current frame. `shareMediaParameters` возвращает nil для duration < 600; bridge подставляет timestamp 0. Для длинных видео этот DTO ещё и округляет время до Int32 секунд.

**Impact:** копируется начало вместо текущего кадра. В оригинале используется `videoPlayer.getCurrentPosition()` (`A/java/org/telegram/ui/PhotoViewer.java:5901–5916`), независимо от длины ролика.

**Fix/test:** отдельный live playback-time accessor для image action, без изменения native share-link semantics. Tiny fake status 20 s / 8.25 s должен передать image-generator ровно 8.25, с cases отсутствующего status, смены item и отмены; успешное декодирование реального кадра требует native test.

### CMC-10 — P2: Gallery image actions теряют конкретный medium rich message

**Source:** `telegram-ios/submodules/GalleryUI/Sources/ExteralessGalleryMessageActions.swift:6–18`; `telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift:1751`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessMessageMediaActions.swift:19–27`.

**Минимальный сценарий:** rich message содержит images A и B; тапнуть B, затем Copy photo / Scan QR / Set profile photo. Настоящая Gallery открывает B по `.richTextMedia(id)` (`telegram-ios/submodules/GalleryUI/Sources/GalleryController.swift:65–75`). Новый request передаёт только Message, не `mediaSubject`/media reference; helper выбирает первый image из `effectiveMedia`. Для rich message с image и video даже Copy frame может выбрать image.

**Impact:** export/action работает с другим вложением. `isCurrent` сравнивает только message ID, поэтому не обнаруживает смену medium внутри того же rich message. Это не AF-03 с preview/full InstantPage.

**Fix/test:** передавать точную native media reference/subject и item generation, повторно проверять их перед выходом; named-but-absent medium должен отказать, как штатная Gallery. Два маленьких разных resource IDs/images в одном InstantPage: выбран B → fetch/output B; смена selection или edit resource → старый callback ничего не публикует.

### CMC-11 — P2: call confirmation публикуется по старому primary-account snapshot

**Source:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatCallConfirmation.swift:8–26`; applied caller — `telegram-ios/submodules/TelegramUI/Sources/AccountContext.swift:1014–1017`.

**Минимальный сценарий:** запросить call из A, задержать `Peer.Peer` read; `activeAccountContexts |> take(1)` уже выдал A. Переключиться на B, затем отпустить read. `accounts.primary === context` сравнивает сохранённый A snapshot и пропускает global prompt поверх B. Подписки, отменяющей старое намерение на account change, нет.

**Impact:** чужой по текущему presentation scope prompt переживает смену аккаунта. Fresh one-shot check на OK предотвращает обычный call A, пока primary=B, но A→B→A снова допускает старое намерение; epoch/lifetime не сохранён. Cancel самого показанного alert не вызывает call — ему не приписывается обратное.

**Fix/test:** operation/presentation lease от входа до конечного native call, continuous account/foreground invalidation, check после peer read и после existing-call replacement prompt. Controlled native signal fixture: held read → switch/cancel → zero presentations/calls; same identity reactivation не оживляет старую операцию, ordinary confirm выполняется один раз. Это отдельная call lifetime, не FPP-01 Settings factory.

### CMC-12 — P2: Disable browser gestures не закрывает modal pull-down/minimize

**Source:** `telegram-ios/submodules/BrowserUI/Sources/BrowserScreen.swift:1704,1724–1728,1745–1747`; `telegram-ios/submodules/Display/Source/Navigation/NavigationModalContainer.swift:302–309,585–632`.

**Минимальный сценарий:** включить disableInAppBrowserGestures, открыть страницу на compact layout и потянуть card вниз. Browser устанавливает только `disablesInteractiveTransitionGestureRecognizerNow`; это horizontal/navigation gate. Реальный modal container проверяет другое свойство — `disablesInteractiveModalDismiss`; Browser его не устанавливает. Достигнув threshold, container вызывает `requestMinimize` без проверки Chat setting.

**Impact:** заявленная блокировка interactive browser dismissal не действует, хотя WebKit back/forward действительно выключены. Реальный navigation graph создаёт этот container (`Display/Source/Navigation/NavigationController.swift:641`); это не предположение по старому API. Original `ArticleViewer.handleTouchEvent` отказывает до tracking (`A/java/org/telegram/ui/ArticleViewer.java:1187–1191`).

**Fix/test:** связать live preference с настоящим modal gesture gate, сохранив кнопки и page scrolling. Native fixture проверяет обе независимые gate families; recorded compact-browser pull-down/back-swipe при on/off нужен для visual acceptance.

### CMC-13 — P2: завершение Edit A использует live state B и закрывает новый editor

**Source:** `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:2087–2105,2198–2229`.

**Минимальный сценарий:** нажать Save в Edit A, удержать один из двух async reads; закрыть Edit A и открыть Edit B, выбрать новое media B. Первый callback продолжает с captured `editMessage=A`, но берёт `editingUrlPreview` и `editMessageState.mediaReference` из текущего B. Затем `pendingUpdateMessageManager.add(messageId:A, …media:B…)` может обновить A чужим вложением. Финальный state update без проверки ID очищает Edit B даже когда второй read A вернул nil.

**Impact:** потеря нового edit draft и смешение двух редактирований. Это существующий native consumer, достижимый новыми Double-tap Edit/selection actions; проверки eligibility перед их запуском не связывают этот callback с A. TLN-07/09/10 касаются других SDK/edit boundaries.

**Fix/test:** capture полного edit request и generation, привязка async reads/commit/cleanup к account, message ID и draft revision; ни один read live state B не должен менять A. Two-message in-memory fixture с queue barriers: A save → B edit → release A; B и его media остаются, A получает только A snapshot либо отменяется. Отдельно missing/deleted A и отмена до pending-update admission.

### CMC-14 — P2: старый playback completion управляет новым playlist item

**Source:** `telegram-ios/submodules/TelegramUI/Sources/SharedMediaPlayer.swift:214–224,253–273,450–475`.

**Минимальный сценарий:** A заканчивается и ставит `Queue.mainQueue().async` из action-at-end; до исполнения блока native Next устанавливает B. При `chats.dontAutoPlayNextVoice=true` callback A проверяет уже B в `stateValue` и вызывает `self.playbackItem?.pause()`, то есть останавливает B. Без этого flag старый блок может продвинуть уже новый item ещё раз.

**Impact:** ручной Next/новый playback вмешивается в отложенное завершение предыдущего. Gallery background identity policy и Core seek lease здесь не участвуют. Async shape существовал в native consumer; новая stop-policy не устраняет эту дыру.

**Fix/test:** capture playback item identity/generation при регистрации end action и проверять её в queued block до любых playlist effects. Fake player callback + controlled main queue: end A → replace by B → drain; B играет, zero extra next/pause. Completion действующего A сохраняет правильную loop/stop/advance semantics.

### CMC-15 — P2: Pangu меняет аргументы bot command, который original исключает целиком

**Source:** `telegram-ios/submodules/TelegramCore/Sources/PendingMessages/ExteralessOutgoingChatText.swift:8–29`; `swift/ExteralessCore/Sources/ExteralessCore/ChatPanguPolicy.swift:59–60`.

**Минимальный сценарий:** enablePanguOnSending=true, отправить `/run 漢ABC`. Native parser может защитить `.BotCommand` span `/run`, но хвост остаётся обычным текстом и превращается в `漢\u{2009}ABC`. Оригинал проверяет `text.startsWith("/")` до любых spacing/entity edits и возвращает весь input (`A/java/tw/nekomimi/nekogram/utils/StringUtils.kt:38–48`).

**Impact:** меняется command payload — строковый аргумент, identifier/поисковый запрос бота. Это source parity defect, не пожелание о другой ширине пробела.

**Fix/test:** сохранить original whole-command exclusion на outgoing boundary. Добавить к реальному `exteralessPrepareOutgoingChatText` cases command с entity и без неё, styled аргумент и plain positive control; команда/UTF-16 entities byte-identical, обычная prose получает thin space. Rich/secret/URL/code/hashtag exclusions должны остаться.

## Applied versus pending на контрольном чтении

| Boundary | Фактическое состояние |
|---|---|
| Optional sound intent | **Applied:** `AccountContext/Sources/AccountContext.swift:1761–1771`; `ChatControllerInteraction.swift:219,412`; `ChatController` transform/inline/send body. Это не missing-symbol issue; остаточные consumer defects — CMC-05. |
| Header/call entry | **Applied:** `PeerInfoData.swift:2817–2825`, `TelegramUI/Sources/AccountContext.swift:1014–1017`. Call helper lifetime — CMC-11. |
| App URL ingress | **Applied:** `AppDelegate.swift:2897–2910,2937–2951,3284…` вызывает `clientCleanOpeningURL`; подготовка settings и exact recovery-route guard присутствуют. Старое «App hunk pending» из `chat.md` уже не отражает tree. |
| Share URL ingress | **Applied:** `ShareExtensionContext.swift:488–494` чистит `.text` DTO и additionalText; `Telegram/Share/ShareRootController.swift:54` конфигурирует тот же filter cache. Uploaded media не проецируется в строку. |
| Archive aliases | **Applied:** `CloudLegacySettingsArchive.swift:17–20,54,95–99,116–130`; typed rules в `CloudLegacyRules.swift:63–68`. Migration больше не только отдельно лежащий helper. |
| Canonical translation setting | **Applied:** Chat policy + AI reader, Main/Share preparation migration. Независимое AI устранение AF продолжалось; его полная closure здесь не сертифицируется. |
| translateInSheet | **Applied к финальной сверке:** helper и double-tap (`ExteralessMessageGestures.swift:58`), а также общий `AI/ExteralessAIIntegration.swift:437–448`, до которого доходит обычный menu action. Owner передаёт actual capability/effective language; helper теперь использует whole rich source. Более раннее отсутствие literal hunk в AIChatActions не означает pending после этой нижней интеграции. |
| Native menu visibility hunks | **Applied к финальной сверке:** `ChatInterfaceStateContextMenus.swift:1000,1344,1784,1934` — favorites/copy-photo/copy-link/report; `Chat/ChatControllerOpenMessageContextMenu.swift:148` — reaction-panel gate. `exteralessMessageContextActions` insertion уже есть (`:2463`). |
| TL explicit audible attribute | **Applied:** `TelegramCore/Sources/ExteralessRuntime/TLMediaServices.swift:271` безусловно добавляет notification attribute для resolved Bool, включая flags=[] при false. Старая pending пометка этого hunk устарела. |
| Native graph | Source imports применены, но просмотренные `BrowserUI/BUILD` и `ShareExtensionContext/BUILD` ещё не объявляют соответственно прямые Core/TextFormat edges из handoff. Полный graph/typecheck — отдельный build-owner gate; это не заявленный compiler failure. |

## Остальная проверенная семантика

- **Defaults/migration:** сверены Kotlin `ChatsConfig.kt:36–83,149–272,386–406`, Na/Neko declarations и настоящие consumers. Shape=1; HD/HDR=true; bottom=1; askBeforeCall/autoPauseVideo=true; silence=false; grammar=1. Legacy quality **только 1** становится preferOriginal=true; 2…5 остаются действующими bands. HideReactions fan-out, inverse reply-background и bottom-button alias имеют original precedence; не создано четыре дополнительных toggles. Typed import теперь действительно вызывает projection.
- **Quality/HDR:** `ChatMediaPolicy.videoQuality` соответствует descending/fallthrough bands `VideoPlayer.java:504–534`; native consumer ждёт реальные available qualities, explicit choice отменяет default subscription. Highest-available — явно описанная platform adaptation. HDR читает original resource через UIImageReader; parent — реальный view-backed TransformImageNode (`ChatImageGalleryItem.swift:280–306`), capture flag установлен на его layer (`:469`, `Display/Source/TransformImageNode.swift:32–38`). Нет основания объявлять это ошибкой старого UIKit API; реального HDR/device/zoom pass нет.
- **MP4:** Files metadata load имеет cancellation/5-second document fallback; URL security scope закрывается once. Legacy as-file resource остаётся passthrough, Video metadata добавляется без пересоздания caption/media value (`LegacyMediaPickers.swift:927,960–963,1003–1047`). Files picker разделяет document/video/music families. Для legacy смешанного Send as File album отдельного executable receipt нет: исходный groupedId проходит в оба типа; это остаётся конкретным regression case для native verification, а не утверждением о полученной server error.
- **Rich/UTF-16:** new-send route использует authoritative `ChatInputContent`, rich InstantPage не прогоняется через Pangu. Прочитаны quote-inline conversion и `ChatInputQuoteInlineAttributeTests`: expanded/collapsed quote сохраняют custom emoji и specific nested code attribute. Private clipboard tree rewrite сохраняет block/run media payloads, меняет href/button URL destinations; opaque button actions отдельно по native paste convention. Это не исправляет новые legacy callers CMC-01/06 и raw paste CMC-08.
- **Enqueue/plugin:** notification empty-flags value сохраняется и после MODIFY; CANCEL сохраняет исходные nil slots; полный native message case переносит media, inline stickers, reply/quote, thread/group/correlation. Native result-slot helpers тестируются без Account. `enqueueMessagesFromPlugin` bypass не является доказательством request-hook ancestry — этот вопрос остаётся в TLN-owner scope.
- **Actions:** typed double-tap values 0…12 существуют; native gesture/reply path и deferred capability path различаются реально. Local/scheduled/secret eligibility не выводилась только из numeric message ID. Bookmarks хранят full peer key + namespace + ID и account-local references, не message text; их открытие остаётся native navigation. Combine-as-draft и bounded delete-own — заявленные частичные адаптации, не засчитаны как original automatic send/delete или unlimited purge.
- **Delete defaults:** один bitmask 8/4/2/1, original linked fields и indirect `getDeleteMenuChecks` consumer сверены. Native sheet seed и common-group rights/history branches присутствуют; common-group discovery ограничен 100. Само значение checkbox не является выполнением moderation; lifecycle/source rights требуют тех же action-boundary tests.
- **Automatic versus explicit download:** просмотрены оба PrefetchManager, `ExteralessFiltering` automatic-download entries, `MediaAutoDownloadSettings.swift:567–620` и `ToolsAutomaticDownload.swift`. Новый file policy стоит в automatic/predownload decision, не в глобальном `resources.fetch`; явные Gallery/media actions идут своим fetch path. Это source tracing, не network/runtime verification всех экранов.
- **Rendering versus wire:** inspected tail/cache key, reply background invalidation, sticker timestamp container, reaction/spoiler gates, compact GIF и poll-result suffix меняют presentation inputs/layout. Например poll suffix создаёт отдельный `displayedOption` с тем же opaque ID, а не переписывает stored poll. Labelled-frame evidence для clipping/gesture/timing здесь не получено.

## Тесты и предел доказательства

Прочитаны существующие `ChatPolicyTests`, `ChatLinkRulesTests`, `ChatPhase2PolicyTests`, `ChatDeleteMenuDefaultsTests`, `ChatMediaPolicyTests`; native `ExteralessOutgoingChatTextTests`, `ExteralessComposerPolicyTests`, `DocumentLinkTargetsTests`, `ChatLinkIngressTests`, `ChatTextInputStateReplaceRangeTests`, `ChatInputQuoteInlineAttributeTests` и source guard `ComposerFlatRebuildGuardTests`. FPP-01 factory tests и closure verdict принадлежат отдельному reviewer.

Содержательно сильные tests используют production transforms/store: notification flags + unrelated native payload, indexed cancellation slots, real settings register/write/reopen/migrate, recursive document structure, final IME commit/undo. Они не нажимают Date, native selection Translate/Mention, Gallery copy-frame/selected-medium, schedule send producers или async Edit/Call callbacks. `ChatDeleteMenuDefaultsTests.testDefaultSnapshotDoesNotOverwriteLaterUserChoices` проверяет value copies, а не действующий moderation sheet. `ChatLinkIngressTests` не делает plain paste в inline code. Source guard сканирует mutable-copy spelling; это не доказательство отсутствия полного `ChatTextInputState(inputText:)` rebuild в другом модуле.

| Выполненная проверка | Результат |
|---|---|
| `python -B docs/wave-2/tests/chat_receipts.py` (timeout 30 s) | **PASS:** 137 unique records, 4 modules, 75 assigned IDs + отдельные 13+6 reconciliation IDs; 567 inventory records сохранены, ported/verified claims=0. |
| `python -B docs/wave-2/tests/chat_receipts.py --check` (timeout 30 s) | **FAIL:** `fragment is stale`. Generated source anchors/status после owner hunks уже отличаются от сохранённого `chat-parity.json`. Это stale receipt, не Swift failure. |
| Toolchain discovery | `swift=None`, `swiftc=None`. Swift/XCTest/typecheck не выполнялись. |
| Reviewer changes | Только данный Markdown; новых fixture/source files нет. |

Сообщённый координатором Core491 с одним Cloud retry failure, Host150 и Hooks24 green не является запуском этих native paths. Live accounts, external plugins, network и CI в review не использовались. UIKit/device/frames pass и server delivery не заявляются. После source fixes необходимы bounded native regressions перечисленных сценариев; simulator XCTest — без параллельного запуска, с `-parallel-testing-enabled NO`.

### Контрольные SHA-256 прочитанных raw files

Пути относительно repo root; hashes фиксируют reviewed source, а не committed tree.

| Файл | SHA-256 |
|---|---|
| `telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift` | `ea041dfe9291687a72303991afb12d55595b9166a4e4067824d4e8b7803bd100` |
| `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift` | `d2ba37c4c712d6ed367af264b792b4b92f379ea9d37c292fcfed6723dadc81af` |
| `telegram-ios/submodules/TelegramUI/Sources/ChatControllerNode.swift` | `8b9970890c856b6f1817e27eab3c63b1b19ad355439143adc8fabb2661a1aebb` |
| `telegram-ios/submodules/TelegramUI/Sources/ChatController.swift` | `2a56ef5578d533f2b1b5a65ecd782b43d3fc46fdc01653d8647de1e53614d022` |
| `telegram-ios/submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift` | `c296a3c94e75da7050fc099690988db5e5c8bdc8c0a570879ca4ed3e7aa7ae1b` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessSelectionActions.swift` | `e769428514f7e33d23582c60b5c6efd562910c0a586a6437f864a5f7786c5dca` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessMessageMediaActions.swift` | `e50ebf65f19d1250b008321fb5048fa5e27e1a272fb7227f63608e95b73e60d0` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatCallConfirmation.swift` | `99da6e30c9031578424c4563d9ac8c0bf7758afa2b39ff073a448fd774a0446e` |
| `telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift` | `ff90a6a03039ab823c6a818f62dd247c009f4ebcdc12d7830eab28873a98b354` |
| `telegram-ios/submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift` | `f6639205f02f7d4bfa1213d14554a0f6e98679bdfc59c62e8f4baeb94d879ef9` |
| `telegram-ios/submodules/TelegramUI/Sources/SharedMediaPlayer.swift` | `b92b39824e696505695ab40709604a163690086fb8db078e158da91206251a17` |
| `telegram-ios/submodules/TelegramCore/Sources/PendingMessages/ExteralessOutgoingChatText.swift` | `43fac77d276f4f1bd4ec1722c2b6d54098c8d25089924f90f000d34ed7ab9cd4` |
| `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Clipboard.swift` | `06551f7cd31a058b8355c27e3798a70c309735b6115f0a34d9f7dd02ee9ea3cf` |
| `telegram-ios/submodules/BrowserUI/Sources/BrowserScreen.swift` | `635b0feec7c921d5ea33aa6be0d62c158af189a5609f7a617595d869206cf8a2` |
