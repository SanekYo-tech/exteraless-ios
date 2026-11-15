# Feed / Player / Pills — focused independent follow-up

**Осталось 2 P1 и 2 P2.** Прямые контрпримеры FPP-01/03/04/05/06/07/09/10 исправлены на уровне прослеженного source callgraph. FPP-02 и FPP-08 закрыты не полностью; новый window-replay код теряет непоказанные IDs. Это source review, не native/XCTest/visual pass.

Reviewed handoffs: `docs/feed-remediation.md`, `docs/player-remediation.md`, `docs/wave-2/pills-remediation.md`, `docs/wave-2/reviews/chat-FPP01-remediation.md`; исходные контрпримеры — в неизменённом `feed-player-pills.md`.

## Оставшиеся findings

### FPP-FU-01 — P1: next window пропускает ещё не загруженный диапазон незавершённого канала

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedTimeline.swift:180–190,343–347`.

`highestPending` учитывает только retained `remaining` и `reload.highestDiscarded`. Обычный incomplete source, у которого следующая страница ещё ни разу не загружалась, туда не входит. При этом его cursor продолжает двигаться при backfill, а `merge` безвозвратно для текущего просмотра отбрасывает всё выше нового `windowUpperBound`.

**Контрпример через actual orchestration: подходящие joined channels, Cloud IDs, без альбомов.**

1. A содержит IDs `1…1000`, timestamp = `4000 + id`; B содержит IDs `1…20`, timestamps `1…20`.
2. Увеличить loaded window до 500. Видны A `1000…501`; `A.cursor = (4501, A, 501)`, `A.complete == false`, `A.reload == nil`. B полностью загружен, но ещё не показан. Всего retained 520, eviction даже не требуется.
3. Нажать Next window. `highestPending` становится `(20, B, 20)`, и это значение записывается в `windowUpperBound`.
4. Следующие 25 native-shaped страниц A содержат `500…1` с timestamps `4500…4001`. Все они отбрасываются строкой 346. Строки 321–324 всё равно продвигают cursor и затем ставят `complete = true`. Feed доходит до end, показав всего 520 из 1020 IDs.

Это новый дефект относительно исходного `FeedTimelineLoader.java:354–378,574–577`, где older query продолжает cursor показанного диапазона, а не прыгает к старому buffered посту другого канала.

**Дополнительный bounded replay:** локальная Python-модель только integer tuples, соответствующая веткам `loadMore/updateVisible/loadNextRound/merge`, с четырьмя одновременно captured before-cursors:

| Sources / порядок ответов | Ожидалось IDs | Показано | Пропущено | Peak retained |
|---|---:|---:|---:|---:|
| A + один B, прямой | 1020 | 520 | A `1…500` | 520 |
| A + 40 коротких каналов, прямой | 1800 | 1300 | A `1…500` | 616 |
| A + 40 коротких каналов, обратный | 1800 | 1300 | A `1…500` | 616 |

Три сценария завершились за 0.654s; максимум 1800 входных tuples, лимит 256 rounds и 15s. Это независимая проверка арифметики/ветвлений, **не выполнение Swift/Native tests**. Существенно: соблюдение лимита 616 само по себе не сохраняет полноту.

**Исправление:** верхняя граница следующего окна должна учитывать frontier всех incomplete sources, включая ещё не загруженную историю; сохранить строгие правила consumed IDs и album-tail exceptions. Не продвигать cursor мимо записей, отброшенных из-за ошибочно заниженного upper bound.

**Регрессия:** добавить этот случай в реальный injected `ExteralessFeedTimeline` fixture, включая 41 source и оба порядка четырёх in-flight ответов; проверить полноту объединения окон, отсутствие duplicates, eventual end и retained ≤616. Текущий `FeedRemediationNativeTests.swift:181–213` использует 40 каналов по **ровно одной полной 20-message странице**; при переходе там нет обычного incomplete source, поэтому он не ловит этот дефект.

### FPP-FU-02 — P1: отзыв Gallery не отзывает открытый через неё root Share/Save flow

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedActions.swift:232–245`; native continuation: `telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift:1947–2017`.

**Сценарий:** открыть из Feed пока ещё unprotected photo → Gallery → Share / Save; оставить share sheet открытым, затем получить peer-only включение copy protection без редактирования поста. После закрытия Gallery нажать Save/External Share в уже открытом sheet.

**Callgraph/evidence:**

- Fresh feed admission и protected projection теперь корректны. Но Feed запоминает только один `feedActiveGallery` (`ExteralessFeedScreen.swift:23–24`, `ExteralessFeedActions.swift:101–104`). На protection flip он dismiss-ит именно его и освобождает watcher.
- Gallery footer создаёт **другой** ShareController и показывает его непосредственно через `sharedContext.mainWindow.present(..., on: .root)` (`ChatItemGalleryFooterContentNode.swift:1947–2017`). Это обходит `feedPresent`, `feedFreshActions` и регистрацию `feedActiveGallery`.
- `WindowContent.swift:1486–1499` помещает такой ShareController в root navigation overlay. Feed Gallery расположена в собственном `.current` presentation context. `PresentationContext.swift:255–262` удаляет только указанный controller: sibling root overlay не становится дочерним lifetime Gallery.
- Для одной фотографии footer уже превратил subject в `.image(representations)` (`ChatItemGalleryFooterContentNode.swift:1845–1847`). ShareController сохраняет её через standalone media (`ShareController.swift:2423–2430`) и собирает external items из этого subject (`:959–979`). Там нет feed permit или повторной проверки актуальной peer protection. Сохранение уже не зависит от существования Gallery footer.

Аналогичный ownership gap есть у continuation, ожидающего готовности presentation: `PresentationContext.present` удерживает controller в ready callback (`PresentationContext.swift:157–162,184–214`), тогда как Feed проверяет generation **до** enqueue. Dismiss ещё не представленного controller не отменяет этот ready callback. Для уже открытого root Share выше временная гонка не требуется.

**Исправление:** протянуть отзываемый account/message/export permit до native Gallery → Share/Save continuations и финального presentation/effect admission; отслеживать их как принадлежащие этому flow. Закрывать только его presentations при protection/scope/account retirement. Fresh setter и dismiss outer Gallery недостаточны.

**Регрессия:** accountless presentation/export spies для Gallery → root Share с photo subject; после protection flip ни Save, ни external preparation не допускаются, descendant/queued presentations отозваны. Дополнительно ready-delayed direct Feed Share и account retirement. Existing fresh-action test проверяет только callback после injected fetch, не эти native continuations; native UI/frames остаются pending. Реальные clipboard/Photos/network effects в ревью не выполнялись.

### FPP-FU-03 — P2: изменение observed IDs пересоздаёт renderer неизменённых постов

**Место:** `telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/ExteralessFeedMessageProjection.swift:130–135,169–179`; consumer: `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedMessageCell.swift:140–142,166–178`.

**Сценарий:** развернуть collapsible quote в видимом посте A. В другом included канале появляется новый пост либо приходит очередная страница; сам A, его peers, replies и version не меняются.

**Доказательство:** `ExteralessFeedTimeline.observeWindow` при любом изменении множества IDs заменяет `windowSource(ids)` (`:354–362`). Новый `exteralessFeedMessageProjections` создаёт пустой `ExteralessFeedProjectionCache` внутри каждого subscription. Поэтому все существующие roots считаются changed, и `exteralessFeedReadProjection` выдаёт каждому новый UUID. Cell трактует смену tokens как изменение и вызывает `nodeConfiguredForParams`, снимая предыдущий node вместо `updateNode`.

Это не только потенциальная стоимость layout: expanded quote state хранится в самом node, `ChatMessageTextBubbleContentNode.swift:119,170–179` (`expandedBlockIds`), и новый node начинает с пустого набора. Аналогично теряются неподтверждённые multiple-choice selections; native media nodes заменяются. Стабильность UUID доказана лишь внутри одного неизменного subscription, а не actual retained-window lifecycle.

**Исправление:** удерживать dependency/token cache для пересечения old/new ID sets на уровне lifetime timeline/projection session, со сравнением actual render данных вместо новых адресов объектов после resubscribe; обновлять совместимый existing item node вместо безусловного пересоздания. Peer-only/reply изменения всё ещё должны обновлять policy/render данные.

**Регрессия:** actual projection-owner fixture `{A} → {A,B} → {A}` с неизменённым A: token/node identity и expanded quote сохраняются; изменение только peer flag или reply A по-прежнему приводит к нужному update. Нынешний FPP-02 native fixture вручную конструирует разные projections, поэтому не проверяет эту стабильность producer.

### FPP-FU-04 — P2: после palette-only update Surface снова включает auto-follow paused lyrics

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSurface.swift:215–224,264–271`; `ExteralessPlayerLyricsView.swift:113–114,118–133`.

**Сценарий:** paused track с длинными synced lyrics. Переключить Inline → Karaoke, вручную прокрутить к другой строке, дать истечь пятисекундной паузе following. Автоматически переключить day/dark theme, сохранив открытый full player и тот же playback timestamp.

`changeMode` обнуляет `lastAutomaticScroll` (`ExteralessPlayerLyricsView.swift:256`). Palette update теперь правильно перекрашивает все visible cells и передаёт `allowAutomaticScroll: false`, сохраняя offset. Но actual `Surface.render` сразу после `updateLyricsPresentation()` вызывает `tick()`. Внутри него `lyrics.updatePosition(position, duration:)` опять использует default **true**. При `lastAutomaticScroll != index` и истёкшем `resumeFollowAt` выполняется `scrollToRow(..., .middle)`. Тем самым второй вызов отменяет обещание первого не двигать вручную прокрученный paused текст.

**Исправление:** различать playback tick и appearance-only render; не включать following на повторной обработке неизменённого paused timestamp после styling. Цвета/шрифты, seek identity и manual-follow state должны обновляться согласованно.

**Регрессия:** native accountless lyrics fixture с достаточно длинным документом и offset вдали от active line должен пройти **обе** операции actual Surface sequence, а не только `lyrics.update`. Сохранить offset после palette/font change и последующего same-position tick; ноль seek callbacks. `PlayerLyricsAppearanceTests` сейчас вызывает view update непосредственно, минуя финальный Surface tick. Это source counterexample; фактические кадры прокрутки не записывались.

## Follow-through FPP-01–10

| ID | Результат focused source проверки |
|---|---|
| FPP-01 | Исходный A→B late action закрыт: Settings всё ещё передаёт свой context через актуальный registry callback (`ExteralessSettingsController.swift:151–159`), но actual actions теперь создаются в `ExteralessChatIntegration.registerActions`, захватывают activation lease и lazy factory; `open:65–71` проверяет exact context, `ChatContextPresentationScope.open:47–53` проверяет epoch до factory и после неё. `clearContext` retires scope. Проверены registry callsite и scope, не только helper test. |
| FPP-02 | Fresh transaction, basic-peer/related-message dependencies, UUID invalidation, direct Copy/Share admission и первоначальная protected Gallery действительно соединены. Остатки — FU-02 и FU-03; полный flow не закрыт. |
| FPP-03 | Actual publisher создан mini-controller (`ExteralessPlayerIntegration.swift:128–140`), вызывается до/после frame update (`:195–199`) и на geometry/hide/attach. Registry фильтрует immutable account + identical weak UIWindow; consumer конвертирует window rectangles в table coordinates, применяет insets и отвергает occluded small/tall/album receipts. Publisher сохраняет старые rectangles при transition и добавляет текущий model/presentation rectangle. Исходный steady-state контрпример закрыт source; animation/window native proof pending. |
| FPP-04 | UI удерживает отдельный `ExteralessFeedVisibleMetadataLease`, независимый от page disposal. В production это один `wrappedMessageHistorySignal(.customChatContents)`: branch реально возвращает `history` (`AccountViewTracker.swift:2026–2088`), а его viewId вызывает native `updatePolls/updatePendingWebpages` и reference-counted cleanup (`:1992–2009`, `:498–537`). 32-ID cap, visible-set update и stop подключены. Исходная lifetime ошибка устранена source; существующий fixture использует fake lease и ещё не подтверждает execution native refcounts. |
| FPP-05 | Header `prepare/attach` теперь до cached foreground subscribe (`ExteralessFeedScreen.swift:133–160`), тот же instance запускается и idempotently возобновляется. Синхронная `combineLatest` emission больше не теряется. |
| FPP-06 | Actual session и classic overlay используют checked native update. `SavedMusic.swift:129–152,214–246` допускает cache mutation только после true RPC response; false/error/missing response не превращаются в успех. IDs preference обновляется вне optional profile cache; profile-context projection идёт через success-only `beforeCompleted`. Cold-cache counterexample устранён source; Postbox/native fixtures не запускались reviewer. |
| FPP-07 | `parse` проверяет repetition × UTF-8/word budget **до** append (`PlayerLyrics.swift:115–120`); result/embedded/override/candidate paths используют checkedFootprint. Search передаёт remaining budget следующему parser, 40-record typed decoder ограничен; fallback admission сохраняет приоритет synced upgrade. Cache/override upper-bound admission предшествует JSONEncoder (`PlayerLyricsClient.swift:381–409`). 4545-byte expansion и исходный encode-then-trim путь закрыты source; reported Core budget pass относится к этой части, не к UIKit. |
| FPP-08 | Новая palette предшествует дочернему update; visible plain/adjacent/karaoke cells перекрашиваются, font change remeasures с anchor. Остаток actual callgraph — FU-04. |
| FPP-09 | Independent `pills.status` реально зарегистрирован (`ExteralessPillIntegration.swift:13–20`) и передаёт actual factory через exact-context/valid-lease gate до construction. Empty/invalid/dormant layout не ограничивает entry. A→B и clear не создают old runtime. Исходный контрпример закрыт source. |
| FPP-10 | Stable Core registry действительно использует trailing delivery: один latest DTO/один timer, fixed 250ms deadline, current-owner/account проверки при delivery, очистка pending/closures на cancel/unregister. Loading→ready/failed больше не теряется. Native renderer получает этот путь через прежнюю subscription, не отдельный bridge workaround. Reported all-Pill31 pass учитывается; внешний plugin/GIL runtime не запускался. |

Compound membership write тоже прослежен до обоих UI consumers: `Chats/ExteralessFeedController.swift:78–85` и avatar exclude/undo `Feed/ExteralessFeedActions.swift:358–365` передают **тот же** исходный snapshot в `FeedSettingsStore.write`. Все четыре maps входят в один `applyPublic(..., expected:)` (`FeedSettingsStore.swift:35–51`), включая read dependencies. Прежний multi-set разрыв устранён source. Global retained dictionary действительно ограничен 616, но полнота связанного cursor replay не соблюдается (FU-01).

## Evidence levels / ограничения проверки

- **CI, сообщённый coordinator/user:** `f99909b5` / run `43700711108` скомпилировал 485 Core tests; один Cloud retry failure. Settings45, AI75, все Pill31, новые PlayerLyricsBudget и CoreHidden прошли. Это не «вся волна зелёная» и не native proof. CI в этом follow-up не запускался и не запрашивался.
- **Новый Feed freeze:** локально все 8 записей `docs/wave-2/feed-core-frozen.sha256` совпали. При сравнении с локальным git object `f99909b5` пять из восьми frozen файлов новые/изменены; только `ChatFeedPolicy`, `FeedFeatures`, `FeedUnreadTracker` совпадают byte-for-byte. Следовательно, указанный Core CI не подтверждает новый Feed slice. Это hash/source comparison, не XCTest.
- **Native:** указанные user Native13 + Player7 не исполнялись; отдельно прочитаны prepared Feed, Pill entry, Player occlusion/appearance и SavedMusic Postbox fixtures. Их presence/содержимое не считается passed tests. Нет recorded frames, visual/animation/GIF pass или device measurements.
- **Local execution reviewer:** только bounded tuple replay выше и read-only hashing/source checks. Не создавались Account/Network, не выполнялись live read/share/save/provider/plugin effects; нет Swift/XCTest, CI, commits или implementation edits. Единственная запись — этот follow-up; первоначальный report сохранён.
- Chat-owner legacy receipts/Identity ChatController work in progress не включался в scope вердикта FPP-01. Незавершённые PluginPill bridge/provider internals также не использовались как основание для закрытия stable registry findings.

## Snapshot

Начальный HEAD — `f99909b58968b69dfb57132db9dd84d2e28889cc`. Во время follow-up другие сессии добавили `c7ef25ed` и `38d71afe`; финальная фиксация source на `2026-11-15T10:30:32Z`: HEAD `38d71afef870e31f0da342fa20d8d1882aa3fec9` плюс dirty/untracked native remediation. Основные четыре finding sites после этого перечитаны. Новых CI результатов из этих commits не выводится.

Первоначальный report SHA-256 до/после: `b1f2bb3ca1826c59430456a25b57880b6d49af196314feddaa552266501fbfa9`. Frozen Core manifest: `84d493ade4fce706d3f8583a5b88ecdecc2c59960791a1d1e29352bab52ff975`.

- Snapshot ниже: **69 files = 27 tracked + 42 untracked**; SHA-256 canonical manifest `1307b63013b378343bf896ccc4eee092a30c8ee973032972d60312bd46852010`.
- Exact tracked delta к `f99909b5`: `git -c core.autocrlf=false diff --binary --no-ext-diff --no-textconv f99909b5 -- <paths below>`; **78626 bytes**, SHA-256 `c5af7d9aad6b3c16312f2bf6472a0bf26e6135b7a713885346f98f98d2d34d45`.
- Untracked source учтён полным file hash, не пустым `git diff`. Manifest format: SHA-256 исходных bytes, два пробела, repo-relative POSIX path, LF; порядок путей лексикографический. Source/hash checks не являются Swift tests.

<details>
<summary>Точные hashes source / fixture evidence</summary>

```text
00e9c76a0355ae1dc900f1ff73284f3874ce57cdadb7cb790d8b03e5a325f9e4  swift/ExteralessCore/Sources/ExteralessCore/ChatContextPresentationScope.swift
1700af181c817769d5907fd2f01cdee032d46961148e41bf6a87e8d863fbd2d1  swift/ExteralessCore/Sources/ExteralessCore/ChatFeedPolicy.swift
c3dd5e22c96f794bc68afeed58ab93616258978582d40f2280a0e6d8596fde30  swift/ExteralessCore/Sources/ExteralessCore/FeedContentGeometry.swift
eaeb6c3ffb37dfc5c55e69981e1baf3674ea2b32805820a213d5829dfb0ca9e5  swift/ExteralessCore/Sources/ExteralessCore/FeedPresentationPolicy.swift
8ed350f616e1b51f7f6e001732f135099e787d9e9eed69ccbe17bd3f8c761b5e  swift/ExteralessCore/Sources/ExteralessCore/FeedSettingsStore.swift
7f3899a41393799bc81c661b10dd2749a9c493aaa33a16b2a8af7f13a72cc255  swift/ExteralessCore/Sources/ExteralessCore/FeedUnreadTracker.swift
8d4adda035b5538556daca7a8164ceb50f8714d53f902f7dc5de5a361222ae71  swift/ExteralessCore/Sources/ExteralessCore/PillPluginRegistry.swift
ce9f7ca43ee83301078505bc468abac9dc4b12e282872632df15e121cdd63615  swift/ExteralessCore/Sources/ExteralessCore/PlayerLyrics.swift
a5ec6fcfbc2ba471cfc0979b5ab05732c5782ddbd188974730653910df0521ea  swift/ExteralessCore/Sources/ExteralessCore/PlayerLyricsBudget.swift
af44dc901916d2d27ff099f22c73c09a4cb7358463da02addad13478718f2f6c  swift/ExteralessCore/Sources/ExteralessCore/PlayerLyricsClient.swift
aff2a340848e0a419e17bef990c22e78aa6c3d8c937244361f943d68ffcd1ec2  swift/ExteralessCore/Sources/ExteralessCore/PlayerLyricsHTTP.swift
87ab4bb4c65f8894ddbe64bd4c724e4e4e888a878a67e34b21ce0310305821b6  swift/ExteralessCore/Tests/ExteralessCoreTests/ChatContextPresentationScopeTests.swift
2b1928df6ed4eefa7dbe6775e289da1b0e5bedaffa540f85e23356c63d6f901a  swift/ExteralessCore/Tests/ExteralessCoreTests/FeedRemediationTests.swift
9ce2fe2f32e7d8c3a382dc259f190f13c0a4e103fffd7a65c695603b44c96697  swift/ExteralessCore/Tests/ExteralessCoreTests/PillPluginRegistryTests.swift
8a996807293de8e0284e171f4ab32198a0f20b76c36fa763a4df1e5ab71d69e3  swift/ExteralessCore/Tests/ExteralessCoreTests/PlayerLyricsBudgetTests.swift
038d2982add2cabf0565af3b293a7a8e8d71dc5608869056feae85e674ed7650  telegram-ios/Tests/Exteraless/PillSettingsEntryContractsTests.swift
eba610dd717c5af463f45340cb0b38f5c3cf4511d546d159be2b7e68b70f5361  telegram-ios/submodules/AccountContext/Sources/ExteralessContentOcclusions.swift
a7fc1b45f49be45e8764942de7040c657303a4ed676d23a456755b2615cfea9b  telegram-ios/submodules/Display/Source/PresentationContext.swift
906dc689c32c820d092cd8f1ea2d8ac393ecb823f51acfd5543a3d10dbcd8d68  telegram-ios/submodules/Display/Source/ViewController.swift
2dc1fec753da9171182b10fb793e49764bf21e85bcaa0fd4db65ff153b81780a  telegram-ios/submodules/Display/Source/WindowContent.swift
ff90a6a03039ab823c6a818f62dd247c009f4ebcdc12d7830eab28873a98b354  telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift
98fafe199cbcc581845f8581c21f06fda40f630ef98f22199aca7b23a37ec88b  telegram-ios/submodules/GalleryUI/Sources/GalleryController.swift
d45dfbd29349179239acb4ff614d1c2b113e1b4e937d7244ff547898afcd917f  telegram-ios/submodules/ShareController/Sources/ShareController.swift
fa146c6b09e8e10e3d5f2fdeaaf6a6be570aa8032c605784a7503ac9113c660a  telegram-ios/submodules/TelegramCore/Sources/State/AccountViewTracker.swift
9912e328c8162358e3babed4e89454b6927d24ce69542fba0ceceec496c47f3b  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/ExteralessFeedHistory.swift
6ec70512bdd8aa21f35656b9157ce28269dcf92f66b5189435691cf5ed5dccd5  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/ExteralessFeedMessageProjection.swift
534d85f9dade202d995336883e812d1803f292abaaaeb07fb86f9bce1d2b2eee  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/ExteralessFeedVisibleMetadata.swift
ca105410b75f5869bcf1ff6ecf222e0fe0d3e13771814dba3ba332b25851bb8d  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/SavedMusic.swift
65a42a429deaa988cf27088134b9066527037fd93e1a6bf37cab6c54cbdf1a70  telegram-ios/submodules/TelegramCore/Tests/PlayerSavedMusicTests.swift
8706b8ae843c6cda4a4318e1100df521a14798852f8f71ed6f2796f515ff69b1  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageItemImpl/Sources/ChatMessageItemImpl.swift
8fa2b7b33503ca33661d4d8b08a26a5b59c461f315f0d26689d886e87bc3ed7f  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift
57048dd7f6bb5128c03e78ae67367947a3760ee311de45a9b85fc26e97223dc6  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatIntegration.swift
738d48806e2bce59603c6c4384d5ddd98105166cf747f650668d861e519596d4  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatTableController.swift
9ecfe65526b755e90d35850b8ae6907f18704453e5aa8293229a3aae184e342d  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessFeedController.swift
7ce2c3afcb20f5dec2b1590441c480774f691a91d84951ac8b1dec79e7cfea7e  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessGalleryChatActions.swift
dbbf98be8d14cf57c048268ac1de8813d865615b838a306c06ef4f7697cf32b1  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessPillStack.swift
6eb4ced5c24af192e3b099337563314b9e6ff444a36d565d305748a597218043  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift
c16c2b5f05fd3a52e6b8cfbc863d07b58be3ef7a4014b18ff2f082152407ee9f  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedActions.swift
42e157360f0bd45db8cc744a3e65cb13ec8fba98a71a559459a58d55c99b5ac8  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedChannelRegistry.swift
96655621a14f7580a5976956cac491c519886393fbc1180f23a599ecb7c7bee1  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedFreshActions.swift
44fb111ba0188437a85cd5aaf44409325edd76e089a3434be84b4c5e1615f2bb  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedHeaderLifecycle.swift
48f54e3c6223b6f15c6ae2c51fcd3fa7f83418edd861e64c86855bd369d21dac  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedIntegration.swift
1bfae84f7bb6a62e7753d0b013ee64c11021eb389566551fbcb22881102f4aaf  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedMessageCell.swift
9ccc1f9885df9a83133c465f3cfe1be0390a975f69dd7697318165e5af227f4b  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedMessageInteraction.swift
608300a74813fa6c0c75149cdf44bd7b2704538d706ff9287e0765faf7dfdc86  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedOcclusionPrototype.swift
92133cddb3304e8df14582476886eb9e78a34021211515abc95ffefa8f9673f5  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedReadState.swift
6fd1f6e0be5ac790e28f833052b70e7cf4bdaa59cb176cbc25bf547b7eec1796  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedScreen.swift
58797b195725ade85eeac1eaa2f0f1fcd5229fc652ac993f0b87570d5f5bd450  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedSmoke.swift
02c6393a925ecaf542d34c22cdb15dafa262c5b16c67d622cc88f9b3cdd1326b  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedTimeline.swift
fb896e4f9779682c6aa115824b05556ec816bb891e1735b40233e43f5d31e707  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedVisibleMetadata.swift
3d2f33fa95c23c13085ca0c35a416d3c53cde9ef5ae5f607c41777faba811ea2  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Pills/ExteralessPillIntegration.swift
eddb7c1007b570df6477be92a71a8e4f327de6aeddffb4cce2e8fa485514c883  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Pills/ExteralessPillRuntime.swift
0d1f6c386ce81b53eeac3a22255810f427d4bc2d24405c35744cb3794f78eef7  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Pills/ExteralessPillSettingsAction.swift
a6f44f172955074d4992c765130a6ba07d557f497e63517671319cdfa1ed0a8e  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessLyricsSelectionController.swift
d5d96bb89d628b9d6b99f5af71eb63aa898182266ff9be23d79c512c7ec822b4  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessMiniPlayerView.swift
a75d7dd233c4a425e54d7fc8fb9c66f4ce537155cde3a89c0b2746110cb5ec6f  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerActions.swift
24c8b17b0b532fe075b5eaacf94e8ea21ad9af3036cd13142476dd893d308317  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerArtworkView.swift
3a298d75b561539d9626a853b6e1147121039dca4f833fdc7d164c8819f81bab  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerIntegration.swift
2ba48cbb18c610ec644f2061a1647da29a9bf6b80440fe1855fa206d6f670ef3  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerLyricsView.swift
b1942f17b11c07a1406cd392a6e3494b7e5c4c016e615ce6ce5c327277e02bf0  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerOcclusionPublisher.swift
0f11e95e8f1e4199cd74c0b0feff429a138b4b412599edcbd00a106651c0cd20  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerProgressView.swift
85a56b8d5a17bb9a116280fbf9a4973ef48e0eeff21ae24c438a0e784ad139ab  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerQueueController.swift
aad9f79e3f0b8da18a1b28f089c0876e939e38ca5a6f1834c3d18a02f836dd46  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSession.swift
e30184cf7d9f2d3c3236ca4937a42e2911d1e47b63dc8e94c6b670f46a216f55  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSurface.swift
d555489c1e0edfebe2ff663f20c46cb24b9e0ef0119fda60ee2b14c651249a70  telegram-ios/submodules/TelegramUI/Sources/OverlayAudioPlayerControllerNode.swift
dc02932ae314cf889b1fd5878a83825c566b558c4b20089bea795f629b9de790  telegram-ios/submodules/TelegramUI/Tests/FeedTests/FeedRemediationNativeTests.swift
6f5cdf00ea5f5bed60db48ad6f5b0c6aa87f06a0b091731eed88b1512ffa4d09  telegram-ios/submodules/TelegramUI/Tests/Player/PlayerLyricsAppearanceTests.swift
f0f185166bbd9d67c877374c05ea3e7d40b660483a4f746bfe3a6f3ad5d7d205  telegram-ios/submodules/TelegramUI/Tests/Player/PlayerOcclusionPublisherTests.swift
24db0b3fbda35f8a0f8750e1da141c3fa1e35310c631328e1716dc031642e140  third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/feed/FeedTimelineLoader.java
```

</details>
