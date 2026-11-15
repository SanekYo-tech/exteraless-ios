# Feed / Player — final source closure: FPP-FU-01–04

**Итог: 4/4 контрпримера закрыты по source callgraph. Конкретных оставшихся P1/P2 в этом focused scope не найдено.** Это независимый source-вердикт; native compilation, XCTest, реальные Photos/Activity effects и recorded frames остаются неподтверждёнными.

Входы: неизменённый [follow-up](feed-player-pills-followup.md), final FU/terminal/direct-Save sections в [feed-remediation](../../feed-remediation.md), [Save callsites](../feed-save-callsites.md), FU-04 section в [player-remediation](../../player-remediation.md). Проверены только четыре последних finding. Предыдущее независимое закрытие CMC-14 и exact-media/time CMC принято как контекст.

Сокращения: `Feed/`, `Player/`, `Chats/` — `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/`; `FeedTests/`, `PlayerTests/` — соответственно `telegram-ios/submodules/TelegramUI/Tests/FeedTests/`, `Tests/Player/`. Остальные native пути ниже относительно `telegram-ios/submodules/`.

## FU-01 · P1 → source-closed: incomplete frontiers и переход окна

**Исходный сценарий:** A содержит 1000 сообщений с timestamp `4000 + id`, B — 20 старых сообщений; после A `1000…501` следующее окно теряло A `500…1`.

- В `Feed/ExteralessFeedTimeline.swift:180–224` переход теперь ждёт завершения текущего round и известных frontiers. `highestPending` включает **все incomplete sources**, а не только buffered/reload entries. В исходном случае `nextBound` становится A `(4501, 501)`, а не B `(20, 20)`; A `500…1` проходят upper-bound admission.
- `:298–318` по-прежнему ограничивает round четырьмя запросами с реальными before-cursors. Проверка unexpected future-range теперь стоит **до** присваивания cursor/complete и merge (`:320–349`): отказ сохраняет before для retry и показывает gap вместо ложного end.
- Consumption остаётся по composite IDs с отдельными consumed tails (`:196–214,368–375`); eviction сохраняет replay frontier (`:239–258`). Global retained-key budget действительно применяется через `swift/ExteralessCore/Sources/ExteralessCore/FeedPresentationPolicy.swift:56–73`: 500 + 4×29 = 616.

**Независимый bounded replay выполнен локально:** Python-модель этих ветвлений, только integer tuples, до 1800 входных записей; четыре before-cursors фиксируются до доставки ответов. Проверены exact union, отсутствие повторов между окнами, end и retained bound.

| Сценарий | Достигнуто IDs | Peak retained | Max in-flight |
|---|---:|---:|---:|
| Старый контроль A+B | 520 / 1020 | 520 | 2 |
| Исправленный A+B | 1020 / 1020 | 520 | 2 |
| A + 40 каналов, прямой / обратный ответы, одинаковые timestamps коротких каналов | 1800 / 1800 в обоих | 616 | 4 |
| Те же 41 канал, разнесённые timestamps коротких каналов | 1800 / 1800 в обоих порядках | 616 | 4 |

Шесть replay завершились за **0.846 s**, максимум 80 rounds; ограничители — 15 s / 256 rounds. Отдельная маленькая проверка rejection branch сохранила A before `501` при неожиданном future item. Это **не выполнение Swift timeline/XCTest** и не измерение native RAM.

Prepared regression `FeedTests/FeedFollowupTests.swift:19–128` использует сам injected `ExteralessFeedTimeline`, включая четыре captured requests и retry исходного cursor. Она прочитана, не запущена.

## FU-02 · P1 → source-closed: Gallery → root Share → Activity / Save

**Исходный сценарий:** открыть unprotected photo из Feed, затем root Share; получить peer-only copy-protection flip и попытаться сохранить/экспортировать через surviving descendant либо ready-delayed presentation.

### Actual ownership / presentation

- `Feed/ExteralessFeedActions.swift:241–268` создаёт один immutable account/original-ID permit и сохраняет policy observation после закрытия внешней панели. Protection/membership, background и account changes ведут к `feedRetireExportFlow:141–156`; timeline scope тоже подключён к retirement. Account invalidation вызывает его из `Feed/ExteralessFeedScreen.swift:260–265`.
- Direct Feed Gallery/Share передают этот permit в `presentWhenReady` с исходными generation guards (`ExteralessFeedActions.swift:102–108,309–324`). Native Footer использует **реальный guarded `makeShareController`** (`GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift:143–178,1854–1874,2068–2138,2156–2208`). Проверен concrete factory `TelegramUI/Sources/SharedAccountContext.swift:4690–4701`: возвращается `ShareController`, содержащий terminal guards.
- Root Share остаётся отдельным overlay, но теперь получает то же ownership. `AccountContext/Sources/ExteralessContentExportPermit.swift:128–184` связывает controller **до загрузки view/readiness**, удерживает wait, повторно проверяет window/permit/prepare и только затем вызывает presenter. Footer дополнительно проверяет item/player generation до и после readiness (`:154–176`). Новый grant при handoff не создаётся.
- Revocation отменяет pending wait и вызывает native nonanimated dismissal конкретного owned controller (`ExteralessContentExportPermit.swift:188–209`). Прослежен реальный root-overlay removal seam: `Display/Source/Navigation/NavigationOverlayContainer.swift:32–37`; локальный presentation context удаляет controller по identity (`Display/Source/PresentationContext.swift:210–214,255–262`). Busy success-animation не является условием отзыва.
- `GalleryUI/Sources/GalleryController.swift:1553–1586` и `ShareController/Sources/ShareController.swift:438–449` передают ownership следующим native presentations. `own(from:)` копирует validator owners; retained reference удерживает их при async work (`ExteralessContentExportPermit.swift:135–156,212–224`). Фактический CMC owner подключён через `Chats/ExteralessChatExportAccess.swift:295–296`.

### Все 7 Save calls доходят до terminal guard

Независимый запрос `\bsaveToCameraRoll\s*\(` дал те же **23 matches**; внутри назначенного flow проверены все семь facade calls, включая передаваемые arguments и их consumers:

| Actual caller | Forwarding |
|---|---|
| `GalleryUI/Sources/Items/ChatImageGalleryItem.swift:781–795` | Photo: original permit/reference, captured generation, validity, отдельный success receipt |
| `GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift:4044–4075` | HLS selected quality reference + тот же permit/reference/generation/receipt |
| Там же `:4100–4112,4152–4169` | Local video и image/paired Live Photo: тот же полный набор guards |
| `ShareController/Sources/ShareController.swift:2622–2651,2654–2685` | Message batch, image representations и exact media reference: permit + retained reference сохраняются, в том числе после standalone conversion |

`GalleryUI/Sources/ExteralessGallerySaveLifetime.swift:38–53,74–106` сохраняет original reference при исчезновении presenter; `operation()` создаёт новое receipt state без обновления epoch/grant. Generation invalidation подключена к actual photo node (`ChatImageGalleryItem.swift:464–466,1190–1202`) и video/player replacement (`UniversalVideoGalleryItem.swift:949–952,1540,2424,2486–2491`).

В `SaveToCameraRoll/Sources/SaveToCameraRoll.swift:393–423` nonnil permit выбирает guarded operation и проверяется соответствие reference/composite message IDs. Далее permission/preparation callbacks повторно проверяют permit/current (`:178–238`), а **сам `PHPhotoLibrary.performChanges` change block** вызывает commit guard вокруг asset creation (`:334–371`). Only-once phase admission и `success && committed` доходят до receipt `1.0` (`:241–264`); download progress ограничен 0.99. Fail/cancel/empty/unclaimed completion не дают Saved UI: actual Share Node идёт через `exteralessShareConfirmedProgress` и generation-checked completion (`ShareControllerNode.swift:34–64,2025–2029,2093–2110`), direct callers используют собственный receipt.

### External Activity

`ShareController.swift:1228–1284,1390–1434` переносит **тот же permit и owners** на `UIActivityViewController`; payload обёрнут в `ExteralessShareActivityItem`. Placeholder/nil-activity requests не выдают реальный контент, а typed item request проверяет live permit непосредственно перед выдачей (`:98–115`). File staging выполняется под admission lock и имеет owned cleanup (`:119–134`). Отозванный исходный flow не превращается в nil-permit stock path после исчезновения Gallery/Share.

Таким образом, прежний root-sibling bypass и queued-ready продолжение закрыты на фактических callers и sinks. Prepared `FeedExportPermitTests`, `FeedActivityExportTests`, `FeedTerminalExportTests` и `FeedGalleryDirectSaveTests` прочитаны; они не считаются native pass. Already-admitted Photos/activity work не описывается как физически отменённое: closure относится к новым admissions и late success после retirement.

## FU-03 · P2 → source-closed: retained A, semantic cache и native node

**Исходный сценарий:** у видимого A раскрыта quote/выбраны poll options; добавление либо удаление B из observed IDs пересоздавало token A и весь renderer.

- Production timeline теперь создаёт один `ExteralessFeedProjectionSession`, захваченный обоими closures (`Feed/ExteralessFeedTimeline.swift:51–59`). Смена ID set вызывает тот же session, а account clear освобождает его cache (`:114–116,379–420`).
- `TelegramCore/Sources/TelegramEngine/Messages/ExteralessFeedMessageProjection.swift:76–107,162–198` сохраняет old/new intersection и отделяет binding generation от render token. Проверен **production** путь `:263–314`: dependencies сравниваются семантически (`:52–73,109–156`), unchanged A берётся из cache; fresh transaction вызывается для изменённых зависимостей. Peer-only/reply-only изменения всё ещё доходят до нового projection/token. Mutable rich full-page snapshot хранится отдельно от render payload.
- Actual Feed table использует row-ID diff и конфигурирует surviving cells (`Feed/ExteralessFeedScreen.swift:425–456`). Cell при unchanged A не перестраивается; при совместимом изменении вызывает `updateNode`, сохраняя installed post/primary/renderer identity (`Feed/ExteralessFeedMessageCell.swift:147–188,254–267`). Проверен нижний native consumer: `TelegramUI/Components/Chat/ChatMessageItemImpl/Sources/ChatMessageItemImpl.swift:469–474` использует существующий node; `TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift:2085–2107,3097–3105` переиспользует его content nodes по type/index/stableId. Обновление policy не требует уничтожать quote/poll state.

Prepared `FeedTests/FeedFollowupTests.swift:130–193,218–258` проверяет `{A} → {A,B} → {A}`, semantic re-decode и peer/reply/rich changes через injected session. Это не исполнение production Postbox observation; source callgraph выше проверен отдельно. Фактическое сохранение quote/poll в кадрах pending.

## FU-04 · P2 → source-closed: полный Surface update + trailing tick

**Исходный сценарий:** paused synced lyrics, Inline → Karaoke, ручной scroll далеко от active line, истёкшие пять секунд, затем palette/font change; второй Surface tick возвращал auto-follow.

- `Player/ExteralessPlayerSurface.swift:211–215,265–275` вычисляет **один sample и один allowFollow для обоих вызовов**. При неизменённых paused track/position/duration `lyricsMayFollow` возвращает false (`:310–321`); отдельный последующий tick использует то же сравнение (`:330–344`). Native session в paused state не экстраполирует позицию (`Player/ExteralessPlayerSession.swift:115–131`).
- `Player/ExteralessPlayerLyricsView.swift:119–147` принимает explicit follow flag в `updatePosition`; default-true второго шага больше нет. Styling обновляет visible cells и восстанавливает font anchor (`:158–208`) без сброса manual-follow state. Artwork palette callback также передаёт false (`ExteralessPlayerSurface.swift:162–167`).
- Seek остаётся в gesture callbacks (`ExteralessPlayerSurface.swift:140–155`); whole appearance render не выполняет seek и не обновляет scrub lease. Prepared `PlayerTests/PlayerSurfaceFollowingTests.swift:10–83` проходит **actual Surface**, включая update → tick → ещё tick, expired manual deadline, palette/font change, playing positive control и сохранённый seek lease. Factory forwarding проверен в `Player/ExteralessPlayerVisualSurface.swift:39–50` и `ExteralessPlayerSurface.swift:494–505`.

Следовательно, исходный same-position paused counterexample больше не имеет ветки, включающей following. Три UIKit регрессии и scroll/color/font frames не выполнялись в этом ревью.

## Уровень доказательств

- **Выполнено reviewer:** чтение actual callgraph/continuations, проверка exact source hashes, bounded tuple replay FU-01. Эти действия не являются Swift typecheck, XCTest или native run.
- **Сообщённые результаты:** Core-stage green350 и pytest628/180/30 относятся к прежнему scope. Их green не переносится на этот native snapshot. CI не запрашивался и не запускался.
- Указанные пользователем **46 existing Feed/native и новые 9 terminal fixtures** остаются written/not run. В final source дополнительно прочитан пяти-методный direct-Save suite; три Surface-following метода тоже prepared. Количество файлов/методов и совпадение pins не доказывают выполнение.
- Apple build, Photos/Activity behavior и labelled frames pending. Для visual acceptance ещё нужны кадры surviving A с quote/poll, paused manually scrolled lyrics после styling и отзыва owned root descendants при сохранении постороннего overlay. Source closure не является visual acceptance.
- Account/Network не создавались; live accounts, CI, provider/plugin/network/export effects, commits и pushes не выполнялись. Implementation и оба старых report — read-only; единственная запись reviewer — этот файл.

## Срез и неизменность входов

Фиксация evidence: **2026-11-15T14:47:13Z**, HEAD `4476f853e27d011ee7acc43cadccf5f7da9f7eb1` плюс фактические dirty/untracked source bytes. В начале задачи наблюдался `d8cbdaca17272ba848ac65be2b4dcbbc6b175275`; HEAD изменён другой сессией. Заключительная сверка уже при `46393e31b26741c6f80ff2f9547a960ad10af5c7` подтвердила все **60/60** evidence hashes, неизменность обоих старых reports и 118 explicit line-reference bounds.

Оба frozen manifest проверены по каждому файлу:

| Manifest | Совпало | SHA-256 canonical manifest (LF) |
|---|---:|---|
| [`feed-fu-native-frozen.sha256`](../feed-fu-native-frozen.sha256) | 36/36 | `a11351633da81d23754b9dea018974b09aa38a08276f4da4aa5612b9738e9c0c` |
| [`feed-core-frozen.sha256`](../feed-core-frozen.sha256) | 8/8 | `84d493ade4fce706d3f8583a5b88ecdecc2c59960791a1d1e29352bab52ff975` |

SHA-256 старых reports до/после:

- `feed-player-pills.md`: `b1f2bb3ca1826c59430456a25b57880b6d49af196314feddaa552266501fbfa9`.
- `feed-player-pills-followup.md`: `6970849877b6b0023e09f95cc18bec1463052f8fd405828849f41d73c99d877e`.

<details>
<summary>16 дополнительных source/fixture fingerprints вне двух Feed manifests</summary>

SHA-256 этого списка (`hash`, два пробела, path, LF): `eefe74db287ff72fbca5d6c9171457ae4dd6da6a1ed7ec9861aea59f5bb7c36b`.

```text
fe929acf1b8d24cb613dc1e4e5b3b9ce631a06f77f5b51ac00c67c1f53ebc44f  telegram-ios/submodules/Display/Source/Navigation/NavigationOverlayContainer.swift
a7fc1b45f49be45e8764942de7040c657303a4ed676d23a456755b2615cfea9b  telegram-ios/submodules/Display/Source/PresentationContext.swift
906dc689c32c820d092cd8f1ea2d8ac393ecb823f51acfd5543a3d10dbcd8d68  telegram-ios/submodules/Display/Source/ViewController.swift
ffddee32acbc80607fbf5c96ab339a8c600cae57e055337cab8d672c734ff4a7  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/Message.swift
6e20962f5b4052589220b3bf0d636bbe0fbad46006da93b5b100840f39b53513  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift
8706b8ae843c6cda4a4318e1100df521a14798852f8f71ed6f2796f515ff69b1  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageItemImpl/Sources/ChatMessageItemImpl.swift
a097e11e4145ada572d14cf2cae2e30472768fd93d7da4f0ed3c547c7953bf14  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessagePollBubbleContentNode/Sources/ChatMessagePollBubbleContentNode.swift
8fa2b7b33503ca33661d4d8b08a26a5b59c461f315f0d26689d886e87bc3ed7f  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift
ccf3270935ad714892c7b4e3d6d2cf73ecdf707a124af344edc9087ee7c9846c  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatExportAccess.swift
c0b3eb364e4b3c2915457d99b85ba4cf796a8511f25b596e0e7fc27c6064d7db  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerLyricsView.swift
d69de84f1b47cccd73599f8bc6b6e8d852a5409b7511f92b53b70fbdf83f9087  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSession.swift
bcdf9e61c3c84ec274d0967f166cbb5bfba7e3edd55c6bbfa1015172f1f2c708  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSurface.swift
0b2fd78e3279d3f54e80ba1d89c36fc7d5f099a617a0aefa19da8f8fc4b70109  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerVisualSurface.swift
4d6a22ae9d3e72eba29c3b025309d508b2b0d9debb6caaa4685cb48ce76dffa8  telegram-ios/submodules/TelegramUI/Sources/SharedAccountContext.swift
899946b36fb430f45d65e5743d9216135e394a9c72f0e8d38f7ab1d5919c54f2  telegram-ios/submodules/TelegramUI/Tests/Player/PlayerSurfaceFollowingTests.swift
1c6db3ddac98afea4f52ae87261c2cd375e87bb54522737f220d0cbdfe1e4e04  telegram-ios/submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UIViewController+Navigation.m
```

</details>
