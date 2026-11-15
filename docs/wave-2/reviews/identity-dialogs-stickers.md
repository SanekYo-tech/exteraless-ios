# Independent original → iOS review: Identity / Dialogs / Stickers

**2026-11-15 — REQUEST CHANGES: 8 новых P2; новых подтверждённых P1 не найдено.**
Это выводы по исходникам и порядку событий. Native typecheck, CoreText/UIKit
execution и visual acceptance этим review не установлены.

## Срез и доказательства

- Прочитаны `telegram-ios/AGENTS.md`, полный `CLAUDE.md`, wave-2 contract,
  `identity.md`, `dialogs.md`, `stickers.md`, `stickers-integration.md`, их shared
  seams и текущие consumers. Android проверялся в **Java и Kotlin**.
- Начальный HEAD: `ddc25d696a8a27e63e1e8f6b0bfb2d53ed4a62b8`; при фиксации
  Core-среза: `f99909b58968b69dfb57132db9dd84d2e28889cc`. Checkout общий и
  изменялся другими owners. Ниже зафиксированы raw-byte SHA-256, а ссылки ведут
  в прочитанный working tree, не в номера строк старых handoff patches.
- Финальная сверка: HEAD `c7ef25ed710af501554facd27401d4f4af6f0f81`.
  Пять изменившихся shared/dependency files перечитаны по относящимся к review
  seams; superseding pins от **10:27:12 UTC** находятся в конце. Причины IDS-01…08
  сохраняются. Native acceptance всего нового commit этим не заявляется.
- Все **20 Core Identity/Dialog/Emoji/Sticker sources + 8 test/fixture files**
  имеют пустой `git diff e59bd30a -- <cohort>`. Полный base:
  `e59bd30a8d89bebe4537bb0d9a391a118b2f3fa9`.
  `progress.md:32–34` сообщает для него 390 Core tests PASS, включая эти домены.
  Это атрибутированный CI-контекст; CI здесь не запускался и его logs не читались.
  Он не покрывает текущие native adapters/consumers.
- Выполнена одна ограниченная **30 s** in-memory Python проверка: собственный
  968-byte mixed-glyph font, его SFNT checksums и два коротких контрпримера
  recents/pin order. Это не запуск Swift, Postbox или CoreText. Файлов fixture
  вне отчёта не создано; сеть, live accounts и внешние plugins не использовались.
- Изменяется только этот новый файл. AP-01…11 и TB findings не переименованы
  в новые findings. Поздние исправления Privacy/Retention использованы лишь как
  зависимости; их самостоятельное закрытие остаётся за соответствующим review.

Пути ниже: **C** = `swift/ExteralessCore/Sources/ExteralessCore`,
**CT** = `swift/ExteralessCore/Tests/ExteralessCoreTests`,
**S** = `telegram-ios/submodules`, **N** = `S/TelegramCore/Sources`,
**U** = `S/TelegramUI`, **NT** = `telegram-ios/Tests/Exteraless`,
**A** = `third_party/exteraless-android/TMessagesProj/src/main`.

## IDS-01 — P2: local emoji-status expiry теряет следующий deadline после перевода часов

**Source:** `N/ExteralessIdentity/ExteralessIdentityPresentation.swift:80–89`;
`U/Sources/ExteralessClient/Identity/ExteralessIdentityIntegration.swift:23–29`;
`S/SSignalKit/SwiftSignalKit/Source/Timer.swift:30–49`.

Lease вычисляет delay по `Date()`, но ставит одноразовый **DispatchTime** timer.
Его callback только invalidates presentation. Foreground/significant-time-change
тоже только invalidates: ни один из этих путей не пересчитывает timer.

**Сценарий/impact:** wall time=1000, local status expires at 1100. Через 50 s часы
переведены на 100 s назад: now=950. Notification правильно перерисует ещё активный
status. Старый timer срабатывает через оставшиеся 50 s при now=1000: status ещё
активен, timer больше нет. При настоящем now=1100 не происходит invalidation.
Уже показанный badge остаётся до постороннего обновления. Перевод вперёд, не
пересекающий expiry сразу, аналогично оставляет слишком поздний deadline.
`isActive(at:)` корректен при новом чтении — дефект в доставке этого чтения.

**Original:** `A/kotlin/xyz/nextalone/nagram/helper/LocalPremiumStatusHelper.kt:25–30`
и `A/java/org/telegram/messenger/UserObject.java:187–203` сравнивают expiry с
текущим wall clock; истёкший статус не должен оставаться активной проекцией.

**Fix/test:** пересчитывать ближайший expiry на foreground/time-change и после
слишком раннего timer callback; сохранить account lease/token guards. Native
fixture с injected wall/monotonic clocks: backward/forward jump, suspension,
expiry ровно на границе, account retirement; реальное время устройства не менять.

## IDS-02 — P2: Identity name projection обходит действующий Zalgo display filter

**Source:** `S/LocalizedPeerData/Sources/PeerTitle.swift:8–13,39–68`;
`N/ExteralessIdentity/ExteralessIdentityPresentation.swift:158–162`;
`N/ExteralessPrivacyExtras/ExteralessFilteringText.swift:4–9`.
Реальный title consumer: `U/Components/ChatTitleView/Sources/ChatTitleComponent.swift:631–641`.

Stock `displayTitle`/`compactDisplayTitle` применяют `exteralessZalgoDisplayText`.
Добавленные account-bearing методы возвращают `projection.name/compactName`
раньше этого пути. Projector формирует имя **любого обычного пользователя**, даже
при `state == nil` и без alias, поэтому обход не ограничен локально введёнными именами.

**Сценарий/impact:** `privacy.zalgoFilter=true`, firstName=`A` + четыре U+0301,
lastName отсутствует. Native display formatter выдаёт `A`; Identity formatter
возвращает исходный combining run в chat/list/profile title. Alias с таким run
также допустим по текущим alias bounds. Фильтр имён фактически перестаёт работать
на переведённых consumers, хотя настройка и stock implementation исправны.

**Original:** `A/java/org/telegram/messenger/ContactsController.java:3062–3119`
вызывает `MessageHelper.zalgoFilter` **после** name-order composition;
`A/java/tw/nekomimi/nekogram/helpers/MessageHelper.java:953–981` содержит gate и
removal rule. `C/FilteringTextPolicy.swift:6–34` уже реализует этот rule.

**Fix/test:** композиция Identity → existing display filter на конечном display
boundary. Для `ContactsPeerItem.swift:968–995` сохранить attributed first/last-name
fonts, применяя уже существующий attributed projector. Не менять stored alias
или server peer. Проверить alias/no alias/reset, обе name orders, flag off/on,
обычные диакритики и ZWJ; сравнить actual account-bearing title methods со stock.

## IDS-03 — P2: поздний remote-unpin удаляет локальный pin после его перестановки

**Source:** `N/ExteralessDialogs/ExteralessDialogPins.swift:27–33`;
`N/State/ManagedSynchronizePinnedChatsOperations.swift:227–237,276–290`;
`N/State/AccountStateManagementUtils.swift:1714–1726,5208–5219`.

Overflow guard определяет происхождение unpin по **нынешнему** server-limited
prefix. Он не хранит prefix/revision запроса, чей поздний update обрабатывается.
CAS в sync защищает применение ответа `getPinnedDialogs`, но не этот отдельный
state-replay path.

**Сценарий/impact:** limit=5, committed local order `[1,2,3,4,5,6]`; sync отправил
`[1,2,3,4,5]`, оставив 6 local-only. До доставки unpin(6), относящегося к прежнему
remote состоянию, пользователь **коммитит отдельной transaction** reorder
`[6,1,2,3,4,5]`. Guard теперь видит 6 в первых пяти и возвращает false; replay
удаляет 6. Поздний echo отменяет более новое явное локальное действие. Это не
предположение о read-your-writes внутри одной transaction: reorder уже committed.
Малый order counterexample проверен в памяти.

**Original/contract:** сохранение local pins при refresh видно в
`A/java/org/telegram/messenger/MessagesController.java:17848–17882`; native handoff
также прямо обещает защиту overflow от unpin echo. Валидный `updateDialogPinned`
действительно преобразуется в указанный replay operation.

**Fix/test:** привязать reconciliation/echo disposition к отправленной generation
и pending local intent; после более нового local pin/reorder сохранять его и
пересинхронизировать актуальный prefix. Не сохранять все remote pins безусловно.
Fixture: настоящие disposable Postbox transactions + injected replay update в
обоих порядках, limit=5/6 entries; explicit local Unpin должен по-прежнему удалять.
Один вызов pure `preservingLocalPins` этот порядок событий не проверяет.

## IDS-04 — P2: выключение additional pins не reconciles невыбранный account

**Source:** `U/Sources/ExteralessClient/Dialogs/ExteralessDialogIntegration.swift:40–54`;
`N/ExteralessDialogs/ExteralessDialogPins.swift:36–41`;
`U/Sources/ExteralessClient/ExteralessClientRuntime.swift:263–267,291,358–378`.

Глобальный flag наблюдается только для текущего context. Reconcile enqueue делается
только на переходе `previousPinsEnabled == true → false`; при новом context
`previousPinsEnabled` снова nil.

**Сценарий/impact:** account A имеет 6 сохранённых pins при server limit=5, незавершённых
sync operations нет. Переключиться на B, выключить flag, вернуться на A. Off-event
enqueue получил только B. Initial false у A не enqueue ничего; его overflow pins
продолжают отображаться при выключенной настройке до посторонней синхронизации.
Это также случается после изменения shared setting, пока account не представлен UI.

**Contract:** `C/CoreDialogFeatures.swift:27–28` обещает reconciliation при off;
исходный `NekoConfig.java:113` — один global flag, а local pins хранятся по account.
Ограничение новых pin operations в `TogglePeerChatPinned.swift:52–70` не очищает
уже существующий overflow.

**Fix/test:** reconcile нужных active accounts на global transition либо учитывать
account-local reconciliation state при attach с false. Избежать бесконечных
enqueue на каждый unrelated setting callback. Два synthetic accounts, A→B→off→A:
проверить один необходимый enqueue для A, затем реальную native reconciliation,
сохранность B и отсутствие подмены server acknowledgement локальным success.

## IDS-05 — P2: Back badge вычитает channel, уже исключённый из total

**Source:** `U/Sources/ExteralessClient/Dialogs/ExteralessDialogBackBadge.swift:35–54`;
`S/TelegramUIPreferences/Sources/RenderedTotalUnreadCount.swift:10–16`;
`S/SettingsUI/Sources/Notifications/NotificationsAndSoundsController.swift:613–617,722–732`.

Total уважает `totalUnreadCountIncludeTags`, но current-peer subtraction проверяет
только mute и positive count. Категория peer не проверяется. В filtering branch
тот же closure вызывается после total, который уже отфильтровал tags
(`N/ExteralessPrivacyExtras/ExteralessFilteringSummaries.swift:233–251`).

**Сценарий/impact:** обычной native настройкой выключить **Include Channels**;
в private chats 5 unread, у открываемого unmuted broadcast channel ещё 3.
Total уже равен 5, adapter выдаёт `5−3=2`. В режиме count-chats он может скрыть
единственную оставшуюся private-chat единицу как `1−1=0`. Для устойчивого fixture
держать history read-disabled; ошибка не требует работающих sender/regex filters.

**Original/native contract:** `A/java/org/telegram/ui/ActionBar/ActionBar.java:2614–2617`
даёт opt-in badge; iOS adaptation обещает существующие native notification-count
preferences, а не другой набор подсчитываемых chats. Это не AP-01 про default
folder counters и не повторная фильтрация всей chat-list projection.

**Fix/test:** вычитать только contribution текущего peer в том же eligible set,
из которого построен total. Messages/chats, Include Channels off/on, muted,
unknown projection и entry-point suppression проверять на actual badge adapter;
не менять read state ради исправления числа.

## IDS-06 — P2: full local recents вытесняют свежие cloud recents

**Source:** `C/StickerPolicy.swift:64–75`;
`N/ExteralessStickers/ExteralessStickerCollections.swift:53–63`;
`U/Components/EntityKeyboard/Sources/EmojiPagerContentSignals.swift:1920–1938`.

При count>20 merge идёт `local + cloud` и останавливается на limit. Cloud заменяет
metadata совпадающих IDs, но новый cloud ID вообще не попадает в полный local list.

**Сценарий/impact:** count=200; local IDs=1…200. Другой клиент аккаунта использует
sticker 999; свежий native cloud list=`[999,1,…,19]`. iOS отображает 1…200,
**999 отсутствует**, хотя он самый новый. При меньшем заполнении он окажется
после старых local items. При reset на 20 отдельная cloud-only ветка внезапно
возвращает правильный порядок. Контрпример 200+20 проверен в памяти.

**Original:** `A/java/org/telegram/messenger/MediaDataController.java:2205–2233`
сначала берёт свежие server documents, затем добавляет только отсутствующие local
extras. `:929` применяет display count. `CT/StickerPolicyTests.swift:17–24`
сейчас закрепляет противоположный local-first порядок — green test не доказывает parity.

**Fix/test:** для recents сохранить свежий cloud order, затем local-only tail;
новый local send уже добавляет элемент в native cloud list в **той же transaction**
(`N/State/SynchronizeRecentlyUsedMediaOperations.swift:40–46`). Проверить через
настоящий adapter 20/21/200, cross-device refresh, local send/remove/clear, reset
и свежие references без изменения server quota. Отдельная local GIF shelf имеет
свой документированный порядок; исправление recents не должно случайно менять его.

## IDS-07 — P2: Sticker policy signal может последним опубликовать старый snapshot

**Source:** `N/ExteralessStickers/ExteralessStickerSettings.swift:7–15`;
`C/ClientSettings.swift:354–356,453–454` (последняя сверка);
`C/ClientSettingsObservation.swift:34–38`;
`S/SSignalKit/SwiftSignalKit/Source/Subscriber.swift:152–162`.

Subscribe-before-read закрывает потерянную регистрацию, но не порядок публикаций.
Callbacks ClientSettings по контракту могут перекрываться. `StickerPolicy(...)`
читается до `putNext`; neither observer nor Subscriber удерживает delivery lock.

**Сценарий/impact:** callback A прочитал старый `hideTrending=false` и остановлен
перед публикацией. Callback B после последующего committed true публикует true.
A возобновляется и публикует false; `distinctUntilChanged` его пропускает.
Persisted setting=true, но live picker снова включает featured provider
(`EmojiPagerContentSignals.swift:1746–1748`) и остаётся со старой policy до следующего
события. Таким же образом расходятся recents count/group visibility/local GIF projection.
Источники двух callbacks могут быть обычными native settings writers.

**Fix/test:** сериализовать **повторное чтение + публикацию** на одной queue, как
уже сделано в `N/ExteralessDialogs/ExteralessDialogPolicy.swift:9–20`, либо ввести
монотонную snapshot generation. Не блокировать store/observer lock вокруг UI
subscriber. Controlled two-writer fixture с barrier после старого read должен
закончиться текущей policy; отдельно initial-read race, reset и disposal.

## IDS-08 — P2: один видимый glyph разрешает применение невидимых emoji из того же font

**Source:** `S/Emoji/Sources/EmojiFontRendering.swift:26–55,99–111,160–177`.

`supports` принимает любой nonzero glyph в том же font. `hasVisibleProbe`
останавливается на **первом** видимом emoji из четырёх. Поэтому проверка blank font
на installation не распространяется на следующий отображаемый grapheme.

**Сценарий/impact:** собственный SFNT содержит видимый 😀 (glyph 1) и пустой 😉
(glyph 2, numberOfContours=0). Оба cmap IDs ненулевые. Первый emoji пропускает
admission; для второго `font(for:)`/`attributedText` выбирают пустой custom glyph,
а не OS fallback. В picker/message вместо 😉 получается пустое место.

Для source counterexample в памяти построен **968-byte** font из существующего
CC0 `CT/EmojiFontFixture.swift`: сохранён glyph 1, добавлена копия пустого glyph 0
как glyph 2, обновлены `maxp`, `hhea/hmtx`, `loca` и format-12 cmap для U+1F609.
Все SFNT checksums пересчитаны, итог `0xb1b0afba`; SHA-256:
`3d8c2e9912be9ff1ffabee9f71feb51687b82d0f00535b1b22b20492736fd1ea`.
**CoreText execution этого counterexample не выполнялся.** Доказательство здесь —
раздельные admission/use predicates и валидный empty-glyph input, не кадры.

**Original/native contract:** font raster path присутствует в
`A/java/org/telegram/messenger/Emoji.java:150–163` и
`A/java/tw/nekomimi/nekogram/helpers/remote/EmojiHelper.java:258–269`.
Native handoff дополнительно обещает whole-grapheme fallback, а тест
`NT/StickerEmojiRenderingTests.swift:34–41` проверяет только полностью blank font.

**Fix/test:** bounded, cached per-face/per-grapheme shaping/visible-glyph decision
на use path; пустой unsupported emoji должен получить целый native fallback.
Добавить mixed visible/blank fixture к реальному UIFont/bitmap suite; проверить
также partially supported ZWJ/VS16/skin-tone sequence, style/UTF-16/link preservation
и удержание старого UIFont при update/reset. Не считать проверку одного probe
доказательством поддержки всех emoji в pack.

## Проверенные границы и оставшаяся интеграция

### Identity

- Account cache key включает record ID, user ID и environment. Durable archive
  проверяет user/environment; перенос в другой record того же user/environment
  разрешён намеренно. Peer-kind aliases и secret→regular-user mapping различены.
  Publication cache хранит immutable values, проверяет lease token и sequence.
- Alias limits/canonical peer keys, signed Int64 status/pattern IDs, Int32 expiry,
  Android 0/−1 sentinels и absent-vs-explicit import fields прослежены в
  `IdentityPolicy/Archive/Mutation`. Native reader получает bounded JSON напрямую,
  reset удаляет только owned preference row. Field CAS проверяется внутри Postbox
  closure, edit permit — после queueing (`ExteralessIdentityStore.swift:39–60`).
  Это не заявление, что уже начавшаяся transaction откатывается при account switch.
- Projector возвращает presentation fields, не новый serializable peer. Local
  Premium действует для owning user; actual server status/color имеет priority.
  `EnginePeer.isPremium` остаётся native. Просмотренные Network/PendingMessages
  пути не используют cosmetic badge как capability. Picker `forceHasPremium=true`
  локальных status/color editors заканчивается local mutation, не status/color RPC.
  Outgoing custom-emoji entitlement в native chat по-прежнему проверяет actual Premium.
- Contact-card name берётся из supplied contact payload, если нет local override.
  Metadata rows используют реальный user/channel ID и подписанный источник DC;
  profile about/common-groups/title consumers применены. IDS-02 относится к
  финальной display-filter composition, не к сохранению server name.
- Foundation Persian calendar, компонентный round-trip, DST day arithmetic,
  target-date timezone offset в date header (`ChatMessageDateHeader.swift:148–149`)
  и Gregorian media-month endpoints проверены по source/tests. Android 33-year
  approximation (`PersianDate.java:306–325`) не используется как iOS oracle.
  Source timestamps/scheduled instants не преобразуются в другие payload IDs.
  Это не новое закрытие AP-10/11 или native date-render pass.

### Dialogs / read boundaries

- Nagram unread key и legacy Neko sort declarations не объединены. Promotion
  сохраняет native pin positions/draft-date ties и peer/thread IDs. All-known-local
  metadata provider отделён от обычного loader; holes не выданы за загруженные dialogs.
- `ChatListNodeLocation.swift:223–242` вызывает **один** privacy projection до
  ordered window. `ChatListNodeEntries.swift:1012–1014` не делает второй sort.
  Hidden-account gate повторён перед финальными entries, включая contact/Saved
  suggestions (`ChatListNode.swift:2217–2219`). Read-only projection не передаётся
  в mark-read APIs. Поздний Privacy fix прочитан: inactive projection сразу
  возвращает list, active cursor использует peer/namespace-local bounds и общий
  budget; прежний PR01 не продублирован как новое finding.
- Forum preference сохраняет три состояния absent/Tabs/List. Router использует
  настоящий peer; next-topic берёт `nextThreadData.id`, navigation stack принадлежит
  ContentData. Swipe-to-next проверяется при visibility и release, expansion
  потребляется once. Native history с `canRead=false`/held sender не вызывает
  `applyMaxReadIndex`, custom contents пропускает этот writer
  (`ChatHistoryListNode.swift:2717–2745`). Это не proof отзыва уже admitted RPC;
  общие privacy admission findings рассматриваются отдельно.
- Stories disabled отменяет subscription/request/loading callbacks в inspected
  StoryListContext paths; hashtag search освобождает context/disposable. Back badge
  скрывается при unknown projection/запрещённом entry point; его числовой дефект — IDS-05.
- Archive hide убирает reference, не membership. Pull lease хранит previous native
  position вместе с hiddenPsaPeerId; explicit native Unhide выигрывает. Swipe
  unarchive проверяется при построении options **и** dispatch. Cancelled pull,
  повторный pull/возврат и реальные frames ещё не приняты.

### Stickers / Emoji / GIF / favorites

- SFNT directory/table/name/cmap/metrics bounds проверяются до CoreText; TTC,
  WOFF/WOFF2, SVG, COLR v1 и bitmap-only unsupported layouts не принимаются как
  установленные iOS packs. Inspection — immutable value без public initializer;
  registration повторно сверяет source hash, private name меняется только в
  in-memory copy. Original file/license data сохраняются. Проверены 32 MiB/font,
  16 packs/96 MiB library, catalog bounds, HTTP deadlines/redirect/body limits.
- Registration owners account-scoped; retired owner не apply новую face.
  Failed unregister сохраняет ownership в registry; content-hash names позволяют
  удерживать старый UIFont. Эти source guarantees не заменяют CoreText lifetime
  execution. IDS-08 показывает отдельный use-time fallback gap.
- Defaults/reset: recent count=20, sticker size=14, hide Trending/greeting-send
  defaults соответствуют исходным keys. Legacy-unused `useCustomEmoji` не выдан
  за working native toggle. Fresh cloud references обновляются по ID; IDS-06
  относится к **порядку и наличию** новых IDs, не к потере precision.
- Local favorites используют **настоящий Tools Postbox adapter**:
  import/merge/write и remove происходят внутри одной transaction
  (`ToolsLocalFavoriteStickers.swift:153–187`), count=10,000 и bounded 24 MiB writer.
  Keyboard подписан на local producer один раз, объединяет Saved group по ID,
  cloud entry сохраняет свежий reference, local получает pack/standalone provenance;
  tap/long-press/editor paths сохраняют actual file reference и native Premium gates.
  После TB remediation увидены raw JSON/preflight/checked FlatBuffer boundaries.
  Старый TB-03, включая отдельный stock cloud decode в picker, новым ID не повторён.
  `StickerFavoritesIntegrationTests` проверяет DTO/projection (350 entries),
  **не** atomicity реального Postbox или performance 10,000 entries.
- GIF save имеет отдельный local success/error, off идёт в native cloud operation,
  clear local не очищает cloud. Recents capture встроен рядом с native mutation
  в существующую transaction. Большие collection encode/decode и actual UI latency
  требуют native budget fixture/profiling; source cap сам по себе не измерение памяти.
- Locked WebP/WebM custom emoji превращается в новый LocalFile upload; actual
  chat/reply/draft/location/permission guards стоят до native send callback. Нет
  переименования Premium cloud document в якобы бесплатный server sticker.
- Static/animated sticker shape/time callsites прочитаны вместе с
  `ChatStickerLayoutPolicy`: hide-time выигрывает над side, time/share fallback
  сохраняет исходные frames при недостатке ширины, native share/comment/quick-share
  callbacks retained. Это source inspection, не geometry/frame approval.

### Pending shared hunks — актуальное состояние вместо старого receipt

| Seam | Состояние прочитанного source |
|---|---|
| Шесть reserved Identity files | Основные вставки **уже applied-source**: runtime definitions/init/update/clear (`:59,281,298,378`), list/chat date-format invalidation (`ChatListController:472–477`, `ChatController:6810,6971`), wallpaper gate (`:6828`), list names/status/activity, AvatarNode (`:836`) и account-bearing PeerAvatar (`:88–100`). Старое «все 6 pending» не используется как finding; blanket acceptance всех anchors этим не заявляется. |
| Sticker runtime | Registration и lifecycle **applied-source** (`ExteralessClientRuntime:59,280,297,377`). |
| ChatController sticker observer / central choosing-activity guard | **Pending:** предусмотрены `stickers-integration-common-hunks.patch`; в текущем ChatController нет `ExteralessStickerChatObserver`/central StickerPolicy guard. Picker-local gate уже есть. |
| AccountViewTracker featured gate | **Pending:** source/cancel boundary из common hunks отсутствует в просмотренном AccountViewTracker. Picker-local Trending projection уже есть. |
| Static/animated size + large-emoji font | **Pending:** hunks из `stickers-integration-node-hunks.patch`; текущие `innerImageSize`/large-emoji text construction ещё native. Применённые shape/time/Identity changes не являются size/font insertion. |
| Последний GIF menu path | **Pending:** `ChatInterfaceStateContextMenus.swift:1862` ещё вызывает stock `toggleGifSaved`; другие inspected picker/Gallery/inline callsites уже используют adapter. |
| Native typecheck / runtime / frames | **Pending** для текущего merged checkout; Core CI и source anchors этот gate не закрывают. |

## Следующий bounded native proof

1. Реальные disposable Postbox fixtures: IDS-03/04/05/06, queued Identity permit
   после retirement, два peer/thread namespaces с одинаковыми numeric IDs,
   favorites concurrent add/remove/import, small injected byte/count budgets.
2. Controlled clocks/queues: IDS-01/07, stale callback после switch/reset,
   hidden/read-disabled projection; recorder должен показывать отсутствие новых
   read mutations от presentation-only действий.
3. CoreText/UIFont suite: mixed-glyph fixture IDS-08, TTC/WOFF refusal, retained old
   font update/unregister, unsupported grapheme fallback и attributed style/ranges.
4. **Ожидания frames до записи:** alias/title/initials обновляются совместно;
   expired status исчезает на своей границе; sort не дублирует peers и не теряет
   anchor; archive открывается один раз после release, cancel не навигирует;
   static/animated time/share/reactions не перекрываются на narrow/RTL/large text;
   font reset убирает старые glyphs из recycled cells, unsupported emoji видимы;
   cloud→local favorite reference change сохраняет tap/long-press actions.
   Light/dark, account switch, off/on/reset, 4/14/20 sizes — после pending insertions.
   Запись через `simctl io recordVideo`, оценки по индексированным frames и
   **ffprobe PTS** согласно AGENTS.md. Сейчас кадров для этих утверждений нет.

## Source pins

SHA-256 — raw bytes. Aggregate formula: ordinal-sorted **полный repo-relative POSIX path**
`+ NUL + lowercase file SHA-256 + LF`, затем SHA-256 конкатенации. Prefixes ниже
раскрываются до вычисления aggregate. Большие shared файлы проверены по указанным
важным paths/seams, их hash не означает review каждой строки файла.

### Core cohort — 28 files, 10:05:05 UTC

Aggregate: `05f56ab49a6e8ea3f01574b7209039c1721104bce7afb25f078322580a518c0a`.

```text
7ec148204096a5a2f78f7c06e862fac662d2aab0dd0bce5e0bd533e6d7449d30  C/CoreDialogFeatures.swift
757ce33d8cefd971c33e669e8543cc53386206694906dd72f7323315247a1e0c  C/DialogHistoryPolicy.swift
6249ccb90ab25d56c544f0e76d21cd4e292e5ea5ec9a5651f3a3d3b8a036321e  C/DialogOrderingPolicy.swift
a8ee2f57f943cc9d10695f7879d072261a980e9ed7712504fc393afe41f867ec  C/DialogPolicy.swift
188a297ea701d451949cbea5279787c397d10da7e6409dc17a1db83f3aebef2c  C/EmojiFontHTTPClient.swift
f81ef717e723cbba7a9aff99dc28d108587d1f014dad7da1168f20c8d2843986  C/EmojiFontInspection.swift
179b5412b28b2d39d24ddeb80cfb1f2061f04c983b08d1a45ad542d23d985651  C/EmojiFontRegistration.swift
9f97f05eefd76b113361fc24fdd70140eb614958d7c03fd30850e67df801bb0c  C/EmojiPackLease.swift
5d61ce1114376ad780205e999516dc7380a1d5ce48147f512c22f9c19d97c8c4  C/EmojiPackModels.swift
f0e9eb34f669eed264e181a817f5805023b2e34edcd4a59bb143e517ae559d67  C/EmojiPackStore.swift
b55e8b94a633e7c5795dcc23991a9dd10de1377a05b8751c69cdb70bd8d12c1f  C/IdentityArchive.swift
30754a8ab29fed413f193fbeefb9757fbeb6e3d31df0885e9359d7334dbb0878  C/IdentityDatePolicy.swift
e364fd53d72db53b629fb4a40edd7e7584a8d0f147af39908e974a3316765d1d  C/IdentityEditPermit.swift
1aca621fb2c99d743970e651f4109beb7b379229ad1256aa8bb990ab36fdd4bf  C/IdentityFeatures.swift
9c610134b3bcce435397173c96a5a2a5bc1bf7558011578351d8cf3f61179f7c  C/IdentityMutation.swift
06d6a564815c158f5d4bcd3eea65d245bbbf67a1c2f1fc88b2c6a561fd911e6e  C/IdentityPolicy.swift
2f364e2ee3441fb902fdb18e126abc2c4285749c73e36604daa296ba1dca57a2  C/IdentityPresentationCache.swift
013d56750ebc4e8062c793912da02f424d603eb96e6d483c490ed9117f29c277  C/StickerFeatures.swift
1b63442784fbd46bfd2205ca9bbd71206010e1e35df1880ef8f323914b3cdac1  C/StickerPolicy.swift
f81c5a93490c8141030dfbe48f72978f23ad1e19a22df40ea6f371f69db7e8b9  C/StickerReactionPolicy.swift
5fafa99f1b8624cfbb873461f107cfafdcdae7c526cfda176a7960eb64c460ab  CT/DialogPolicyTests.swift
2d6b9bf253b2098013d2f69a9973563e11720603500d062b53e19b61f52afc98  CT/EmojiFontFixture.swift
e79bce2f7c192803eecac5037d5cc0c55647b3a380792c2fa886171d0058b7a9  CT/EmojiFontHTTPTests.swift
c05110439b8c353d63fac2987a4dfd53f7259e4940fc1a4a7e402a784c45e91b  CT/EmojiPackTests.swift
bd96efd7306b8f6f5d81d41ecdf98b919b35b7e959d763fe42238661f313ded8  CT/IdentityCacheTests.swift
73c79c89807bdfbadf73324e4986e8372c444e378abe52aeffd3068898593e90  CT/IdentityDateTests.swift
783e4583981b791b21d6297d7240900709d9c84c5d7774045cf79d270890011d  CT/IdentityPolicyTests.swift
ddc01bfa3cc7f67d29510502d734ab23d4bc12e676722ba3156d051e0eea473b  CT/StickerPolicyTests.swift
```

### Native/consumer cohort — 105 files, 10:08:17 UTC

Aggregate: `f0706b66e4a590e039a90adc59437e5b00fa67cc5ad9ae708c77b51da494c5ca`.
Включены шесть соседних Core dependencies; это не дополнительный CI cohort.
Поздний `ExteralessFilteringSummaries` перечитан с уже исправленными bounds.

```text
e56665ee3d9da258d71555541fb92dcb098f4d67d6ea42e27148404299b378e7  C/ChatMessageLayoutPolicy.swift
f6b9ac51017abbffe0ae2aeb2558cf6b1998adbe0ef5ba74ea97e6b6873719b7  C/ClientSettings.swift
bbd9fda0a1675b2014ab4794b8ed502e7b021cfb3032b6817bc4b9f85f2900f3  C/ClientSettingsObservation.swift
2546593c4319f96ee6efc16b04eb80b63991cabd7d99068bdd41c79a9365f690  C/FilteringTextPolicy.swift
06fc0704aa9e374b485720d6fd7867341685d0c9d7b9c0cde74c1f01ca093b3e  C/ToolsFavoriteStickers.swift
067db09a29a576c81692ef318240ec773d113a3c3109cdceb36b6c70d53fc4f2  C/ToolsFavoriteStickerStorage.swift
d6c8071d4a6eaa8e9724d6d5a8fe9cc11f13c690a87f7776275e7a77d8fd3247  S/AvatarNode/Sources/AvatarNode.swift
275f733f7e6ab5d299313f2858138986dd3c0482be966a9ec90c82611734b73a  S/AvatarNode/Sources/PeerAvatar.swift
83d9d03a8a94e060cb2775e7249994a9dffbc58d83e119db2782927ed8889121  S/ChatListUI/Sources/ChatListController.swift
3640c3b053dd6a3b7b7b447329d5752e3b12dfd44808443a7576d5682688370c  S/ChatListUI/Sources/Node/ChatListItem.swift
b0b219dc64342ba4ceb28300b8443984547906c535a77b7497cccb6f43ef634b  S/ChatListUI/Sources/Node/ChatListNode.swift
699cab2124bf50d6eaa62f757f805d1e746568e18ed844f386b3bac52cfe88bb  S/ChatListUI/Sources/Node/ChatListNodeEntries.swift
8628c0275e8052bde1ebbd3e2d9e33b71caf06cbe818a25872d5fb2bb5e84901  S/ChatListUI/Sources/Node/ChatListNodeLocation.swift
7b425269efdafd9f803112053b81f676116b924dbab0b46e527e873bcd268d72  S/ChatListUI/Sources/Node/ChatListViewTransition.swift
2b3270e6fa5a38e0b9785ff6c2e41369a111880068ba76756342311d4039a7d6  S/ContactsPeerItem/Sources/ContactsPeerItem.swift
8e7f58d1c3626ef7739a2a5d69eccaab0967a1a44e88474a40287c16b82b03c3  S/Emoji/Sources/EmojiFontRendering.swift
8070849537cdca22e272eacc44a4295f638d0b1813c5397b335c1203de31db92  S/HashtagSearchUI/Sources/HashtagSearchControllerNode.swift
c0c4039baa463e822d074013e91293f219c26f871a8116beb9e8bd4fac219f02  S/LocalizedPeerData/Sources/PeerTitle.swift
a94b469bf35640627d35ccb81632388a6899806d812577c8e1dba0b5098ee013  S/PeerPresenceStatusManager/Sources/PeerPresenceStatusManager.swift
e62d177dd0ac8a7ffc4860f07e831c3564c79ea3f3baca458f48cb78051aa59b  S/Postbox/Sources/ChatListTable.swift
3209b384dc3a39cf4b1c69a4f2b51c147b2a19cf2c247203900bb55d696b1165  S/Postbox/Sources/Postbox.swift
9bfcd2b723f7242af6fa65d887748caaf5ad0843c1a6086ee2ce6d6346d5bf79  S/SettingsUI/Sources/Notifications/NotificationsAndSoundsController.swift
eb28ad26bda8b4a8ff1aad73b949d4c3d24132db3aebdd1f5a4c67a5962718ee  S/SSignalKit/SwiftSignalKit/Source/Subscriber.swift
08630c786e0410459543d7cc2d56a02228345f4bb4996bcc4a79ce569b04474c  S/SSignalKit/SwiftSignalKit/Source/Timer.swift
1c375cdf598ebb26f7562204a28a7636bbe23a9a2a4156cbfc346f33402cac63  N/ExteralessDialogs/ExteralessDialogForum.swift
43522d604f48353f85c1a9ba7ab5e014e96e78ff865cb7924b8fbeeda0552d4c  N/ExteralessDialogs/ExteralessDialogList.swift
6b6bb7179fe2fd58cb1c351f833713c65330e2bbdc570492b8bebd26c71f8c86  N/ExteralessDialogs/ExteralessDialogPins.swift
ad0e4f3f58354db09465b58cc73302de8fd3073a82e261ee17c7ab080b9ad487  N/ExteralessDialogs/ExteralessDialogPolicy.swift
5a12c69e36577923fe94d5fbd171a09047bed776a36a2d1feef7a2780dcf8ec2  N/ExteralessDialogs/ExteralessDialogSearch.swift
96f429e8bf11ccdb615ddcf81de13d2c515c794cb679098bf4bf4ed395ec37bd  N/ExteralessDialogs/ExteralessDialogStories.swift
030220febb3fbf844e7424ed76f568ef3899d1b08c73a093795cac8f4f99a8a4  N/ExteralessIdentity/ExteralessIdentityMetadata.swift
e3b41f463af5178a4f78c05934afdc57f54ca6a8297f0b409f42dea465f00af6  N/ExteralessIdentity/ExteralessIdentityPresentation.swift
aa506b1f5d1ce70397a0d54e86c02d3a8c0d7fae8c89bc714a3101c832ddd323  N/ExteralessIdentity/ExteralessIdentityStore.swift
8bc47a0e3e787db7c56af64e770ceaf841f9850f6f1c7a0b8cdd5594d57878fe  N/ExteralessPrivacyExtras/ExteralessFilteringSummaries.swift
a3c2b85e610e4ca6061790cae0fa3e5c0bad43d7bc2449f21934b15f3f61d190  N/ExteralessPrivacyExtras/ExteralessFilteringText.swift
12ed7f92248a54492c150aaee1f1db4d451375ad384894fc0ff8ff9bf51aac11  N/ExteralessStickers/ExteralessEmojiPackSource.swift
ef64a9da4b5570a2a023821b797c41c2dafe8169bd3829e08817a1e4c2314529  N/ExteralessStickers/ExteralessPinnedReactions.swift
f7730a7549496f0ded781b098a8d420f31651945bb4e2ae7ab097a198697f976  N/ExteralessStickers/ExteralessStickerCollections.swift
beef68a4b019d338e3e1777a7584a4b1390b1f0fc33c815e8e25e29e241265bc  N/ExteralessStickers/ExteralessStickerFavorites.swift
ca9d5301a572ae2fbc8d6532cb3706aa90fc9e923e073ae59a297cf1b72935e2  N/ExteralessStickers/ExteralessStickerSettings.swift
a7e08a23c421e876ac5f89fafb7d5c3e722a36b15506367a82fc89b01a5898fa  N/ExteralessStickers/ExteralessUploadedEmojiSticker.swift
5a0ace71ba47d3dba48f0528467a6851fb9f132a81a220dd70f1aa00c39afa2c  N/ExteralessTools/ToolsLocalFavoriteStickers.swift
a9e51176fe6ed4ec232f80a03b90419ad6e523e6785aee09a923c423f4b4ad88  N/State/AccountStateManagementUtils.swift
fa146c6b09e8e10e3d5f2fdeaaf6a6be570aa8032c605784a7503ac9113c660a  N/State/AccountViewTracker.swift
a3365eed08adcc28f32bba29d17aa28153183c953d4417bee497c3659870a989  N/State/ManagedSynchronizePinnedChatsOperations.swift
41cdcb7919b6c7fa675d1edf773559576449b0f79e0615b7dfd65b7489c044d1  N/State/SynchronizeRecentlyUsedMediaOperations.swift
5d445fb35f2a9d62efce8d4136991fc263bd807b728e4218290bc943eb7d8c8e  N/State/SynchronizeSavedGifsOperation.swift
606f4ee903ad470c99a7912f696da27f52e817e3e002b25c2c74b3712808ebe4  N/SyncCore/SyncCore_RecentMediaItem.swift
f71d35af6ddbd9e9704d78ab84c82f55f02d341bb8458360875eadaf20decfc5  N/SyncCore/SyncCore_SynchronizePinnedChatsOperation.swift
d26dd5a9061e5ed4ad22978ced8be2263f43690e4004dea9b3c15d1a29e573e1  N/TelegramEngine/Messages/ChatList.swift
790a950f42ce605fc584492adc35949f6bab3cd038433d80179900f23e1584d8  N/TelegramEngine/Messages/StoryListContext.swift
4422c86b1df2d4e2cd5e0beb03ce3eaa66796328399dcddff3360abb4f2e1446  N/TelegramEngine/Peers/TogglePeerChatPinned.swift
942dfd27821c5aed1a210b1545cd2f8d1e350f97d5dd01cc2f471c9bfb9136ff  N/Utils/PeerUtils.swift
d34c96b7a6535cce2f06823fc2c059d7611d7b2527d4351f574c8b855e711f49  S/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift
6f579b1613fde62672d7d48d929b740feb7180e8dba7e2935a1e14f4e9d223f8  S/TelegramPresentationData/Sources/ExteralessIdentityActivity.swift
f210596261c0ad92b0c6256bd5ef8be9fb40681d8b99c786c5f14c0480f9a6de  S/TelegramPresentationData/Sources/PresentationData.swift
f216cab71f68cc1728c9843d24a019acd96f86da5fe420d45576b8c42778a935  S/TelegramStringFormatting/Sources/DateFormat.swift
c9d296279bc69754bcc10ac879779d7fa962ad15c6186a8e8d3b44ee00711a08  S/TelegramStringFormatting/Sources/ExteralessIdentityDateFormat.swift
35c2045e612b9cd001b3bb2ccc85420b6a74af3d0a01c8bc29a359512d5ece68  S/TelegramStringFormatting/Sources/PresenceStrings.swift
8a03e6db39d8fea17a0cd7f73b65a72ca0ee18ad1380ed7e0e9d069197551a7d  U/Components/Chat/ChatMessageAnimatedStickerItemNode/Sources/ChatMessageAnimatedStickerItemNode.swift
f86bd2d7e0c4c62e1beff8c284e7635384f01aedaeeaf736cecdf67b7e54a4ef  U/Components/Chat/ChatMessageDateAndStatusNode/Sources/ChatMessageDateAndStatusNode.swift
7bd83079bec9545140bec598da97ab711b3e1e748d76882127fb1f1f69e20717  U/Components/Chat/ChatMessageItemImpl/Sources/ChatMessageDateHeader.swift
266ad1061610749f02bcc209abdb56421d75db5953910fe8301b875b5eb8002d  U/Components/Chat/ChatMessageStickerItemNode/Sources/ChatMessageStickerItemNode.swift
44576aa6c31223cba6fc9a799f1be06fde66519251d6a0dafafb76e2a5e06a88  U/Components/Chat/TopMessageReactions/Sources/TopMessageReactions.swift
3a754c67fe3dcf1ca0d63938b183c97dfba93d0c999c69068c0c3e6446d3e88d  U/Components/ChatEntityKeyboardInputNode/Sources/ChatEntityKeyboardInputNode.swift
d8436e85e1d12aa179ea8bbd4df81e41da2405f8db1f05e23fe93675fe8488aa  U/Components/ChatTitleView/Sources/ChatTitleComponent.swift
cbfed3d2813824affb1f0acefb514f4ff863b0dc403d8fcd630c46351cc9d1c0  U/Components/ChatTitleView/Sources/ChatTitleView.swift
b13b9daa7da785359e623f3beef9c456137e5c1ae06be5bc58dc3d0df24ca1e6  U/Components/EntityKeyboard/Sources/EmojiKeyboardItemLayer.swift
638082aa16112565998929ab4411d9c37f3d9e60ffcabbda91f8b351712089da  U/Components/EntityKeyboard/Sources/EmojiPagerContentComponent.swift
bac6a4b867822440ff18cf1891d53a9bb0b0c06a6df897aad070b5c50c12db3c  U/Components/EntityKeyboard/Sources/EmojiPagerContentSignals.swift
ffda55d1da52be07bff6d8262ee312f53286ca1f72efb9944877b8ec0e108bc8  U/Components/EntityKeyboardGifContent/Sources/GifContext.swift
d9c0067f795fd51f9aa70171b9125ed8dfb6bbc629a98ef16a10baee51b9a976  U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift
2d3e959c505b31a5c240b71a1508761273a955470080fa33a1be7272fdc34992  U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift
a0b78ccb8a9edb54ee745cdf9b4af77c06023645b4458ada290c4c157648b2c6  U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoProfileItems.swift
db3aa6ff28e13cb0d5d0fe17ae85e80e7887f16844b597a63e82dcb807b6819d  U/Components/StickerPickerScreen/Sources/StickerPickerScreen.swift
d2ba37c4c712d6ed367af264b792b4b92f379ea9d37c292fcfed6723dadc81af  U/Sources/Chat/ChatControllerLoadDisplayNode.swift
79ed9994537452b9b62a9a9e7203053049d0bb0c15f5466315de1c05c6487058  U/Sources/ChatController.swift
cfc36317afc9454d998478578b45ac069cba89ad997833b225df689c8f658383  U/Sources/ChatControllerContentData.swift
f60431d16744426a161601974366257e0923525e2eb60d4fd21fbd826b569be5  U/Sources/ChatHistoryListNode.swift
0553b7a4dab03ae2aa487545a9d4b6c81700a1bf3df7f37623ff6dca048ed153  U/Sources/ChatHistoryNavigationStack.swift
b84eb75ebaa2e17437dbcf3c9925067db18972c78db6ef74a042aa8499e25fee  U/Sources/ChatInterfaceStateContextMenus.swift
37de31d8aa949f6a66102f69ba65911aaf9c2614ddd067cf915f98d1149d058b  U/Sources/ExteralessClient/Dialogs/ExteralessDialogBackBadge.swift
8f49ff3a8ab0ed3548ec677ff4f6d5ef9ab44f416b8f9192cd38b3e2a1a56fdd  U/Sources/ExteralessClient/Dialogs/ExteralessDialogForumController.swift
1dd9958629f3495205ce472ac32679c013632ab5b46e8e101456dd7c925651d9  U/Sources/ExteralessClient/Dialogs/ExteralessDialogHistoryControls.swift
2aae85c91ef5158c226d113f6c640384800d4c280536ef4399ef3112241b89ed  U/Sources/ExteralessClient/Dialogs/ExteralessDialogIntegration.swift
3932eb6e302b5824b3dd871b9d164ff8876d9c660b93908a756752bf78932c2e  U/Sources/ExteralessClient/ExteralessClientRuntime.swift
f9d9157367f83795c78753a7a698e84f0ab8410259b2459e6d1a807f7e60380f  U/Sources/ExteralessClient/Identity/ExteralessIdentityAliasController.swift
f140787fc72362588237777a77f007e4a3362274a67cf30f65753f7fd8f7fc4d  U/Sources/ExteralessClient/Identity/ExteralessIdentityColorsController.swift
2445d726fa762d18955c1c21845b3cbc2b75d1e378bff03511367f8fcc1a899e  U/Sources/ExteralessClient/Identity/ExteralessIdentityController.swift
6e565534d8659a3626ba338c6b9c789fbb774f37c328415347a6d4a043b1c492  U/Sources/ExteralessClient/Identity/ExteralessIdentityIntegration.swift
213d7e6aa5bfaf667640487b7091a74e89e6c0815bc6e81a7e67dd25a0e04309  U/Sources/ExteralessClient/Stickers/ExteralessEmojiPacks.swift
e06fc924b2c10bcdee812a712d54bcd6e849bd328732ba9fd038b822b46dea25  U/Sources/ExteralessClient/Stickers/ExteralessEmojiPacksController.swift
dc1e47fcc131740fb3807e3dcb700907a689109312708b55c1b744a3f4da9ae6  U/Sources/ExteralessClient/Stickers/ExteralessLocalGifsController.swift
dfd292b3d883a4b95d402968eb76688fc1e1340a21b7c8c3ab8d81b5d38c6330  U/Sources/ExteralessClient/Stickers/ExteralessPinnedReactionsController.swift
b8b39f65f083fb3a4889f0566d9d1b3d9f92f0a32eff7784718e33505f235e83  U/Sources/ExteralessClient/Stickers/ExteralessStickerChatObserver.swift
5c046caa105dde9c06eb35d84ff05b8afcdc0ce078576d1ffa9fd232e3cd07bd  U/Sources/ExteralessClient/Stickers/ExteralessStickerIntegration.swift
896cb104a8465f576c842433c91215ae27c3c251f27d7f2880b93ff93acba229  U/Sources/NavigateToChatController.swift
8e5e455916f2a0932705c0802fb0226fbc424d99d6e66539fb3e9feac8d7b74b  S/TelegramUIPreferences/Sources/ChatArchiveSettings.swift
00fc3fbe70340ed770e091a2c12e60363347992e850e16321e87310741a2d557  S/TelegramUIPreferences/Sources/InAppNotificationSettings.swift
79985925a23a8838ec62cb895b904effa24dc5ea2a40e99cbaf27c074218c1ed  S/TelegramUIPreferences/Sources/RenderedTotalUnreadCount.swift
0b91b9e5b514cdb8cd2c42a787ce6ea72e3907299107c4092b468451ef6f6fc2  S/TextFormat/Sources/DateFormat.swift
14e0a780c96f0a98452963e7403fdc87ff4667866a342ae1ffb6670046cd2300  NT/DialogNativePreferenceTests.swift
4eb490bf454d8fb441fbd2a1f5d9cfc4e236b7c2a765e8482691cf16a3baf375  NT/IdentityPresentationTests.swift
4e9db6307f1749eb13b561c89f0dd343f3e5c8cbedb41a05cef9284f6de4d1d9  NT/StickerEmojiRenderingTests.swift
ae54423263d26754bd0696eefeb1081e4c3ac0b4393830e67cf9913e9087a8c6  NT/StickerFavoritesIntegrationTests.swift
```

### Original evidence — 21-file cohort, 10:12:59 UTC

Aggregate: `6bf804a12862fa78ab7c4999fbc92efe1d375ad287ca8900e2710247e7305a7e`.
`PersianDate.java` — дополнительный отдельный pin после этого cohort.

```text
a665ba37983717c86babdd4fd29f63922e80f8760f29e35f3ced88e77389be3a  A/java/app/exteraless/utils/FaveStickersBackup.java
9ca5fa402d9715a96727002c2456fa74c45e5f29bb493bb2660bca8d7e5a3981  A/java/org/telegram/messenger/ContactsController.java
a46faf543bda00f5062960294d6b2dce4f23a149dd8b6fda4469cc03f8c03c7b  A/java/org/telegram/messenger/Emoji.java
ae6d2e8042dbeaa2ab0d65624430ce0d4a29dbd2045f9162fdc9b955742ff595  A/java/org/telegram/messenger/MediaDataController.java
10495b6e82eb4bd5d59f14b9dbc4b5f6dbda185e972985608bd345eb572367d3  A/java/org/telegram/messenger/MessagesController.java
b8118f337455fae8647b46ceabc3b91b6bf83d443a6579281ce9a26fb5cf551b  A/java/org/telegram/messenger/UserConfig.java
811724065831d55d56a061cd6b66c2778c06b8f8731d7b3631501d3172a7202e  A/java/org/telegram/messenger/UserObject.java
801994102506a37a94cf7066f459bc8a8ddd2fa247bd7e1aea312825e56fc7ab  A/java/org/telegram/ui/ActionBar/ActionBar.java
01be97e8c0947ebe10d4c0a43ffffd70fb8e5a6f9a6b4c8bbd98a4c35b8f233d  A/java/org/telegram/ui/Cells/ChatMessageCell.java
2e83ebab9172840462cd63c4b889f4d17f59ae2e71ba3480277aafd15055485b  A/java/org/telegram/ui/DialogsActivity.java
daf068484584108a5c44e2d6180927e9490850334dfabf0ee0060779e635aef0  A/java/tw/nekomimi/nekogram/DialogConfig.java
9dab494987cce3fdc7a4271630a4925daca74d2a3ce3675c08227b1562e183ec  A/java/tw/nekomimi/nekogram/NekoConfig.java
98f875078e7b0595a12cb49ba0b3e280beff834d107ab0a2923f4ee53319c345  A/java/tw/nekomimi/nekogram/helpers/ChatsHelper.java
60fae18cc315779d6abca4d30df92695f692f01417963512f146b2187c910527  A/java/tw/nekomimi/nekogram/helpers/LocalNameHelper.java
bc9b288acbbbed19dc37a9730e8b3d75d35d853164f41342f8e22985467f6db3  A/java/tw/nekomimi/nekogram/helpers/MessageHelper.java
bca29d5733dca72c002a3f5859a98479f7f15d63fbaafa770ac62e9a6b96a7b0  A/java/tw/nekomimi/nekogram/helpers/PinnedElementsHelper.java
e20e402ec88384fe9fdede5d24e5fe3cf0ab127d3b0776a7c6e4f1b00397cb54  A/java/tw/nekomimi/nekogram/helpers/remote/BaseRemoteHelper.java
a9e64b933b57a4663fb099b11fffc417d10b3bc24f21af074c4eb1a1416f786e  A/java/tw/nekomimi/nekogram/helpers/remote/EmojiHelper.java
495356be6d7050b4c5ca313ff5d4bb6be61d6ce4f3022c47fcddead222014646  A/kotlin/xyz/nextalone/nagram/NaConfig.kt
6d075ffa9a4c846ed01d4935b515afe6c1ff2d12694068056d47a42f5faae984  A/kotlin/xyz/nextalone/nagram/helper/LocalPeerColorHelper.kt
315e6d18c9940a2452839cf7d5759a487e3a00a7b68168ea31baed7fcc856982  A/kotlin/xyz/nextalone/nagram/helper/LocalPremiumStatusHelper.kt
```

### Дополнительный original и прочитанные handoffs

```text
3100f5a66370b042b7db0c1284a3f167093a82dd8ddf90d758f8fff392fd7b0b  A/java/tw/nekomimi/nekogram/shamsicalendar/PersianDate.java
9cfb347e8bdfee63746a99740fb32cd0cf3d044a9c87a1e23dd6ff49ad499cc4  docs/wave-2/identity.md
af7f191beff1bcca537ceec8129ad5018f361de1623d78d414937e15706fa070  docs/wave-2/dialogs.md
197034540bc45b16381b44036be7c4e9205969e0c0984b81f2b1e25c50895903  docs/wave-2/stickers.md
3f6db70e3f22e7e249deb5f4375ea56cc4921a5f7cda844d09cb069ff66ae9b9  docs/wave-2/stickers-integration.md
```

### Superseding shared pins — 10:27:12 UTC

Эти пять записей заменяют одноимённые pins в 10:08 cohort для текущих ссылок.
ClientSettings по-прежнему допускает overlapping callbacks и delivers после
writer unlock (IDS-07); filtering total по-прежнему исключает tags до subtraction
(IDS-05). Root account teardown/lifecycle и Identity title/wallpaper/common-groups
seams сохранены. Четыре перечисленных pending Sticker seams повторно проверены:
новых size/font/central choosing/featured insertions в них ещё нет.

```text
60f695dd0919907b5ce6af08e6a36796f4918efd839e6cde518a3cf06d0ed7e6  C/ClientSettings.swift
ee8cfa2eaaea636740dee2c20136452bef733366ed0fcbf286e9f576faf8805c  N/ExteralessPrivacyExtras/ExteralessFilteringSummaries.swift
b07c317e1cc476481c65587f2319216c7d5b7ec969ddf19585927c07e2471e02  U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift
2a56ef5578d533f2b1b5a65ecd782b43d3fc46fdc01653d8647de1e53614d022  U/Sources/ChatController.swift
dfd63b693c85cd580039274c21f9380f322f2613f44179c52594a6f90012ef94  U/Sources/ExteralessClient/ExteralessClientRuntime.swift
```

Дополнительная проверка applied GIF callsites: Gallery message/webpage
`:1892–1895,2131–2134`, inline-bot `:247–250`; реальные reference и отдельные
local-success/error callbacks присутствуют.

```text
ff90a6a03039ab823c6a818f62dd247c009f4ebcdc12d7830eab28873a98b354  S/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift
3b95af5264cdbddd92e53cef9a0718cad6e0022cdca5c54f4eaaac1cee4bd12d  U/Sources/HorizontalListContextResultsChatInputContextPanelNode.swift
```
