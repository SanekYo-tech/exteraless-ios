# Независимое ревью Feed / Player / PillStack

**Результат: 3 P1 и 7 P2 по исходникам.** Проверены Core-политики, native orchestration/renderers/controllers и соответствующие Java/Kotlin defaults/callsites. Наличие функций и число аргументов initializer не принимались за доказательство работающего поведения.

Ревью read-only; единственная запись reviewer — этот файл. Account/Network не создавались, провайдеры и плагины не запускались. Swift/XCTest, CI, сборка и визуальная проверка не выполнялись. Упомянутые ниже тесты — рекомендации, а не результаты. Старые 122 baseline-теста не доказывают этот cohort. Для UIKit/GIF/анимаций нет записанных кадров.

Прочитаны `telegram-ios/AGENTS.md`, `telegram-ios/CLAUDE.md`, `docs/wave-2-contract.md`, `docs/wave-2/feed.md`, `player.md`, `pills.md`. Основные выводы ниже основаны на коде, включая уже применённые shared integration hunks.

Короткие native пути `Feed/`, `Player/`, `Pills/`, `Chats/` ниже относятся к `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/`; `TelegramCore/` и `SSignalKit/` — к `telegram-ios/submodules/`. Java `app/...` и `org/...` — к `third_party/exteraless-android/TMessagesProj/src/main/java/`.

## Findings

### FPP-01 — P1: поздний Settings action возвращает ChatIntegration к старому аккаунту

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatIntegration.swift:60–64`, входы `:24–29`.

**Сценарий:** сохранить callback страницы Settings аккаунта A; переключить primary на B; вызвать старый Feed action с A, пока старый presenter/callback ещё жив.

**Доказательство:** Settings действительно передаёт сохранённый `self.context`, а не новый primary: `ExteralessClient/ExteralessSettingsController.swift:154–158`. В `open` выполняется `self.update(context: context)`. Это вызывает `clearContext()`, инвалидирует уже зарегистрированные экраны B и присваивает `self.context = A` (`ExteralessChatIntegration.swift:45–57`). Новый Feed создаётся до этой проверки, с `accountIsValid = true`; его account lifetime определяется только внешней инвалидизацией (`Chats/ExteralessChatTableController.swift:34,126–135`). Собственной подписки Feed на primary account нет; `Feed/ExteralessFeedScreen.swift:56–75,127–135` проверяет этот локальный флаг и общий foreground. Таким образом, старый action способен повторно допустить старый context после retirement. Реальная отправка read/network действий в ревью не проверялась.

Это отличается от уже корректно закрытого tab/menu-входа: `Feed/ExteralessFeedIntegration.swift:89–95` требует `self.context === context`. Modern Player также отдельно проверяет primary; это не защищает Feed и fallback table-player вход.

**Исправление:** принимать Settings actions только для текущего immutable context/generation; `open` не должен сам менять активный account domain. Использовать тот же checked factory для Settings и tab/menu, проверяя до создания экрана.

**Тест:** на injected context/factory spies выполнить A → B → старый callback A; ноль новых factories/subscriptions/effects для A, экраны B не инвалидированы. Отдельно проверить поздний action после `clearContext()`.

### FPP-02 — P1: Feed использует старые peer copy-protection flags при render/copy/share

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedTimeline.swift:301–318`; связанные проверки — `Feed/ExteralessFeedActions.swift:179–198,216–224`.

**Сценарий:** загрузить пост, затем включить у канала copy protection без изменения самого поста; открыть действия сохранённого поста и Copy formatted text / gallery / Share.

**Доказательство:** retained window подписан только на `EngineData.Item.Messages.Messages` (`ExteralessFeedTimeline.swift:42–43`). Его `MutableMessagesView.replay` отслеживает history operations и `updatedMedia`, но не `updatedPeers`: `telegram-ios/submodules/Postbox/Sources/MessagesView.swift:18–60`. Channel registry может получить новый peer, однако `configure` запрашивает head только при изменении top ID/version (`ExteralessFeedTimeline.swift:113–118`), а сохранённый `EngineMessage.peers` не заменяет. Кроме того, `EngineMessage.==` не сравнивает `peers`/associated messages (`TelegramCore/Sources/TelegramEngine/Messages/Message.swift:190–242`), и cell invalidation использует это же равенство (`Feed/ExteralessFeedMessageCell.swift:125–141`).

`feedCurrentMessage` возвращает именно retained copy (`ExteralessFeedScreen.swift:550–553`). `isCopyProtected()` читает channel flags из этой копии (`TelegramCore/Sources/Utils/MessageUtils.swift:538–547`). Следовательно, повторная проверка перед Copy/Share не является повторной проверкой актуального peer. Gallery получает тот же stale `copyProtected` (`ExteralessFeedActions.swift:70–88`). Android, например, проверяет актуальный controller peer отдельно от message flag: `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/player/PlayerActions.java:55–58`.

**Исправление:** включить актуальные peer/restriction данные в retained render projection и invalidation key. Перед экспортом получить свежие message + peer-policy данные через Engine; не опираться на shallow equality как на completeness metadata.

**Тест:** immutable message ID/version/media при смене только `TelegramChannel.flags.copyProtectionEnabled`; уже показанный пост и открываемая gallery становятся protected, clipboard/share не допускаются. Проверить также обратный переход и изменение associated reply без изменения version основного поста.

### FPP-03 — P1: плавающий mini-player не вычитается из Feed receipt viewport

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedScreen.swift:488–495,509–520`.

**Сценарий:** включить Feed tab и проигрывание music с default modern mini-player; расположить небольшой непрочитанный пост под нижней панелью mini-player. Аналогичный случай — высокий пост или альбом, закрытый частью панели.

**Доказательство:** mini монтируется через **root** `presentOverlay(..., blockInteraction: false)` и виден на main tabs (`Player/ExteralessPlayerIntegration.swift:97–109`). Его 64/52pt frame вычисляется поверх содержимого над tab bar или под navigation bar (`:149–174`; `Player/ExteralessMiniPlayerView.swift:30`). Он не сообщает занимаемую область в layout текущего Feed. Feed viewport вычитает только собственные `tableView.contentInset`; obscuration gate проверяет только собственные presented/presentationContext controllers. Root overlay туда не входит. `FeedPresentationPolicy.admitsReceipt` поэтому получает завышенную видимую высоту; все IDs альбома затем передаются в `feedReads.seen`.

В оригинале этот стык реализован явно: `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/feed/ui/FeedActivity.java:225–246,254–265` включает `miniPlayerPadding` в системные/list insets. Privacy network gates не отменяют ошибочное локальное чтение невидимого поста.

**Исправление:** общий account-scoped источник occlusion/insets для root mini и Feed, учитывающий top/bottom, compact, keyboard и side tabs; либо подавлять receipts при реальном перекрытии. Считать видимость bubble/album после вычитания overlay geometry.

**Тест:** deterministic layout fixture с synthetic rectangles для поста под 64/52pt mini, tall post и album; ноль admitted receipts до открытия содержимого. После native build — кадры phone/Duo, top/bottom mini и первых/последних строк. Здесь это source-level finding, не наблюдение по кадрам.

### FPP-04 — P2: one-shot history page прекращает native poll/webpage metadata lifecycle

**Место:** `telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/ExteralessFeedHistory.swift:28–38`; retained subscription — `Feed/ExteralessFeedTimeline.swift:42–43,301–332`.

**Сценарий:** оставить открытый poll в уже загруженном Feed; внешний голос/закрытие опроса требует следующего native poll refresh, но других history updates нет. Для pending webpage — resolution завершается позднее первой page emission.

**Доказательство:** `take(1)` освобождает `aroundMessageHistoryViewForLocation` после первой подходящей страницы, а timeline также dispose-ит page request (`ExteralessFeedTimeline.swift:255–257`). Именно lifetime wrapped history владеет native poll/pending-webpage подписками: `TelegramCore/Sources/State/AccountViewTracker.swift:1981–2006`; disposal снимает обе. `updatePolls` после удаления последнего view отменяет producer (`:515–537`); его реальные 30s/deadline refresh находятся в `:573–596`. Оставшийся `MessagesView` лишь читает Postbox. Feed's единственный периодический metadata refresh заказывает reactions (`ExteralessFeedScreen.swift:528–542`), не polls/webpage resolution.

Оригинальный native ChatActivity feed-host добавляет видимые polls в очередь (`third_party/exteraless-android/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java:17743–17745,17830–17831`); эта очередь делает `messages.getPollResults` и применяется к реальным message IDs через feed normalizer (`org/telegram/messenger/MessagesController.java:10932–10981`, `app/exteraless/feed/FeedRequestNormalizer.java:153–169,182–199`). Собственное голосование Feed работает, но не заменяет lifecycle обновления чужих голосов.

**Исправление:** сохранить один bounded native metadata lease для реально видимых retained messages, отдельно от completion page requests; использовать existing tracker/coalescing, с отменой при скрытии/account retirement. Не удерживать все history views аккаунта ради metadata.

**Тест:** finite injected page + delayed poll/webpage producers: page завершилась, metadata lease ещё жив для видимого поста; после hide/retirement отменён. Poll update должен менять ровно исходный composite ID, без нового pagination request.

### FPP-05 — P2: Feed создаёт Pill-header после синхронной foreground emission

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedScreen.swift:127–138`.

**Сценарий:** обычное открытие Feed в уже активном приложении, затем выход и повторное открытие.

**Доказательство:** подписка на foreground/active стоит **до** `self.pillHeader = ExteralessPillHeaderView(...)`. Cached `Promise.get()` эмитит синхронно (`SSignalKit/SwiftSignalKit/Source/Promise.swift:51–67,119–129`); `combineLatest` с default nil queue также немедленно передаёт пару (`SSignalKit/SwiftSignalKit/Source/Signal_Combine.swift:30–42,91–94`). `deliverOnMainQueue` не откладывает вызов на main (`Signal_Dispatch.swift:3–8,23–24`, `Queue.swift:60–65`). Поэтому `startFeed()` вызывает `pillHeader?.start()` (`ExteralessFeedScreen.swift:171–176`) для nil или предыдущего header, после чего `viewWillAppear` заменяет его новым. Новый header имеет `running = false`; initializer и `didMoveToWindow` его не запускают, а `reconcileSubscription` требует running (`Chats/ExteralessPillStack.swift:32,128,164–167`). Он остаётся с Waiting for reading, без обновлений и работающих tap/swipe, до следующего foreground edge.

**Исправление:** создать/подключить header до подписки; предпочтительно сохранять один экземпляр и явно синхронизировать его visible lifecycle после установки.

**Тест:** cached `.single(true)` foreground/active на main, без асинхронной задержки; ровно один start текущего header на каждом appearance, stop на disappearance, старт не получает удалённый экземпляр.

### FPP-06 — P2: Save/Remove music не обновляет like-state при холодном profile-list cache

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSession.swift:312–337`.

**Сценарий:** `savedMusicIds` уже известны, но My Profile Music/list ещё не открывался. В modern player обычного chat track нажать Save to My Profile; либо удалить ранее сохранённый track при том же холодном list cache.

**Доказательство:** session разрешает действие при non-nil `savedIds` и определяет сердце исключительно по этому набору (`:138–145,170–173`). Для chat track `ownList == nil`, поэтому вызван direct Engine helper. В `TelegramCore/Sources/TelegramEngine/Peers/SavedMusic.swift` обновление preferences с `SavedMusicIdsList` вложено в условие наличия **другого**, `CachedProfileSavedMusic`, cache (`:128–186,208–234`). RPC `account.saveMusic` расположен вне условия (`:187–204,235–246`) и действительно выполняется; это не fake operation. Однако completion session лишь снимает pending и вызывает render. Без profile-list cache сердце/следующее действие остаются прежними до обновления IDs; managed refresh имеет интервал 30 минут (`SavedMusic.swift:91–124`).

Android после успешного ответа обновляет saved IDs независимо от наличия UserFull/profile cache (`third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/player/PlayerActions.java:303–320`). Это integration defect нового consumer, опирающегося на existing native helper с таким предусловием; helper сам не был изменён этой подволной.

**Исправление:** обновлять authoritative saved IDs независимо от наличия cached profile page; согласовать success/failure/revalidation с native operation. Одного оптимистического изменения UIButton недостаточно.

**Тест:** memory transaction fixture с IDs preference и отсутствующим profile-list cache, canned save/remove completion; итоговый observed набор и следующее действие должны измениться. Отдельный negative test для failed add, без реального Account/network.

### FPP-07 — P2: multi-timestamp LRC обходит общий лимит текста после expansion

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/PlayerLyrics.swift:108–129`.

**Сценарий/малый fixture:** одна строка из 64 валидных timestamps `[00:00]...[01:03]`, затем 4097 ASCII `x`. Это **4545 входных bytes**, ниже лимитов input/line; parser создаёт 64 строки, суммарно **262208 text bytes**, уже выше `textBytes = 262144`. Проверена только эта арифметика коротким Python fixture; Swift не запускался, большой/OOM fixture не создавался.

**Доказательство:** после expansion проверяются количество строк/word cues, но не сумма `line.text.utf8.count`. `parse` возвращает документ без `isValid`; `PlayerLyricsClient.candidate` принимает его (`PlayerLyricsClient.swift:241–250`). Cache trimming сериализует весь expanded entry/candidates **до** проверки размера (`:127–133,323–338`). При допустимом input около 256KiB размер сериализованного текста одного candidate может достигать примерно 15MiB; повторение в candidate list добавляет ещё allocations. HTTP streaming cap не ограничивает эту вторую стадию. Общий validator (`PlayerLyrics.swift:196–210`) обнаружил бы превышение, но online parse path его не использует.

Multiple timestamps — реальная семантика оригинала (`third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/player/Lyrics.java:91–107`), поэтому удаление поддержки не является исправлением.

**Исправление:** учитывать logical expanded text/word UTF-8 budget до добавления строк; применять согласованный общий document/candidate budget до cache encoding. Ограничивать не только исходный HTTP body.

**Тест:** приведённый 4545-byte fixture должен детерминированно вернуть size error; соседний допустимый boundary сохраняет multiple timestamps и порядок. Не требуется выделять мегабайтные/неограниченные строки.

### FPP-08 — P2: paused inline lyrics сохраняют старые цвета после day/dark смены

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSurface.swift:213–214`; `Player/ExteralessPlayerLyricsView.swift:108–128`.

**Сценарий:** paused music, уже показанные inline/plain lyrics, затем переключение светлой/тёмной Telegram theme или player artwork/theme colors без смены документа/строки.

**Доказательство:** surface передаёт в `lyrics.update` старую `palette`, и только затем вычисляет новую в `applyPalette`. Даже следующий update с новым palette не переконфигурирует существующие cells при прежних lyrics/track/index: reload зависит от document/track либо activeIndex. Единственная ветка обновления существующей cell относится к текущей karaoke-строке. Остальные attributed foreground colors остаются прежними, хотя background уже новый. Для paused inline playback это сохраняется до дальнейшего изменения lyric index/document. Source comparison показывает несогласованное состояние; фактический контраст/кадры здесь не измерялись.

**Исправление:** вычислять новую palette до передачи дочерним views; инвалидировать оформление всех visible lyric cells при palette/font change, сохраняя scroll position и track/seek lease.

**Тест:** native view fixture с неизменными document/position: light → dark → light должен менять attributed colors visible cells без seek/play и reload документа. Затем записанные кадры paused inline/plain/karaoke по AGENTS.

### FPP-09 — P2: нет независимого Settings-входа в Status Pills после пустого layout

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Pills/ExteralessPillIntegration.swift:7–13` и `Chats/ExteralessChatIntegration.swift:23–36`.

**Сценарий:** через Status Pills скрыть последние Cache/Proxy, выйти из экрана, затем попытаться снова открыть управление pills из Settings.

**Доказательство:** PillIntegration устанавливает только header factory; комментарий о сохранённом ChatIntegration action не соответствует коду. Среди registered Chat actions есть Feed, Player, Bookmarks и tracking filter; Pill action отсутствует. Поиск всех actual `ExteralessPillSettingsController` constructors в TelegramUI находит только header error/long-press routes. Пустой layout скрывает header и имеет высоту 0, поэтому этих routes больше нет. Generic Settings показывает raw layout/data editors; восстановление возможно ручным редактированием/сбросом raw keys, но native экран управления из Settings недоступен.

В оригинале есть независимый вход независимо от layout: `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/settings/OpenExteraAppearanceActivity.java:551–553`. Это **не** прежний конфликт четырёх layout definitions: они уже восстановлены в `ChatFeatures.swift:7–11` и здесь не предъявляются повторно.

**Исправление:** зарегистрировать отдельный account-checked Status Pills action в сохраняемой integration, доступный при empty/invalid/dormant layout.

**Тест:** hide last pill → выйти → открыть Settings action → включить pill через native экран. Проверить stale-account action по FPP-01.

### FPP-10 — P2: 4Hz admission в стабильном Pill registry теряет terminal DTO

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/PillPluginRegistry.swift:99–103,122–130`.

**Сценарий:** небольшой native `PillPluginProvider` в `start` публикует `.loading`, затем cached `.ready` синхронно или через 10ms. Следующего изменения данных нет.

**Доказательство:** первая модель проходит `delivery.admit()`, вторая отбрасывается из-за `< 0.25`. Нет сохранения latest model, trailing delivery/timer или исключения для terminal phases. В header остаётся Loading; аналогично быстрый failure не заканчивает loading. В `PillPluginRegistryTests.swift` есть одиночные valid/invalid publications и unload, но нет последовательности loading → ready/failed. Дефект существует в **стабильном Core registry API** и воспроизводится native DTO provider; вывод не зависит от недописанного `PluginPillBridgeExtension` или Python callback implementation.

**Исправление:** bounded latest-value coalescing с trailing delivery, либо гарантированное завершение loading/terminal state при сохранении rate bound. Retired owner/account должен отменять pending delivery.

**Тест:** finite in-process native provider, две публикации в одном start: не позднее 250ms виден последний terminal DTO; unload/cancel до trailing delivery не публикует его. Не исполнять внешний plugin corpus.

## Что дополнительно проверено и где остаётся граница доказательств

- **Pagination / identity:** actual source идёт через native root/archive chat-list pages и channel history, не parked News API. Cursor учитывает filtered non-channel/service rows; 4 requests / 10s round, retryable failures, source frontier и whole-album composite IDs присутствуют. Android negative channel uid применяется только для ordering (`ExteralessFeedTimeline.position`), native IDs не подменяются. Отсутствие потерь на всех real hole/album boundaries без native fixtures не подтверждено.
- **Membership / retention:** чтение known/excluded больше не обрезается prefix 2000; native enumeration не заканчивается на 1000. Проверка 20000 membership IDs/real native pagination не запускалась. Retention составляет **500 + до 29 сообщений на каждый source**, а не 500 на аккаунт (`FeedPresentationPolicy.swift:45–60`); held `EngineMessage`/media references и window observation масштабируются с числом channels. Большая memory/load пригодность этой схемы остаётся неподтверждённой. Membership writer делает несколько `set`, а не один `applyPublic`; атомарность compound changes этим ревью не подтверждается.
- **Reads:** peer/namespace frontiers и local native apply/mark-all реально подключены (`ExteralessFeedReadState.swift:119–160`). Прямого feed read RPC/exemption не обнаружено; policy отправки остаётся в существующем native privacy boundary. FPP-03 относится к admission видимости до этого boundary.
- **Native cells:** production path строит `ChatMessageItemImpl`, `.message/.group` с исходными messages и native item nodes. Проверены media/source/copy/share/selection/reaction/vote callbacks, height/reuse leases и visibility. Advanced/paid reaction, bot/web-app, poll-result и advanced selected-text переходы в исходный пост документированы в handoff; само наличие 131 labels не считается функциональным покрытием. Подготовленный smoke с PNG не является доказательством GIF/video lifecycle или native visual pass.
- **Player:** сверены 33 Appearance defaults с `AppearanceConfig.kt:256–365,392–399` и effects в `PlayerStyle`/native surfaces; cover/order/mode/action/mini настройки имеют consumers. `md3Player` в settings-owned controller выбирается при создании view, live replacement реализован в native Overlay node. Scrub/lyrics/menu/swipe используют real item/resource/duration identity; pause/reopen не добавляет play. Native queue/rich references и возвращённый cloud file upload подключены. Replay/seek, 10/5-minute remembered position thresholds, stored base rate и six-speed cycle прослежены в actual MediaManager/SharedMediaPlayer; runtime/audio/codec proof не получен.
- **Lyrics HTTP:** exact/search/fallback endpoints/parameters, LRCMUX milliseconds и >5s rejection сверены с `OnlineLyrics.java`. Transport имеет task cancellation, ephemeral storage, 1MiB body cap, 20s lookup budget и bounded retries; нет credential setting/произвольного endpoint. Эти source bounds не устраняют FPP-07. Offline overrides/cache/query matching изучены, HTTP fixtures не запускались.
- **Pill 1–15:** rates используют reciprocal USD/unit и cross division; GRAM→TON, XAU/troy ounce и older dependency timestamp сохранены. AUTO использует phone-country текущего context, включая 76/77→KZ и прочие 7→RU, затем supported currency/USD fallback. Weather использует реально активный Android Telegram bot; Open-Meteo — явно выбранный дополнительный источник. TTL/cache timestamps действительно Unix ms. Pair edits/selection/migration используют atomic public patches/CAS, raw quote cache не хранит currency-labelled UI старой пары.
- **Pill lifecycle / metrics:** осмотрены producer coalescing, last-subscriber cancel, account lease retirement, bounded parsers/HTTP 429, first delta/reset identity. RAM обозначен как app footprint + free pages; CPU — process % одной core; network — account MTProto bytes. Это явные native ограничения, не Android whole-device metrics. Low Power/thermal interval выбирается при resume (`ExteralessPillRuntime.swift:201–208`); live смена этих состояний без lifecycle restart не перепланирует timer. Физические measurements не выполнялись.
- **RTT:** отсутствие passive RTT у конкретного engine не объявляется дефектом. Текущий код читает optional `ExteralessPillPassivePingSource`, отбрасывает stale sample и иначе явно показывает readiness/activity age, не выдуманный ping. Engine-specific forwarding/точность не проверены измерениями.
- **Registry / SDK граница:** stable Swift registry выполняет start/actions/provider cancellation на utility worker, rendering получает DTO. Незавершённые `PluginPill*` provider/bridge internals и owned-GIL end-to-end не рецензировались по заданию. Во время ревью в header уже появился renewal одинакового descriptor после registry invalidation; прежний вариант с потерей replacement subscription **не** включён в findings.
- **Shared assembly:** применённые `ExteralessClientRuntime`, AccountContext entries, Feed Contacts replacement/badge, appearance recomposition, ChatList Pill panel/visibility и downward Gallery PiP hook проверены по actual source/diff. Старая формулировка «unapplied» в handoff не использована как finding. BUILD наличие test target/source graph не доказывает native compile или выполнение новых suites.

## Source snapshot

Рабочее дерево менялось другими сессиями во время ревью. Начальный HEAD: `b1424e109ce1562ffc2a74e428e7577b0432dbd0`. Зафиксированный полный scope snapshot на `2026-11-15T08:27:39Z`: HEAD `33ff6dce8751f30ec30b3a2cdee970fbec36e0ec`, затем наблюдался внешний commit `2a03061d` (другие Core domains). Reviewer commit не делал. Ключевые finding sites перечитаны после этого; Pill header registry-renewal delta учтён выше.

Сравнение tracked source выполнено с исходной базой волны `68bb1adf6898f6172cd4315b5d32a446fdb29550`, не с отчётом CI. Scope: Core Feed/Player/Pill policies + referenced Chat/settings helpers; все native Feed/Player и non-`PluginPill*` Pill files; shared seams и native helpers; domain fixture sources; Java feed/player/pillstack/nowplaying trees и соответствующие Kotlin/оригинальные callsites.

- Полный scope: **168 files = 122 tracked + 46 untracked**. Untracked native source прочитан как полный файл; обычный `git diff` его не покрывает.
- SHA-256 canonical scope manifest (`sha256 + "  " + relative POSIX path + "\n"`, пути отсортированы, хэшируются исходные bytes): `926dfeb018d5e81f9abfed2df6bc0461e50564d3a94c494033d2da6029d91f02`.
- Tracked binary diff: `git -c core.autocrlf=false diff --no-ext-diff --no-textconv --binary <base> -- <scope paths>`; **470274 bytes**, SHA-256 `63b80f305d36afd5364fadfb8fc0f862ae940c238f67e8cf5f57bba273563da4`.
- Эти digests обозначают source snapshot, не passing test/build. Ни последующие чужие commits, ни новый Core CI автоматически не закрывают findings.

### Финальный manifest finding evidence

`2026-11-15T08:34:56Z`, HEAD `2a03061d20921e2e87d6c674d2d56810674bdd34`: **61 files, 43 tracked + 18 untracked**. Этот перечень включает все явно процитированные finding files и стабильные Core Feed/Player/Pill policies. Он фиксирует actual working-tree bytes, включая некоммиченный native source и обновлённый Pill registry-renewal header.

- Canonical manifest SHA-256: `54eb72388ef29a7525d8fc82ecb5f8de02069b5fca6244f9bf93396cb55a8b16`.
- Exact tracked diff к той же базе, с путями из manifest: **191868 bytes**, SHA-256 `9a3995a5288c86fe802c7b546af947add78a8d2e8f45b681e6011d33df47f3b9`.
- Hash-format: два пробела между 64 hex chars и POSIX path; LF после каждой строки. Для проверки содержимого хэшировать `read_bytes()`, без нормализации CRLF. Untracked files подтверждаются полным file hash, а не пустым tracked diff.

<details>
<summary>SHA-256 и точные пути evidence</summary>

```text
13282dbd39cb247954cdd1b8345cc4b73136eeccd0341c6f14af57fadbb8a5d5  swift/ExteralessCore/Sources/ExteralessCore/ChatFeatures.swift
1700af181c817769d5907fd2f01cdee032d46961148e41bf6a87e8d863fbd2d1  swift/ExteralessCore/Sources/ExteralessCore/ChatFeedPolicy.swift
ba568a7eebc70a03b9aa50e234b326f70805c639902d07ae0a6ffe9534df3bc3  swift/ExteralessCore/Sources/ExteralessCore/CorePillFeatures.swift
e094f9f8bfa9a0f96be0bd852d27f3b178a3283b4c9f92ebb8b730b9d62a7543  swift/ExteralessCore/Sources/ExteralessCore/FeedFeatures.swift
6bef168e30f31645219a48161d884ca4f5564fc74c74f3cb8f9edff09f95e407  swift/ExteralessCore/Sources/ExteralessCore/FeedPresentationPolicy.swift
7f3899a41393799bc81c661b10dd2749a9c493aaa33a16b2a8af7f13a72cc255  swift/ExteralessCore/Sources/ExteralessCore/FeedUnreadTracker.swift
d12c30beeb7d1736f89847a68f2250482c1f4439db87c665c99ce25dbf482c1d  swift/ExteralessCore/Sources/ExteralessCore/PillCurrencies.swift
f54cc9ead81ebb75177afad7127142a05ad920e84e873d01f5cd1ac150df7aaf  swift/ExteralessCore/Sources/ExteralessCore/PillHTTPTransport.swift
e620f660422d31a8f7e50f7180f6e223ed87ff3a038572dd19d8738f618a12b5  swift/ExteralessCore/Sources/ExteralessCore/PillMetricPolicy.swift
7ae6ba4888975bb6a271c537d8d2dea9badade9d771d43b67a3207a0517c685b  swift/ExteralessCore/Sources/ExteralessCore/PillModel.swift
e742f360395652c0800fd262f6e884a4fbc702222e9de7a68f997baa260823f4  swift/ExteralessCore/Sources/ExteralessCore/PillPluginRegistry.swift
7d13db627d26af4bf85608b3a1a9a55a888f8270053105f05eb5b62cb195c2fa  swift/ExteralessCore/Sources/ExteralessCore/PillRateProvider.swift
4fe3be6657a7c0414db90f8035d7b99dd14305677e7e1020b3700bf0aa8b0171  swift/ExteralessCore/Sources/ExteralessCore/PillRegistry.swift
652224510607541c12d74aa8df86fe3979876b1df6202ac6108d4b4ed9833830  swift/ExteralessCore/Sources/ExteralessCore/PillRequestPool.swift
66efa6bb49c4ea9e2eef28eb671f831ee4f44d4e41f515407a8cd8551fed0583  swift/ExteralessCore/Sources/ExteralessCore/PillSettings.swift
5c73fa2368519388bdf8903bd5c6916c1baac73f78df0b3ebea075671fee3b6e  swift/ExteralessCore/Sources/ExteralessCore/PillWeatherPolicy.swift
e981e0f26110494d8e18769fe6b9a91471d6b22d5ffed56bc48cb7a6b16c5133  swift/ExteralessCore/Sources/ExteralessCore/PillWeatherProvider.swift
040afe1b53cf42a77b55aa5c88e4f3f8f044d913da04f5a6e84c656dd3d4be39  swift/ExteralessCore/Sources/ExteralessCore/PlayerFeatures.swift
15d00355cc6e4b799092c33fce781607c823935c5be9cd0d5b7623d0c5854b44  swift/ExteralessCore/Sources/ExteralessCore/PlayerLyrics.swift
d52fe21a5ff6ad6937002234b93d7484f91c842988a2f71722ab826f91c75c3f  swift/ExteralessCore/Sources/ExteralessCore/PlayerLyricsClient.swift
aff2a340848e0a419e17bef990c22e78aa6c3d8c937244361f943d68ffcd1ec2  swift/ExteralessCore/Sources/ExteralessCore/PlayerLyricsHTTP.swift
5f68c2b8b1bfd35a67eb685bb60fccf6ca6832a6574d527ad8cdc6b9b51c18f6  swift/ExteralessCore/Sources/ExteralessCore/PlayerMiniPresentation.swift
cabe1c1111978f40b3fc04f62e4785d41bda15cc79933bbb1d3b0323b6a424d0  swift/ExteralessCore/Sources/ExteralessCore/PlayerStylePolicy.swift
61369eba9c35b71f9a3ef39f6252c3e82e156838ce9cf746b396ad1a5a676742  swift/ExteralessCore/Tests/ExteralessCoreTests/PillPluginRegistryTests.swift
60a53539152b23052f82441b03cc4743889839c6274c6d7c7f993e16c5df7b40  telegram-ios/submodules/Postbox/Sources/MessagesView.swift
e691338e89b656e5d272f70e6c97f5d07990d57badfd7e1d7e1dae86f9a3693a  telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Promise.swift
ac7db4cdf6b9728f0936bf35998cee3f6b8d7824abbc07e71e679e068315b31b  telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Queue.swift
994f52d6459d2251a2880f7d0827f853e74c4bd20ab7896386f4152215723450  telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Signal_Combine.swift
136f325211fca4cf75d193a3f273d092a32ed9304c3442095b707c6b1639fc38  telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Signal_Dispatch.swift
3d1bbcb7016def3162ce821885690a6667ae357f639c8c67171c768bad87edc7  telegram-ios/submodules/TelegramCore/Sources/State/AccountViewTracker.swift
44571e97ba408da2299303e9d627d4b57bc7755c901f853d45d542a3d468e161  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Data/MessagesData.swift
9912e328c8162358e3babed4e89454b6927d24ce69542fba0ceceec496c47f3b  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/ExteralessFeedHistory.swift
ffddee32acbc80607fbf5c96ab339a8c600cae57e055337cab8d672c734ff4a7  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/Message.swift
578a2a38885d9bb2082b3d2cca64e9aff88f4dba163a8f16e3c13e95a3f22c03  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/SavedMusic.swift
00c0dc1c4d82a1c6368bc02ed95acf36cbc5980c98ee7f3d04ed326eff3b17cc  telegram-ios/submodules/TelegramCore/Sources/Utils/MessageUtils.swift
e732a316d7d8497ec60f0bb963008b0e11f5dbfdf11d81543724854bca120dfc  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatIntegration.swift
738d48806e2bce59603c6c4384d5ddd98105166cf747f650668d861e519596d4  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatTableController.swift
dbbf98be8d14cf57c048268ac1de8813d865615b838a306c06ef4f7697cf32b1  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessPillStack.swift
57884dd0a9fad0d8228a3e5d6e9a17c43b232a9ebc95488caabe8b5851c8cdeb  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift
2dff351743b1e2a959f9e861f300b92e2b722b25925a8c37c38310b4d57faecd  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedActions.swift
48f54e3c6223b6f15c6ae2c51fcd3fa7f83418edd861e64c86855bd369d21dac  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedIntegration.swift
006abaf96bd4334c82338c7e2ef4bb25a5cf5acd4eb07f1c508054de9bb8f80c  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedMessageCell.swift
92133cddb3304e8df14582476886eb9e78a34021211515abc95ffefa8f9673f5  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedReadState.swift
8fd687f2a5ed22f13c57eab3ce751565a4d988c3df0222d39196e75f2822fed0  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedScreen.swift
08117b3176f98761657a880adfdeebb755372539fbad4313c94664e6fd6ef90a  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedTimeline.swift
d38707559e88aabd635fb24b94ab4bdee4e7aae805e1e07c2429e14c366f8a54  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Pills/ExteralessPillIntegration.swift
eddb7c1007b570df6477be92a71a8e4f327de6aeddffb4cce2e8fa485514c883  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Pills/ExteralessPillRuntime.swift
6c7f0c776a80704585573312f511269d0dd5d9184cf0357bc2a2d8e83fb538a9  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessMiniPlayerView.swift
526d29d0562a7946afc48835be16f0e1fc3d013b5573dccd3e2e149ebc8a8789  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerIntegration.swift
df22468f90295dc175f5c273d05353df0aaeb184d917a7f6b20ccf152f983158  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerLyricsView.swift
d50ca09f06033f7f720832a69a4a1eec201fe6359dbb4f0db65deb8a743534d4  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSession.swift
26d3e149d30b2aab6009ee6a1953e4b18eba0fb42f7fb858ea11a85e62715a7b  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerSurface.swift
d8a9d139bd07cab4cb22860237cbcff8ee2b53fc708fa483d090f4949748f14f  third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/feed/FeedRequestNormalizer.java
df4aebe5cfda582096f18b27ac7791f041a609a88b55818dfff7e1b01b0cd6ce  third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/feed/ui/FeedActivity.java
553e9f183c282d6063bc9ecfcdffa7b0b06ccbdf824d83cfcc92520c4d0e9972  third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/player/Lyrics.java
d925a292aaaf739895e757783239be4907d01ec86aebf81e7b5c362363d45453  third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/player/OnlineLyrics.java
86334ed4f2c4a4c989d175f1ce2c8d79d4368ff7e0c3b1cc947a67b177103cd5  third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/player/PlayerActions.java
55b6a4b71a392be705862f81b7361e2d42c261336b2c443f4b0e25da8231406a  third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/settings/OpenExteraAppearanceActivity.java
10495b6e82eb4bd5d59f14b9dbc4b5f6dbda185e972985608bd345eb572367d3  third_party/exteraless-android/TMessagesProj/src/main/java/org/telegram/messenger/MessagesController.java
d37ab6d4b385acd1c7e52ec9114a54a3ca40786e86b49f03d684730382e672ad  third_party/exteraless-android/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java
8092bb53568040d010df1ec6fa1f269f666c4cb1b072cc642cce7bfee32ee187  third_party/exteraless-android/TMessagesProj/src/main/kotlin/app/exteraless/appearance/AppearanceConfig.kt
```

</details>
