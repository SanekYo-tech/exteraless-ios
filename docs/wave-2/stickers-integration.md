# Stickers — step 2 source integration

**Применены 9 разрешённых native/rendering/recents/GIF hunks и подключён настоящий
Tools local-favorites backend к picker/menu.** Это source integration, не Swift
build и не visual acceptance. Все parity records сохраняют `ported=false`.

## Применённые callsites

| Source | Изменение |
|---|---|
| `TelegramCore/Sources/State/SynchronizeRecentlyUsedMediaOperations.swift` | Local recent add/remove/clear в той же native transaction, рядом с существующей cloud sync operation |
| `TelegramUI/Components/Chat/ChatEmptyNode/Sources/ChatEmptyNode.swift` | Реальный greeting tap-to-send проверяет `disableGreetingSend`; artwork остаётся native |
| `TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift` | Display-only `ExteralessEmojiRendering.attributedText` перед `InteractiveTextNodeLayoutArguments`, после native entities/translation/style processing |
| `TelegramUI/Sources/EmojisChatInputPanelItem.swift` | Тот же font backend в emoji suggestion cells |
| `GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift` | Оба Save GIF paths — message и web-page — вызывают `exteralessSaveGifReporting`, с отдельными local-success/error callbacks |
| `TelegramUI/Sources/HorizontalListContextResultsChatInputContextPanelNode.swift` | Inline-bot Save GIF использует тот же реальный backend |

`EmojiKeyboardItemLayer` уже рисует glyph images выбранным `UIFont`; новый text
callsite использует **тот же** `ExteralessEmojiRendering.shared` и account owner.
В `hasVisibleProbe` bitmap явно очищается перед `CTLineDraw`, чтобы ненулевой alpha
не мог появиться из старого содержимого памяти у пустого glyph.

## Сверка Font/Appearance ABI перед вставкой

Прочитаны актуальные `appearance.md`, `appearance-subwave.md`,
`Display/Source/Font.swift`, текущий message formatter и `EmojiFontRendering.swift`.
В этом снимке `Font.with(size:design:weight:width:traits:)` и `Font.regular` остаются
native UIFont factories; отдельного Appearance CSS/glyph backend или нового
font-registration ABI в исходниках/handoff нет. Appearance документирует font-family
alternatives как отдельный незавершённый scope. Не предполагается несуществующий API.

Используемые exports:

```swift
ExteralessEmojiRendering.shared.font(for:size:accountId:fallback:)
ExteralessEmojiRendering.shared.attributedText(_:accountId:defaultSize:)
```

Вызов находится **после** native attributed-text construction: non-emoji fonts,
colors, links, entities, UTF-16 offsets и custom-emoji attachments сохраняются.
Исходный message/draft не меняется; системный UIFont cache не подменяется.
Default/System по-прежнему используют OS glyphs, а неизвестная pack-у sequence
получает native grapheme fallback.

## Tools local favorites: один store, одна Saved-группа

Сверены `tools-favorites-hooks.md`, `tools-phase-2.md:62+` и актуальный
`TelegramCore/Sources/ExteralessTools/ToolsLocalFavoriteStickers.swift`.

### Keyboard data

- `EmojiPagerContentSignals.stickerInputData` подписывается на
  **`exteralessLocalFavoriteStickerItems(engine:)` ровно один раз**, если этот picker
  запрашивает native Saved list. Existing recents/GIF/search/group/policy inputs сохранены.
  Сохранены также три добавленных параллельно Identity-owner guards
  `premiumItemStarInReactions`; они не заменяются новым favorite producer.
- `ExteralessStickers/ExteralessStickerFavorites.swift` содержит только pure projection
  `exteralessStickerPickerFavorites(cloud:local:)`. У него нет storage key,
  transaction или RPC. Он использует `ToolsFavoriteStickerArchive.maximumPerAccount`
  (10 000), native cloud order/current metadata и Tools local order.
- Один `saved` group: cloud/local дубликаты объединяются по `EngineMedia.Id`;
  cloud entry выигрывает и несёт свежие references. Local-only entries добавляются
  к той же группе, без второго shadow store или synthetic server quota.
- Ошибка Tools store логируется безопасным literal; picker сохраняет cloud list.
  Это не успешный пустой import. Tools UI остаётся местом подробного storage error/repair.

### Native references, tap и long press

`EmojiPagerContentComponent.Item.fileReference` — optional native `FileMediaReference`,
default `nil` для прежних consumers. Cloud favorites получают `.savedSticker`;
local-only — `.stickerPack` из Tools metadata, либо `.standalone`, если pack неизвестен.

- `ChatEntityKeyboardInputNode` и `StickerPickerScreen` используют этот reference
  при выборе item, вместо безусловного объявления любого Saved item серверным.
- Long-press send/silent/schedule использует тот же provenance. Новый файл из
  sticker editor сохраняет свой reference, а не reference исходного sticker.
- Equality включает reference; recycled layers получают текущий `Item`.
  При cloud→local/reference change слой заново привязывает fetch, чтобы устаревший
  `savedSticker` reference не оставался у уже local-only item после cloud refresh.

### Menu

В общем `EmojiContentPeekBehaviorImpl` добавлена **одна** local action factory:
`Keep Local Favorite` / `Remove Local Favorite`.

- State читается из `exteralessLocalFavoriteStickers(engine:)` текущего context.
  Read failure имеет состояние `nil`/Unavailable, а не ложное `false`.
- Write вызывает **`exteralessSetLocalFavoriteSticker(engine:file:saved:)`**.
  Toast появляется только после Signal value; failure показывает реальную безопасную
  ошибку. Already-present/already-removed не выдаются за новую запись.
- Обычная cloud action по-прежнему вызывает
  `context.engine.stickers.toggleStickerSaved`; native Premium/server-limit branch
  и lock/send semantics сохранены. Local membership не становится Premium entitlement.
- Metadata/archives/backup принадлежат Tools. Здесь нет нового unlimited preference,
  другого account selector или копии их data model. Tools' original ID
  `neko.unlimitedFavedStickers` не продублирован во втором mergeable fragment.

## Что передать другим owners

**Не применять старые phase-1 `stickers-native-hunks.patch` / `stickers-gif-hunks.patch`
целиком:** они теперь также содержат уже применённые hunks и сохранены как baseline
для source regression checks. Актуальные pending-only документы:

1. [stickers-integration-common-hunks.patch](stickers-integration-common-hunks.patch)
   — 12 точных hunks: runtime registration/init/update/clear, ChatController live
   invalidation/activity, общий AccountViewTracker featured source/cancel boundary,
   и оставшийся GIF action в `ChatInterfaceStateContextMenus`.
2. [stickers-integration-node-hunks.patch](stickers-integration-node-hunks.patch)
   — Chat lead: 6 узких size/font-provider hunks для Sticker/AnimatedSticker nodes.
   Их shape/time/date rendering принадлежит Chat; общей переписи nodes нет.
   Pinned reaction provider уже подключён в `TopMessageReactions`, поэтому
   message reaction counters/DateAndStatus node не нуждаются в новом pin sorter.
3. [stickers-integration-build-hunks.patch](stickers-integration-build-hunks.patch)
   — Build owner: добавить `StickerFavoritesIntegrationTests.swift` и TelegramCore dep
   к уже существующему `StickerEmojiRenderingTestsLib`. Production source globs и
   Emoji/Core deps уже предусмотрены текущим build graph; BUILD здесь не правился.

RootClientRuntime/AppDelegate/Passcode/Network/Host/ChatController/ChatInterfaceStateContextMenus
и Chat-owned Sticker/AnimatedSticker/Date nodes в этом шаге не редактировались.
Общий AccountViewTracker также оставлен его owner с точным hunk.

## Проверки

Выполнено:

```powershell
python -B docs/wave-2/tests/test_stickers_integration.py -v
python -B build-system/Make/PostboxImportCheck.py   # cwd: telegram-ios
git diff --check -- <touched source paths>
```

- **7/7 integration source checks passed**, 0.030 s: девять применённых hunks,
  one-time Tools subscriptions/actions, current references, retained native gates,
  font callsite/probe, 20 remaining owner/build hunk anchors.
- **5/5 исходных contract checks passed**, 0.133 s: точные 21 ID/defaults,
  актуальные consumer lines, parity merge и pinned SFNT fixture. Промежуточное
  смещение трёх line receipts из-за параллельных Identity guards исправлено без
  изменений их реализации.
- **Официальный Postbox guard: exit 0.** Allowlist не расширялась; новые UI wrappers
  не импортируют Postbox и используют существующие Core/Engine exports.
- **Targeted whitespace diff: exit 0.**

Machine receipt: [stickers-integration-checks.json](stickers-integration-checks.json).

Добавлен native XCTest source `Tests/Exteraless/StickerFavoritesIntegrationTests.swift`:
350 local entries после cloud refresh, dedup/current cloud references, pack/standalone
provenance, 10 000 bound и account-ID selection. Fixture создаёт только собственные
валидированные metadata/native files: **Account/Postbox/network и реальные account
writes отсутствуют**. Сам XCTest пока не запускался — Swift/Apple SDK здесь отсутствуют.

Нужны последующие full Swift build, native suites и кадры по AGENTS.md, особенно
cloud→local layer rebinding, local favorite error/menu flow и live glyph replacement.
Source checks не являются визуальным или runtime pass.
