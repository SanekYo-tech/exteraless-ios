# Следующие адресные пакеты реализации

**Назначить владельцев для 82 исходных IDs в 10 семействах.** Это
planning-срез по готовым receipts, не итоговое code review. Общий доменный ярлык
«Chat»/«Appearance» не считается молчаливым принятием всех оставшихся полей.
Указанные ниже новые владельцы — рекомендации координатору, не уже выданные задачи.

После возобновления прочитан актуальный `docs/wave-2/progress.md`: **65 input/action
IDs уже у Chat phase 2, ещё 1 favorites ID — у Tools**. Они сняты с первоначального
списка 148 новых адресных назначений. Player, Feed и Pills теперь имеют отдельных
исполнителей; их старое общее владение Chat не повторяется.

Machine gapset: [remaining-ownership.json](remaining-ownership.json).
Основные `client-features.json` / `sdk-surface.json` и чужие handoffs не менялись.

## Что показало сопоставление

| Срез | IDs |
|---|---:|
| Исходный инвентарь: настройки, state и templates | 567 |
| Упомянуты в пяти feature fragments | 249 |
| В JSON заявлены native functional callsites (`partial`/`implemented`) | 190 |
| Упомянуты, но без такого claim | 59 |
| Вообще без feature-fragment | 318 |
| Из этих 318 уже покрыты текущими адресными owner scopes | 236 |
| Нужна новая адресная резервация | **82** |

Итого **377 IDs без functional-callsite claim в JSON**. Три уже имеют handoff-only
claim: proxy names, auto-disabled proxy projection, per-plugin JSON storage.
Во время среза появился и прочитан **`ai-subwave-2.md`**, затем обновился сам AI
fragment: **15** старых pending/unsupported IDs теперь имеют source implementation
claims и выведены из активных receipt gaps. История этого обновления сохранена.
Остальные **374** —
без source implementation claim в прочитанных отчётах; это **не** число заведомо
отсутствующих реализаций. Phase 2 идёт параллельно, receipts могут отставать.
190 заявленных callsites также не означают 190 законченных/проверенных функций.

Из 318 IDs без feature-fragment **207 относятся прямо к NaConfig/Neko/OpenExtera**:
145 `nagram.*`, 61 `neko.*`, 1 `openextera.*`. Среди 82 ещё не назначенных записей —
77 settings, 3 templates и 2 state; исходные признаки: 76 static effect sites,
6 unresolved. Последняя группа требует source-disposition, а не
автоматического создания дополнительных UI.

Исходный Android digest:
`8ef4beb977e16fc92583851958c906cfcf2e2f3a0a9c635e35209d3ad0e25cf4`.
Хеши inventory/fragments/handoffs зафиксированы в JSON. Для каждого ID там задан
точный join к исходной записи, её category/state, всем Android consumers и UI
definitions. Representative anchors ниже взяты из этих pinned источников.

## P0 — новые назначения до следующей общей стыковки

Android-пути в таблицах относительны `TMessagesProj/src/main/`.
Полные списки **каждого** original ID находятся в JSON под соответствующим package ID.

| Пакет | IDs | Предлагаемый исполнитель | Оригинальные consumers | Критерий готовности |
|---|---:|---|---|---|
| **P-stickers-emoji** | **21** | Новый stickers/emoji; Tools — favorites boundary | `EmojiHelper.java:119`; `Emoji.java:95`; `StickerTime.java:31`; `PinnedElementsHelper.java:19` | Реальный выбор/источник/cache emoji packs, shapes/time/size/recents/picker и pinned reaction sets. Local favorites backup и `unlimitedFavedStickers` уже переданы Tools; состыковать, не дублировать. |
| **P-dialog-navigation** | **16** | Новый dialog/search/archive; Appearance сохраняет свои geometry/header seams | `DialogsSearchAdapter.java:1105`; `ChatObject.java:2640`; `GeneralHelper.java:148`; `ChatsHelper.java:506` | Search/archive/forum/next-chat/history/pins/badges имеют живые consumers. Данные и сортировка не считаются закрытыми по навигационному header. Отдельно принять уже заявленные pending `nagram.sortByUnread` / `neko.sortByUnread`. |

### P0, уже назначенные Chat phase 2 — сохранить адресные batches

| Пакет | IDs без feature receipt | Original anchors | Что вернуть |
|---|---:|---|---|
| **P-message-actions** | **46** | `ChatActivity.java:11345,5057`; `PhotoViewer.java:6187`; `AlertsCreator.java:2756` | Message/selection/media menus, admin shortcuts и delete-default policy с настоящими placement/default/action/cancel semantics. Linked UI-only delete bits сначала требуют source-disposition. |
| **P-composer-policy** | **19** | `SendMessagesHelper.java:2535`; `MediaDataController.java:7566`; `ScheduleTimeHelper.java:41`; `ChatActivityEnterView.java:3119` | Parser/Pangu/combine/schedule/preview/confirmations/mention/composer controls через реальные пути. Одна композиция с AI, privacy и TL, без потери rich draft/reply/media. |

Имена пакетов `P-*` сохранены как стабильные planning IDs. Назначение в JSON
определяет `assignment/current_owner`, не префикс. Координатор может разделить
эти 65 IDs по исполнителям, но они уже не считаются unowned.

Часто выпадающие точные семейства:

- `NaConfig.ActionBarButton*`, `chatMenuItem*`, `shortcuts*`,
  `mediaViewerMenuItem*`, `showCopy*`, `showAddTo*`, delete-defaults. **Chat admin
  shortcuts — не `UIApplicationShortcutItems` из Tools.** Deleted-specific menu
  entries уже направлены retention-agent, поэтому в этих 46 их нет.
- `combineMessage`, `disableMarkdown`, `markdownParser`, `enablePanguOnSending`,
  `defaultScheduledTime`, `sendCommentAfterForward`, `disableLinkPreviewByDefault`,
  `confirmAVMessage`, `askBeforeCall`, `showTextCreateMention`.
  `silentMessageByDefault` уже оставлен текущему Chat.
- Единственный отсутствующий из OpenExtera feature receipts family:
  **`openextera.downloadEmojiPacks`** вместе с `emojihelper.emojiPack` /
  `emoji_packs_v2`, а не «ещё один общий appearance switch».
- Для сортировки живой оригинал — `nagram.sortByUnread` (`SortByUnread`).
  `neko.sortByUnread` (`sort_by_unread`) и соседние старые sort flags нельзя
  автоматически привязать к тому же Core key.

## P1/P2 — ещё не принятые семейства

| Пакет | IDs | Предлагаемый исполнитель | Representative Android anchor | Критерий готовности |
|---|---:|---|---|---|
| **P-message-presentation** | 10 | Новый bubble/reply presentation либо явный Chat batch | `ActionBar/MessageDrawable.java:882`; `Components/ReplyMessageLine.java:247`; `Cells/ChatUnreadCell.java:59` | Tail/reply colors+emoji+background/unread capsule/share/time/spoilers и header controls имеют реальные gates/layout. Stock appearance не заменяет переключатель. |
| **P-local-identity** | 11 | Новый profile/localization либо отдельный Appearance batch | `MessagesController.java:6941`; `ContactsController.java:3078`; `LocaleController.java:456`; `PersianDate.java:186` | Local user/chat aliases, name order, Persian calendar/digits, ID/DC/about/common-groups/forward date воздействуют на нужные consumers без подмены server identity. |
| **P-local-premium** | 11 | Тот же local-presentation owner или отдельный | `LocalPremiumStatusHelper.kt:66`; `LocalPeerColorHelper.kt:85`; `ReplyMessageLine.java:399`; `EmojiAnimationsOverlay.java:430` | `localPremium`, восемь `premiumItem*`, local status/color data получают scoped native presentation и reset. Хранение флага не подтверждает серверное entitlement/result. |
| **P-network-resolver** | 3 | Network-policy; Tools/Privacy/TL согласуют scope | `DnsFactory.kt:74`; `ConnectionsManager.java:992,1263` | `dnsType/customDoH/useIPv6` управляют реальным заявленным resolver/network scope; proxy suspension и TL codec этого не делают. |
| **P-maps** | 3 | Map/location-policy либо явно разделить Tools/Appearance | `AndroidUtilities.java:2905`; `GoogleMapsProvider.java:595`; `ApplicationLoader.java:131` | Map preview/provider/coordinate correction: реальное native поведение или точный backend-specific предел. Отсутствие OSMDroid не закрывает всю user-facing функцию. |
| **P-cloud-sync** | 3 | Cloud-settings-sync либо явно принятый Tools batch | `CloudSettingsHelper.java:269,278,314` | `autoSync/includeApiKeys/localSyncedDate`: remote/account lifecycle, successful-sync state, restore/conflict и явная secret-policy. Локальный manual backup — другой контракт. |
| **P-client-api** | 3 | Coordinator client-identity + Build/network | `NekoXConfig.java:49`; `PasskeysController.java:191` | `customApi/customAppId/customAppHash` связаны с фактическим API environment/auth и понятной restart/account policy; Core schema не является этим эффектом. |
| **P-system-contacts** (P2) | 1 | Privacy-extras/coordinator, disposition | `ContactsController.java:427` | Только Android AccountManager-механизм `disableSystemAccount` можно закрыть как exact platform-only с доказательством; не смешивать с iOS contact sync/permission. |

Из 82 адресуемых IDs последний — точный platform disposition, а не предложение
написать новую UI-функцию. UI-only/legacy/state элементы в других пакетах также
не требуют автоматически отдельного экрана: сначала их исходный эффект.

## Уже назначенные scopes: не выдавать повторно

Это **236 IDs без feature fragment**, но с текущей резервацией. Они остаются
в gapset для адресных receipts, а не превращаются в unowned/complete.

| Owner / JSON-пакет | IDs без fragment | Что обязательно вернуть в continuation |
|---|---:|---|
| **retention / R-retention** | **27** | Archive capture/replay, exceptions, archived/chat/bot kinds, retained media, edit/deleted inline marks, quote/menu paths; также AyuDatabaseImport. Не путать с timestamp observations первой Privacy. |
| **privacy-extras / R-privacy-extras** | **15** | Regex/user/channel filtering, restrictions, Zalgo, hidden accounts/panic; source-specific scope и account isolation. |
| **appearance-phase2 / R-appearance** | **23** | Остальные header/nav/visual gates + drawer/icon/nav state. `customTitleUserName`/`folderNameAsTitle` и подобные UI-only поля получают disposition, не dummy rows. |
| **ai-phase2 / R-ai** | **3** | `appearance.hideAiEditor/hideIvSummary/hideMessageSummary` рядом с уже назначенной stock-AI/auto/article/mode/key работой. |
| **Chat phase 2 / P-message-actions + P-composer-policy** | **65** | Адресные batches выше: input/actions явно перечислены в новом progress handoff. |
| **Player / R-player** | **33** | Все style/mini/profile-music/lyrics поля из AppearanceConfig. Отдельный Player owner заменяет первую резервацию Chat; controls не покрывают selectors автоматически. |
| **Pills / R-pillstack** | **16** | Rate/weather providers, instance/cache/location state, плюс providers без ConfigItem и plugin-created pills со смежниками. |
| **Feed / R-feed** | **2** | `showFeedTab/showFeedUnreadCounter`, entry/read/badge boundary; не parked News. |
| **Chat / R-chat-media** | **16** | Silent send, decoder/HDR/quality/MP4/GIF/PiP/browser/media routes и migration aliases; exact volume-key limit отдельно. |
| **Tools / R-tools + R-telemetry-legacy** | **18** | Download/upload boost, files/subfolders/selection, audio/video capture/performance/RPC diagnostic fields; old Crashlytics migration; теперь также явно назначенный `unlimitedFavedStickers` / local backup. |
| **Coordinator + SDK / R-runtime** | **16** | Manager mode/pin/compact/engine/developer/safe-mode/watchdog receipts; Xposed markers — только excluded-mechanism disposition. |
| **Privacy / R-proxy-state** | **2** | Уже описанные names/effective-disabled projection перевести в original-ID receipts; новая UI не нужна. |

Кроме них, **59 уже перечисленных в fragments IDs без functional-callsite claim**
полностью перечислены в JSON (`reported_without_functional_callsite_claims`).
Это в основном текущие Appearance/AI phase-2, shared menu hunks и precise platform
dispositions. Их original IDs не теряются из-за `partial` или `unsupported`.

AI phase 2 уже описал adapters для stock interception и translation policies,
legacy service-hash import и настоящий persistent Bing TTL cache. Обновлённый
AI fragment теперь содержит эти 15 claims; они удалены из активного списка gaps.
`additional_handoff_claim_groups` хранит историю получения receipts и pending
shared wiring, а не дополнительные потерянные задачи.

## State / legacy / platform — критерии закрытия

- **State:** токен TTL/selection hash, proxy projection, timestamps, cached rates,
  materialized collections, migration markers и plugin storage можно закрывать
  как adaptation, если доказана исходная read/write/migration роль и реальный
  native заменитель. Например, fresh Bing session вместо persisted TTL и native
  proxy displayName вместо Android JSON ledger. Само отсутствие новой UI — не gap.
- **Legacy:** `appearance.centerTitle`, мигрированные reaction/reply/file-loader/
  rear-camera/ID flags не плодят независимые toggles. `ui-only`/`unresolved` от
  сканера сами по себе не доказательство отсутствия эффекта.
- **Exact platform-only:** Nothing Glyph, Android small notification icons/bubbles,
  UnifiedPush distributor fields, Android AccountManager toggle, consumable
  hardware-volume KeyEvent, Xposed/wakelock failure state и глобальный VPN detector.
  JSON фиксирует exact IDs. APNs delivery — **external prerequisite**, а не
  невозможность iOS notifications.
- **Не blanket platform-only:** square FAB/style adaptation, Monet style choice,
  predictive-back visual intensity, HDR/decoder/map-provider/DoH user-facing
  policy. Конкретный Android API может отсутствовать; остаточный переносимый
  контракт остаётся у исполнителя до явного disposition.

### Shim/API слой

В исходной матрице отдельно **308 ExteraConfig overload IDs**: 220 mapped aliases,
44 compat-storage и 44 utility/unresolved. Это не дополнительные клиентские фичи.
Tools дал classification-only receipts для 12 storage getter/setter IDs; SDK
описал общий class registry и settings bridge, но точного ExteraConfig mirror
receipt для каждого метода пока нет. Owner — SDK + соответствующий domain для
alias target. Нельзя принять generic `getClientSetting` за весь ExteraConfig или
выписать 139 новых UI-задач. Machine gapset задаёт точный selector по pinned API IDs.

## Три расхождения receipts, требующие reconciliation

1. **`nagram.showTextTranslate`**: теперь оба partial, но AI заявляет
   **`ai.showTextTranslate`**, Chat — **`chats.showTextTranslate`** для другого
   native меню. Координатору согласовать единый source-of-truth/linked alias для
   одного original ID, сохранив оба entry paths. Это конфликт receipts/keys,
   не проверенный кодовый дефект.
2. **`general.crashReports`**: Appearance pending, Tools implemented local MetricKit
   adaptation. Использовать Tools scope; он не заявляет Android auto-upload parity.
3. **`utils.predictiveBackIntensity`**: Appearance unsupported, Tools pending с
   передачей Appearance. Current owner — Appearance phase 2; нужен точный native
   navigation/disposition контракт, не reset или автоматическое closed.

Это наблюдения о документах для планирования, не найденные кодовые дефекты и не
перепроверка единичных UIKit методов.

## Смежные уже назначенные работы вне списка ConfigItem

- **Extra Services:** owner tasks, files/intents barriers, controller and
  NotificationCenter services. Python adapter readiness не является native effect.
- **TL phase 2:** actual mutation-capable request/update boundaries и rich media;
  schema/deep observational snapshots этого не закрывают.
- **Build/deps:** все packages и admission. Pillow/lxml/debugpy не назначать
  повторно из-за недостатка client feature IDs; package presence и actual OWN_GIL
  iOS behavior остаются разными gates.
- **Coordinator:** common insertions/composition/owner leases. Готовый CoreSettings
  gate — предоставленные пользователем 15 XCTest, run `43645893132` на `496d426`;
  baseline IPA `43635233046` на `68bb1adf`. Эти runs здесь не опрашивались и не
  использовались для повышения client parity.

## Как выдать задания

Сначала назначить два ещё свободных P0-пакета и подтвердить полный объём двух
уже назначенных Chat batches, затем объединить по способности исполнителей
profile/localization + local presentation, resolver + maps, cloud sync + client
identity. Во всех случаях scope подтверждает координатор; общие Swift insertion
места остаются у него. В receipt нужны original IDs, реальный эффект/адаптация,
native consumers, defaults/override/reset и meaningful behavior evidence.

JSON хранит точные ID-списки, приоритет, текущую резервацию, рекомендуемого owner,
исходные anchors, категории/dispositions и критерии готовности. Проверка этого
документа ограничена целостностью IDs/partition/input pins; это не review pass,
не Swift build, не UI/visual acceptance и не запуск плагинов/CI.

Финальная data-проверка: 82 + 236 = 318, ещё 59 reported gaps; все 377 ID/Android
anchor joins разрешаются, пять fragment hashes совпали, основной inventory hash
не изменился. `appearance-subwave.md` и `ai-subwave-2.md` продолжили меняться после
их выбранного read snapshot; его pins сохранены явно. Это ограниченный planning
срез, а не постоянно обновляемый статус параллельных реализаций.
