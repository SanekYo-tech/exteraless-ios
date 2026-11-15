# CMC-01 / CMC-06 / CMC-07 / CMC-08 — composer remediation

2026-11-15. Working-tree source changes; **Swift/XCTest не запускались**: Windows, `swift`, `swiftc`, `xcodebuild` отсутствуют. Старое review — read-only. CI и commits не выполнялись.

## Применено

- **CMC-01:** `openDateEditing` получает `ChatTextInputPanelNode.beginNativeDateEditing()` **до** показа picker. В native completion вызывается `nativeEdit.apply(result.time)` и восстанавливается только input mode. `0` снимает marker, остальные значения → `applyRichTextLink(dateMarkdownURL(timestamp:), to: selection)`. Ни native add, ни remove не проходят через `ChatTextInputState(inputText:)`/flat caret. Проверяются текущие panel, chat/thread, edit ID, node identity, document и обе input revisions.
- **CMC-06:** Date/Mention/Translate используют `RichTextEditorChatInputNode.SelectionSnapshot`: Core `selectedGlobalRange()`, точные covered `DocumentTree` text nodes и `runs(for:)`, immutable document, synchronous selection revision, content revision и single-use completion. Cell/caption/details title+body/quote author не читаются через `composerSelectedRange`. Перевод заменяет captured Core range через существующий `replaceRange`; смена selection/draft/IME делает completion недействительным. Legacy selected Translate также использует captured range и не заменяет весь draft при исчезнувшем выделении. Content-equal unfocused echo не переводит off-axis selection на flat axis.
- **CMC-07:** все **6** caption sites в `LegacyMediaPickers.swift` вызывают `exteralessComposerCaption`; native media picker использует тот же legacy asset-result producer. Forward comment вызывает `exteralessComposerForwardComment`. Оба producer используют существующий attributed Neko/Telegram parser, сохраняют native trim/split/entity semantics. Date-атрибут теперь входит в protected spans parser.
- **CMC-08:** literal-destination guard стоит перед plain transformer в InputDec и canvas, а в legacy chat panel — перед markdown detection/latch/cleaning. `ChatInputTextView.isLiteralTextDestination(_:)` — общий guard paste/commit. Raw Markdown сначала передаётся parser; code blocks/inline code не чистятся, href чистится destination-only seam, plain prose spans чистятся с сохранением CharacterAttributes. При disabled/unrecognised Markdown source-aware shield сохраняет fences/backticks/link labels. Оба native backend сохраняют raw-source undo; canvas step 2 также проверяет captured content revision/selection.

В non-InputDec native canvas add/read-back/remove date/link сохраняют authored underline; remove возвращает цвет соответствующей caption/author/body region. Shared mapper больше не отбрасывает explicit `underlineStyle` только из-за наличия link (InputDec уже восстанавливал его отдельным read-back pass).

На проверке CMC-06 реальный `Document.replacingRange` копировал media за пределами replacement через `regeneratingIDs`, теряя `displayMode`. Supporting kernel hunk — **одно поле** `displayMode: m.displayMode` в существующем media initializer `DocumentFragment.swift`; fixture использует two-item slideshow со spoiler на втором item.

Граница CMC-06: fragment splice ядра поддерживает одну cell/caption либо целый unit. **Translate показывает disabled при частичном пересечении границы media/table (включая несколько cells)**; entry и completion проверяют ту же capability. Copy/Paste расширяют такой range, что для выбранного текста Translate удалило бы невыделенное содержимое. Paragraph, отдельная cell/caption, details title/body и author остаются действующими; отрицательный producer fixture проверяет отказ без document mutation. Это явное ограничение native fragment splice, не flat-zero fallback.

## Стык Chat-owner: Edit parser (применяет владелец CMC-13)

На контрольном чтении владелец уже заменил `convertMarkdownToAttributes` на `exteralessComposerMarkdown` внутри Edit (бывшая строка 2129, сейчас около 2145). Нужен **следующий точечный delta в ЕГО edit body**:

```diff
- let text = trimChatInputText(exteralessComposerMarkdown(expandedInputStateAttributedString(editMessage.inputState.inputText)))
+ let text = trimChatInputText(exteralessComposerMarkdown(expandedInputStateAttributedString(editMessage.inputState.inputText), respectDisableMarkdown: false))
```

Объявление уже применено в `telegram-ios/submodules/TextFormat/Sources/ExteralessComposerMarkdown.swift`:

```swift
public func exteralessComposerMarkdown(
    _ value: NSAttributedString,
    settings: ClientSettings = .shared,
    respectDisableMarkdown: Bool = true
) -> NSAttributedString
```

`respectDisableMarkdown: true` — обычная text-send boundary. `false` — прежние always-parse getEntities-style boundaries: caption, edit, forwarding comment. Это **выбор grammar**, не удаление explicit formatting. Android `ChatActivityEnterView.processSendingText` читает disable отдельно; общий `MediaDataController.getEntities` выбирает Neko grammar. Другие изменения edit/send/draft принадлежат Chat-owner.

## API / hunks, которые нужно сохранить при интеграции

Пути ниже относительно `telegram-ios/`:

| Файл | Точечная область |
|---|---|
| `submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift` | Только `openDateEditing` (от `let inputPanel` до native completion `return`); общий date detector/picker и legacy branch сохранены |
| `submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift` | Date/Mention native menu eligibility; `_translate`; `selectionActionScope`, `beginNativeDateEditing`, `beginSelectionTranslation`, `beginSelectionMention`; paste transformer wiring и legacy paste guard |
| `submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer/Sources/RichTextEditorChatInputNode.swift` | `SelectionSnapshot`, `captureRichTextSelection`, `isRichTextSelectionCurrent`, `applyRichTextLink(_:to:)`, `replaceRichTextSelection(_:with:)`, `canReplaceRichTextSelection`; off-axis content-equal echo guard; `.date` eligibility |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEditorProtocol.swift` | Read-only `documentRevision`, `selectionRevision`, `hasMarkedText`; комментарий существующего Core global range исправлен |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView.swift` | Revision observations только: role writes/document funnel/selection funnel; `hasMarkedText` |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorUIKit/RichTextEditorView.swift` | Canvas content revision, synchronous selection callback revision, marked-text read |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Clipboard.swift` | Literal guard перед `transformer(text)` |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+SurfaceGate.swift` | `codeLanguage` также literal destination |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorUIKit/Canvas/DocumentCanvasView+Clipboard.swift` | Literal guard по настоящим touched regions; parsed-target cleaning; raw step-2 revision check |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorUIKit/Canvas/DocumentCanvasView+Links.swift` | Preserve underline; remove-link color по text region |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorUIKit/Mapping/AttributedStringMapper.swift` | Одна read-back ветка: explicit underline сохраняется и на link/date/mention |
| `submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorCore/Model/DocumentFragment.swift` | Только перенос `displayMode: m.displayMode` при media copy в selection replacement |
| `submodules/TelegramUI/Components/Chat/ChatInputTextNode/Sources/ChatInputTextNode.swift` | Из существующего insert guard выделен `isLiteralTextDestination(_:)`, используемый panel перед paste |
| `submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ExteralessChatInputHelpers.swift` | `exteralessCleanPastedPlainText`, `exteralessComposerPasteFragment`, per-run prose cleanup; cleaner принимает injectable settings |
| `submodules/TextFormat/Sources/ExteralessComposerMarkdown.swift` | `respectDisableMarkdown`, protected date, caption/comment producers |
| `submodules/LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift` | Только 6 caption text/entities producer sites |
| `submodules/TelegramUI/Sources/ChatControllerForwardMessages.swift` | Только comment parse/split/entities loop |

Новые native APIs не добавляют Postbox/Account type erasure. Существующие Chat/UI/AI/retention patches не переустанавливались целыми файлами; AI button visibility находится вне изменённых Format/paste hunks.

## Fixture / BUILD handoff координатору

**Новые файлы** (Bazel BUILD в этой подзадаче не редактировался):

1. `telegram-ios/Tests/ComposerHarness/Tests/ComposerSelectionActionFixture.swift` — clone только presentation endpoints, все editor/state callbacks forwarded; per-test settings restore с override presence.
2. `telegram-ios/Tests/ComposerHarness/Tests/HarnessComposerSelectionActionTests.swift` — actual Format Date add/remove + one undo; actual Format Translate в paragraph/cell/caption/details title/body/author; production Mention completion; held same-flat-range ABA/draft replacement.
3. `telegram-ios/Tests/ComposerHarness/Tests/HarnessComposerPlainPasteTests.swift` — actual plain paste двух chat input веток, real CommonMark producer, inline code, fenced source, authored URL label, ordinary URL control, raw-source undo, disabled Markdown.
4. `telegram-ios/submodules/TextFormat/Tests/ExteralessComposerProducerTests.swift` — caption/comment producers, Neko vs Telegram, emoji UTF-16 ranges, explicit attributes, disable separation, split boundary.
5. `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Tests/RichTextEditorUIKitTests/CanvasPlainPasteLiteralTests.swift` — actual canvas paste guard для inline/mixed code, undo, synchronous selection ABA, off-axis caption Date add/remove с сохранением underline/media/color.
6. `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Tests/RichTextEditorCoreTests/DocumentSelectionMediaMetadataTests.swift` — реальный kernel replacement рядом со slideshow, на верхнем уровне и внутри authored quote; полный media payload сохранён.

**Дополнен существующий** `telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Host/Tests/Engine/ChatLinkIngressTests.swift`: actual engine plain paste literal/prose, two-step raw undo, synchronous revisions/undo.

В `RichTextEditor/Tests/RichTextEditorUIKitTests/AttributedStringMapperLinkTests.swift` обновлены два старых expectations, которые считали явно заданный `underlineStyle` автоматически добавленным link styling. Link-only controls остаются без underline; comment в `MapperTests.swift` приведён к тому же контракту.

BUILD needs:

- `//Tests/ComposerHarness:ComposerHarnessTestsLib`: новые файлы входят в существующий `Tests/**/*.swift` glob; добавить direct deps `//third-party/exteraless:ExteralessCore` и `//submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer` (прочие imports уже покрыты).
- `//submodules/TextFormat:TextFormatTestsLib`: новый файл уже входит в glob. Для small native target `ExteralessComposerTestsLib` добавить `Tests/ExteralessComposerProducerTests.swift` в explicit `srcs`; новых deps нет.
- `RichTextEditorUIKitTests` SwiftPM и `InputDecHostTests` XcodeGen получают файлы существующими directory targets. Production sources используют уже существующие direct deps; новых module edges нет.
- `RichTextEditorCoreTests` SwiftPM: новый kernel fixture входит в существующий directory target, дополнительных BUILD/deps нет.

На Mac запускать только named classes/targets отдельными bounded процессами (≤30 s на прогретом fixture runtime), без параллельных XCTest; для `xcodebuild test` обязательно `-parallel-testing-enabled NO`. Здесь Accounts/network/real Simulator не запускались. Fixture runtime / UIKit typecheck / visual acceptance остаются проверкой координатора, а не следствием source checks.

## Локальные проверки

- `git diff --check` по изменённым tracked Swift paths: exit 0.
- Toolchain discovery: `swift=None`, `swiftc=None`, `xcodebuild=None`.
- `python -B docs/wave-2/tests/chat_composer_remediation.py` (30 s cap): **PASS owned source wiring**, `Edit owner handoff: PENDING respectDisableMarkdown: false`; **не Swift compile/test pass**. Edit handoff проверяется отдельно от принадлежащих этому исполнителю hunks.
