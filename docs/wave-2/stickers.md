# P-stickers-emoji — source handoff

**Обновление:** текущая стыковка, применённые hunks и Tools favorites находятся в
[stickers-integration.md](stickers-integration.md). Описанный ниже phase-1 handoff
сохранён как исходный контракт; его mixed hunks больше не применять целиком.

**Готовы owned-реализация и точные insertion hunks. Swift/iOS и визуальная
приёмка ещё не выполнены.** В [stickers-parity.json](stickers-parity.json)
покрыты все **21 исходный ID**: 18 owned, 3 явно делегированы Chat phase 2.
16 полей зарегистрированы в `StickerFeatures.definitions`; metadata cache и
неиспользуемая Android-декларация не превращены в фиктивные настройки.

Исходный inventory SHA-256:
`17cf1a8efad7469c8696045904105694347e26a2dbe70040d0f64658464ed99c`.
`client-features.json`, shared roots, BUILD, Python runtime и Android не менялись
этим owner. Все состояния `ported=false`; независимое review назначает coordinator.

## Что подключено

- **Emoji packs:** Files import, original Telegram metadata source, ручной HTTPS
  download с optional user pin, preview фактического шрифта, выбор/default/system,
  version update, remove, clear unused downloads, reload, cancel и account teardown.
  Сохранение файла само по себе не называется установленным шрифтом.
- **Настоящий backend:** SFNT validation → app-private CoreText registration →
  `UIFont` availability → shaping без fallback → проверка ненулевого bitmap alpha.
  `EmojiKeyboardItemLayer` реально рисует выбранным `UIFont` и обновляется по
  font notification. Для message/large-emoji text приложены готовые shared hunks.
- **Picker:** live featured source/tab gate, group sticker tab hide, 20–200 recents,
  компактный Create Sticker в Recent header с действующим native editor callback.
  Create/Clear расположены отдельно; callback читает текущую модель после toggle.
- **Reactions:** native selector для семи pins, reorder/remove/reset, отдельные
  chat/channel enable flags, действующий `topMessageReactions` consumer. Stock
  Quick Reaction settings открываются своим native controller/Engine API.
- **Locked custom emoji:** только WebP/WebM, как оригинал. Загруженные bytes идут
  в новый `LocalFileMediaResource`, обычный sticker upload и native `sendSticker`.
  Premium cloud document не переименовывается в якобы разрешённый серверный объект.
- **GIF:** account-local shelf, native picker/StickerPicker save/remove, локальный
  success label, ошибки записи, clear и merge свежих cloud references. Ещё четыре
  shared Gallery/chat/inline-bot вызова даны готовыми hunks.

## Координатору: применить source hunks

Файлы ниже используют **тот же `*** Begin Patch` envelope, что patch tool**.
Это содержимое для применения координатором, а не уже изменённые shared файлы.
Read-only check проверяет каждый old anchor в текущем дереве.

1. [stickers-native-hunks.patch](stickers-native-hunks.patch):
   - `ExteralessClientRuntime`: registration + retained
     `ExteralessStickerIntegration.init/update/clearContext`;
   - `SynchronizeRecentlyUsedMediaOperations`: add/remove/clear local recents
     **в существующей Postbox transaction**, рядом с native cloud operation;
   - `ChatController`: центральный choosing-sticker gate для всех entry paths и
     retained `ExteralessStickerChatObserver` для live message remeasurement;
   - `AccountViewTracker`: глобальный featured pack gate, cancellation и сброс
     refresh timestamp; native settings уже скрывают Trending для пустого списка;
   - `ChatEmptyNode.stickerTapGesture`: только запрет tap-to-send;
   - Chat-owned static/animated sticker nodes: **только size и display-font hunks**;
     default 14 пропускает преобразование размеров, другие значения используют
     родительские insets/avatar/share/failure budget и сохраняют aspect ratio;
   - `ChatMessageTextBubbleContentNode`: display-only font attributes после entities.
2. [stickers-gif-hunks.patch](stickers-gif-hunks.patch): четыре точные замены
   в `ChatItemGalleryFooterContentNode`, `ChatInterfaceStateContextMenus` и
   `HorizontalListContextResultsChatInputContextPanelNode`. Adapter отдельно
   сообщает local success/error; исходный `SavedGifResult` остаётся cloud-only.
3. [stickers-build-hunks.patch](stickers-build-hunks.patch): Emoji → Core,
   EntityKeyboard → Emoji/Core, picker/node Core imports, native Quick Reaction
   dependency, test-only fixture export и `StickerEmojiRenderingTests` target.
   Новые Core/TelegramCore/TelegramUI файлы входят в существующие source globs.

У Chat сохраняются `stickerShape`, `stickerTimeSide`, `hideTimeForSticker` и все
`ChatMessage{Sticker,AnimatedSticker,InstantVideo,DateAndStatus}` files. Этот owner
их не редактировал. Pins меняют **предложенную reaction row** через центральный
`TopMessageReactions`, не переставляют уже полученные message reaction counters;
поэтому отдельного pin-патча date/status/instant-video nodes не требуется.

У Tools остаются `unlimitedFavedStickers`, favorite-sticker persistence и backup.
Новые keys `exteraless.stickers.recents.v1` / `exteraless.stickers.local-gifs.v1`
находятся в account Postbox и не используют favorite storage. Allowlist не расширен;
новые UI-файлы не импортируют Postbox/TelegramApi и не обращаются к `.postbox`.

## Original semantics и лицензированные ресурсы

Прочитаны Java **и** Kotlin, `AGENTS.md` и весь `CLAUDE.md`.
Особенно важны исходные места:

- `EmojiHelper.java:119,124` выбирает source; в `BaseRemoteHelper.java:22-26`
  default channel = `0/""`, opt-in = `2477822904/nagramx_remote_metadata`.
  Поиск `#emojiv2` ограничен 10 messages. Native вызывает реальные
  `engine.peers.resolvePeerByName`, `engine.messages.searchMessages`,
  `getMessagesLoadIfNecessary` и `engine.resources.fetch/data`; join не выполняется.
- `EmojiHelper.java:408,788` — чтение/запись **state cache**. iOS хранит versioned
  JSON с source identity; ошибочный refresh не заменяет последний валидный catalog.
- `Emoji.java:150-163` — font-raster path против default PNG resources;
  `EmojiHelper.java:258-271,594-628` — glyph drawing и import preview.
- `Emoji.java:790-801` — system emoji; `EmojiHelper.java:141-174,321-338` — Android
  `/system/fonts` lookup. На iOS используются предоставленные ОС Apple glyphs.
  Android PNG pages/alpha masks и `R.drawable.ic_apple_logo` не копируются:
  UIKit/CoreText glyph rendering, включая OS fallback для U+F8FF, — native equivalent.
- `PinnedElementsHelper.java:19-45`, `PinnedReactionsActivity.java:87`,
  `ReactionsContainerLayout.java:1199-1217` — enable flag, лимит **7**, filtering по
  разрешённым реакциям. Native сохраняет этот порядок и действующие permission gates.
- `ChatActivityEnterView.java:14086-14239` ограничивает locked conversion WebP/WebM
  и заново загружает обычный sticker. Native сохраняет этот существенный контракт.
- `EmojiView.java:7130-7138` уменьшает creator до header action, а не выключает editor.

### Font admission

- Разрешены `.ttf`/`.otf` SFNT с проверенными directory/table/Unicode/name/metrics
  bounds, outline либо sbix и COLR **v0** + CPAL. CBDT/CBLC-only Android bitmap fonts,
  TTC, WOFF/WOFF2, ZIP/XML installers, SVG и COLR v1 не выдаются за рабочие iOS packs.
  Финальная совместимость всегда определяется фактическим CoreText/UIFont probe.
- Исходные bytes и SHA сохраняются неизменными. Для process registration создаётся
  **только in-memory** SFNT с private name `EXLEmoji-<content hash>` и пересчитанными
  checksums; copyright/license records сохранены. Это позволяет обновить версию
  с тем же исходным PostScript name, пока старый UIFont ещё удерживается layout.
- 32 MiB/font, 16 stored packs, 96 MiB/library; catalog ≤256 KiB/64 entries;
  HTTPS redirects ≤3, request/resource deadlines 20/25 s, bounded streamed body,
  нет cookies, credential store или shared URL cache. User SHA проверяется, если
  указан; для bundled origin SHA и license обязательны.
- **Ни одного внешнего font asset не скачано/не включено.** Default glyphs лицензированы
  как часть iOS. Remote/user-imported fonts — выбранные пользователем источники;
  их embedded license metadata показывается, наличие catalog entry не объявляется
  доказательством лицензии или iOS-совместимости.
- Единственная новая font fixture — **936 bytes, локально нарисованный CC0-1.0
  тестовый outline** для U+1F600. Это не пользовательский emoji pack и не vendor art.
  SHA: `0e60fcc49115ab0bfc096118e3054a992f8b4fb917c0bdc601eda3e68dbfc5b7`.

### Точная iOS граница

Default и System без custom pack **выглядят одинаково**: обе опции используют
Apple glyphs данной iOS. System временно обходит выбранный app font; выключение
System возвращает валидный выбранный pack. Установленные на ОС emoji version/style
не подменяются. Применение здесь: app emoji-picker images и message/large-emoji text
через предоставленные hunks. Это не глобальная подмена `UIFont` во всех UIKit views.
System keyboard и system notification text остаются OS-owned. Telegram animated
sticker/custom-emoji media продолжают использовать native animation resources.
Для неподдержанной pack-ом ZWJ/VS16/skin-tone sequence применяется целый native
grapheme fallback, без замены текста, UTF-16 range или custom-emoji attachment.

## Карта всех 21 ID

`Core` = `swift/ExteralessCore/Sources/ExteralessCore/`;
`Native` = `telegram-ios/submodules/TelegramCore/Sources/ExteralessStickers/`;
`UI` = `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Stickers/`.
Полные machine callsites/test symbols/source dispositions находятся в JSON.

| Original ID | Default | Native consumer / disposition |
|---|---|---|
| `chats.stickerShape` | `1` | **Chat-owned** `DateAndStatusNode.exteralessStickerCornerRadius` |
| `chats.stickerTimeSide` | `false` | **Chat-owned** `exteralessStickerTimeFrames` |
| `emojihelper.emojiPack` | `""` | `UI/ExteralessEmojiPacks` → `Emoji/EmojiFontRendering` → `EmojiKeyboardItemLayer.updateStaticEmoji`; message hunks |
| `emojihelper.emoji_packs_v2` | `""` | `Core/EmojiPackStore.saveCatalog/catalog/readIndex`, state adaptation |
| `nagram.pinnedReactionsChannels` | `"[]"` | `ExteralessPinnedReactionsController` → `Native/ExteralessPinnedReactions` → `TopMessageReactions` |
| `nagram.pinnedReactionsChats` | `"[]"` | Тот же pipeline, private/group selection |
| `nagram.sendLockedCustomEmojiAsSticker` | `true` | `ChatEntityKeyboardInputNode.sendLockedEmojiAsSticker` → `Native/ExteralessUploadedEmojiSticker` → native send |
| `nagram.unlimitedSavedGifs` | `false` | `Native/ExteralessStickerCollections`, `GifContext`, both pickers, four shared-menu hunks |
| `nagram.usePinnedReactionsChannels` | `false` | `StickerReactionPolicy.pins` gate, native broadcast detection |
| `nagram.usePinnedReactionsChats` | `false` | `StickerReactionPolicy.pins` gate, native private/group path |
| `neko.disableChoosingSticker` | `false` | Live picker activity signal + central ChatController hunk; **не disable picker** |
| `neko.disableTrending` | `true` | `EmojiPagerContentSignals`; global `AccountViewTracker` source/cancel hunk |
| `neko.dontSendGreetingSticker` | `true` | Exact `ChatEmptyNode.stickerTapGesture` hunk; consumer pending insertion |
| `neko.hideGroupSticker` | `false` | `EmojiPagerContentSignals.stickerInputData` group/tab projection |
| `neko.hideTimeForSticker` | `false` | **Chat-owned** `exteralessStickerTimeHidden`, hidden wins over side |
| `neko.maxRecentStickerCount` | `20` | `Native/exteralessRecentStickerItems`, live picker; central transaction capture hunks |
| `neko.minimizedStickerCreator` | `false` | Recent header +, live model/read callback, native `openStickerEditor` |
| `neko.stickerSize` | `14.0` | `Core/StickerPolicy.stickerSide`; exact static/animated node hunks, consumer pending insertion |
| `neko.useCustomEmoji` | `false` | **Exact legacy-unused declaration**; only `NekoConfig.java:80`. Similarly named settings row is a header. No new toggle |
| `neko.useSystemEmoji` | `false` | `selectNative/reload` → active font bypass → actual UIFont/native fallback |
| `openextera.downloadEmojiPacks` | `false` | Original source gate, actual Engine fetch + bounded URLSession import pipeline |

16 setting keys use `chats.<originalField>`; proposed inventory keys for emoji
source/selection are explicitly overridden in the fragment. Pins retain the original
**global configuration**, while file resolution/Premium checks use the current account.
Font files/catalog are account-scoped; a globally selected ID unavailable in another
account falls back to native. Clear/reload retire render owners; stale async completions
cannot publish fonts or commit selection after cancellation/account switch.

## Проверки и следующая приёмка

Выполняемые здесь проверки — **read-only source/fixture checks**, не Swift tests:

```powershell
python -B docs/wave-2/tests/test_stickers_contract.py -v
```

Проверяются 21-ID/default join, merge через существующий parity schema, настоящий
936-byte fixture SHA и все 10 SFNT checksums, coordinator hunk anchors, запрет новых
UI Postbox/TelegramApi accesses, native consumer links и URLProtocol-only fixtures.
Отдельный bounded Python расчёт уже подтвердил fixture SHA и table checksums.
`git diff --check` применяется только к owned Swift/source files.

**Фактический итог 2026-11-15:** 5/5 source checks passed за 0.132 s;
37 hunk anchors (23 native, 4 GIF, 10 build) разрешились. Проверка whitespace
прошла для 21 нового Swift source и для diff восьми изменённых owned Swift files.
Два промежуточных check-а обнаружили изменившийся во время работы runtime
registration anchor; финальный hunk привязан к стабильному `registered = true`
и сохраняет регистрации других owners. Receipt: [stickers-checks.json](stickers-checks.json).

Добавлены, **но не исполнены** (Swift отсутствует в PATH, Xcode/simulator отсутствуют):

- `StickerPolicyTests`: baseline/width clamp, recents/reference merge, WebP/WebM
  context gating, Int64/ZWJ pins, reset, retired commit lease;
- `EmojiPackTests`: malformed font admission, private registration names/license,
  catalog bounds/refresh/recreation, account isolation, cache tamper, invalid update,
  bundled pin requirement, selected/imported preservation during cleanup;
- `EmojiFontHTTPTests`: actual URLSession delegate через URLProtocol, streamed
  fixture, MIME/size/HTTP/hash failures, cancellation, URL policy;
- `StickerEmojiRenderingTests`: настоящий UIFont, unchanged UTF-16/link ranges,
  grapheme fallback, reset, blank-font rejection, account-owner retirement и update
  с удерживаемым старым UIFont. **Account/network fixture не создаётся.**

После стыковки: адресный `swift test --package-path swift/ExteralessCore --filter
'StickerPolicyTests|EmojiPackTests|EmojiFontHTTPTests'`, native test target из BUILD
handoff и поддерживаемая полная Telegram build. CI запускает coordinator.

### Ожидаемые frames до записи

1. При выборе тестового font-а U+1F600 меняется на его outline в preview/picker и
   message body; соседний текст, link ranges и unsupported ZWJ остаются целыми.
   Default/System возвращают native glyph, без старой картинки в recycled cells.
2. Size 4/14/20, portrait/regular width, incoming/outgoing, reply/forward/share,
   static/WebP/animated/video sticker/dice: aspect ratio сохранён, при 14 native
   geometry совпадает, time/reactions не обрезаны, соседние элементы не перекрываются.
3. Compact creator: grid tile исчезает, маленький header + открывает тот же editor;
   Clear остаётся отдельной целью. Toggle обратно восстанавливает tile. Проверить RTL,
   accessibility label и узкую ширину; нет скачка/двойного header при live update.
4. Trending/group switches сразу меняют группы и tabs; current tab корректно переходит
   к доступной группе. Pins выбираются отдельно для broadcast/private/group, forbidden
   и недоступные premium emoji не обходят native checks; native paid star остаётся первым.
5. Cancel/download/error/account switch никогда не показывают ложный installed checkmark
   и не отправляют подготовленный locked sticker после изменения draft/reply/location.

Кадры, их timestamps и выводы по `AGENTS.md` остаются обязательными. Source evidence
и наличие тестов не повышают этот handoff до `verified`.
