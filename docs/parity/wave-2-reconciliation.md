# Wave 2 — final source-only join

**567/567 Original IDs имеют source receipt; receipt gaps: 0. Verified/ported promotions: 0.**

[Точная карта](wave-2-reconciliation.json) · [Основной inventory](client-features.json) · [SDK925](sdk-surface.json) · [Final cohort/pins](final-source-join.json) · [Исторический 93a1badc](cohorts/93a1badc.json)

567 features, 30 modules, 925 SDK symbols, 308 Config overloads, 20 Pill settings и 15 отдельных Pill types сохранены.
`implemented` — claim автора о source, не native/runtime/visual pass. Старые 56 gaps теперь представлены все.

## Snapshot

- HEAD при join: `16c23a99449eba704885a83982e35a079054f815`; исходный request pin — `fac6cf26be9f622dc1c5eec8cf7cf165fff6200c`.
- `16c23a99` публикует уже прочитанные reports и workflow: **production source delta относительно fac6cf26 — 0**. Request/source и поздняя публикация документов различены.
- SDK Config: **276 implemented / 0 blocked / 32 unsupported**, 308 exact IDs, **59 raw source pins / 10 input receipts**, 508 bindings, 21 root groups. Receipt SHA-256 `6624ada22f523f8028f2029b3dba7ac69285349930844d75f172dd48a6410367`.
- Canonical `sdk-config-input-v1` сохранён: `37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`. `sdk_config_manifest --check` прошёл после регенерации derived inventory.
- **Mac component 43738810843 / 136c946f SUCCESS**: локальные summaries/logs показывают 671 Core / 180 Host / 30 Hooks, 23 Foundation HNS cases, Java7, три real Swift/C/CPython SDK child, simulator C219 (169 baseline / 41 owner-bound), unsigned device-probe compilation.
- Получен и прочитан **independent PASS** [runtime-native-acceptance.md](../wave-2/runtime-native-acceptance.md), включая **2/2 created/freed terminal payloads**. Его SHA-256 — `a56d2b7eee2b53e02baa978a55628fbde78c7660c3bf5ac29d36a450d94243f5`. Binary verification здесь не повторялась. Evidence относится к `136c946f` и component/standalone scope; Telegram networking, UIKit и полная IPA им не подтверждены.
- Последняя принятая полная Telegram IPA: **build23 / 43635233046 / 68bb1adf**. **43740868881 / fac6cf26** после начала join завершилась **failure: 25 TelegramCore typechecks**, по позднему сообщению координатора. Четыре owners исправляют узкие signatures/captures; CI не опрашивался.
- Native UI plan — **36 labels / 85 sources / 88 classes / 410 methods**, восемь recording scenarios **3+3+2**: source provided, execution/frames ещё не получены. Последний сообщённый Linux Core — 43732308228 / 96bff39e, 661/180/30; прежние run IDs остаются историей.

### Follow-up после зафиксированной source-сверки

Новый final requirement **atomic Ghost** обнаружил legacy `for/set` в
`TelegramCore/Sources/State/ExteralessOutgoingPrivacy.swift`. Owner `ses_e1fbf2c33`
меняет Core helper и три writers, включая метод ClientRuntime Root, **не definitions**.
SDK `--check` выше прошёл **до** этой дельты. Временный raw Root-pin drift ожидаем;
координатор обновит manifest после готового кода. Это не объявлено broken Catalog.
Завершённый inventory сохраняет fac6 source pins; новый Ghost/compile follow-up
не закрыт этими receipts. Полный source scan не повторялся.

## Выбранные source claims

| Owner | IDs | Author statuses |
|---|---:|---|
| ai | 79 | `{"implemented": 55, "partial": 24}` |
| ai-visibility | 3 | `{"implemented": 3}` |
| appearance | 78 | `{"compat-storage": 3, "implemented": 15, "partial": 58, "unsupported": 2}` |
| chat | 137 | `{"partial": 135, "unsupported": 2}` |
| chat-swipe | 1 | `{"partial": 1}` |
| cloud-api | 6 | `{"partial": 6}` |
| dialogs | 18 | `{"compat-storage": 4, "partial": 14}` |
| feed | 7 | `{"partial": 7}` |
| identity | 22 | `{"partial": 22}` |
| network-maps | 6 | `{"partial": 6}` |
| pills | 20 | `{"partial": 20}` |
| player | 35 | `{"partial": 34, "unsupported": 1}` |
| privacy | 36 | `{"implemented": 16, "partial": 10, "platform-prerequisite": 1, "unsupported": 9}` |
| privacy-extras | 16 | `{"partial": 15, "unsupported": 1}` |
| retention | 27 | `{"partial": 27}` |
| runtime | 16 | `{"implemented": 8, "partial": 3, "unsupported": 5}` |
| stickers | 18 | `{"partial": 17, "unsupported": 1}` |
| tools | 42 | `{"implemented": 24, "partial": 8, "unsupported": 10}` |

Owner precedence сохранён: Feed; Player 33 Appearance fields + player/nowplaying; Pills; Dialogs; Appearance predictiveBack; Tools crash/favorites.
`nagram.showTextTranslate` — один Original ID: **Chat primary / chats.showTextTranslate**, AI secondary evidence сохранён.
Actual policy reader, отсутствие отдельной AI definition и обе Root/Share migrations найдены по символам и закреплены свежими hashes/lines.
Пять `defaultDeleteMenu*` теперь имеют actual Android derived-reader/effect chain и Chat moderation consumers; старое «нет consumer» снято.

## Пять portable adapters: source bindings применены, границы сохранены

- **`nagram.performanceClass`** (implemented): Applied native 0 automatic / 1 High up to 60 fps / 2 Average 30 fps with reduced translucency/effects/background work / 3 Low static cached animations and disabled automatic playback/loops. High is a rendering budget, not a hardware identity or permission override. Native per-feature false values and system/battery/thermal/background constraints remain ceilings. Live revision publication updates real energy settings, per-target vetoes, timers, message layouts and optional prefetch admission without persisting derived booleans. This is a defined iOS adaptation, not identical Android Canvas/cache/particle implementation; native execution/frames remain pending.
- **`etgbackup.ChatSwipeAction`** (partial): Exact -1 auto, 0 pin, 1 read, 2 archive, 3 mute, 4 delete, 5 folders semantics. Auto selects folders with native filter pages, archive otherwise; folders without filters resolves to archive. The primary trailing full-swipe option is selected only from native-eligible options after existing gates; unavailable choices retain the native fallback. All buttons and native handlers/confirmations remain. Folder paging owns center gestures, edge reveals stay native, horizontal child content wins. Registration, base/pager hooks and the exact typed mainconfig.ChatSwipeAction Cloud conversion are supplied as owner patches in chat-swipe-parity.md. No broad mainconfig import or direct Postbox toggle was added.
- **`neko.tabletMode`** (partial): Scoped root-content adapter for raw 0 Auto / 1 Tablet / 2 Phone, default/reset 0. Auto delegates to native rules; Phone really uses single navigation on regular windows; Tablet uses bounded master/detail and sheets only where actual window/safe-area/keyboard space fits. Same controller/stack objects are reparented after retiring old transitions/callbacks. Device/trait/orientation metadata is not falsified. AppearanceFeatures registration, explicit application-root role/binding and Config SDK joins are applied. Native execution/frames remain pending; Android-wide tablet hardware semantics are not claimed.
- **`neko.typeface`** (partial): Registered public Bool, default true: true selects actual Apple system sans-serif fonts; false selects bundled Roboto 3.015 upright/italic variable faces through the real Display.Font producer and family-aware cache. Root and Share/NotificationContent preparation/registration are applied. Dynamic Type size, forceFontWeightFallback and explicit serif/monospace/rounded/camera roles remain independent. The supplied Android tree lacks its bundled font bytes: byte-identical Original assets, Pixel Google Sans and exact Android line metrics are not claimed. Native UIFont/CoreText execution and UI frame coverage remain pending.
- **`appearance.monetStyle`** (partial): Registered integer selector 0 Telemone / 1 Classic, default 0, arrives through AppearanceFeatures and both extension preparation batches. Applied native theme factories, codec, presentation replay and reachable Monet settings/actions consume it only for selected descriptor-bearing native local Monet themes; the selector alone does not opt ordinary themes in. Native day/night references, schedules, wallpaper and explicit outgoing overrides keep their precedence. Accent-seeded HCT palettes, native surface mappings/contrast corrections and pinned older upstream Classic reference tokens are an iOS adaptation. The supplied Original still lacks its six Telemone/Classic/AMOLED assets; exact Android tokens, OEM wallpaper palettes and rendered equivalence are not claimed. Native compilation, resource save/relaunch and UI frames remain pending.

Applied shared source receipts (Root/TLN04/05/CA04/AP/Tools modes/IDS Avatar/AF History) приведены с точными report anchors в JSON.
Их более поздний статус приоритетнее старых ‘unapplied’ заметок внутри receipts; независимые findings этим join не закрываются.

Для всех пяти policies дополнительно найдены и закреплены actual Root/Cloud/consumer anchors.
`chat-swipe` теперь primary для одного `etgbackup.ChatSwipeAction`; старый Tools claim сохранён secondary.
**Exact Original Monet assets gap остаётся:** отсутствуют все шесть исходных Telemone/Classic/AMOLED assets.
Старые upstream Classic references, native HCT/role/contrast adaptation не выданы за восстановленные Original assets.

### Dispositions

- **unused-storage**: `nagram.folderNameAsTitle`, `nagram.strokeOnViews`, `neko.sortByContacts`, `neko.sortByUnmuted`, `neko.sortByUnread`, `neko.sortByUser`, `neko.useCustomEmoji`.
- **migrated-alias**: `appearance.centerTitle`, `general.showNagramSettings`, `nagram.customTitleUserName`, `nagram.defaultHlsVideoQuality`, `nagram.disableChannelMuteButton`, `nagram.disableCrashlyticsCollection`, `nagram.hideDividers`, `nagram.hideReactions`, `nagram.messageColoredBackground`, `neko.disableInstantCamera`, `neko.enhancedFileLoader`, `neko.rearVideoMessages`, `neko.showIdAndDc`.
- **android-specific**: `chats.unmuteWithVolumeButtons`, `energyprofiler.wakelock_hooks_broken`, `energyprofiler.wakelock_hooks_pending`, `glyph.enabled`, `glyph.onCall`, `glyph.onNewMessage`, `glyph.onRecording`, `glyph.screenOffOnly`, `icons.customNotificationIcon`, `nagram.disableProxyWhenVpnEnabled`, `nagram.notificationIcon`, `nagram.pushServiceTypeInAppDialog`, `nagram.pushServiceTypeUnifiedGateway`, `nagram.pushServiceTypeUnifiedSimple`, `nagram.pushServiceTypeUnifiedWebPushAuthSecret`, `nagram.pushServiceTypeUnifiedWebPushPrivateKey`, `nagram.pushServiceTypeUnifiedWebPushPublicKey`, `neko.cachePath`, `neko.disableNotificationBubbles`, `neko.disableSystemAccount`, `pluginscontroller.compatibilityMode`, `xposedhooks.nativeHooksBroken`, `xposedhooks.native_hooks_init_pending`, `xposedhooks.native_hooks_init_strikes`, `xposedhooks.native_hooks_unsupported_stamp`.
- **server-or-device-prerequisite**: `nagram.pushServiceType`.

Каждый disposition сохраняет конкретные original-source и owner reasons. ‘Android-specific’ относится только к названному механизму, не ко всей portable feature family.
Pills11: старый type receipt ещё пишет pending forwarding; более поздний coordinator report сообщает Rust/passive RTT applied. MtProtoKit retained RTT и physical measurements отдельно не подтверждены.

## Modules

Шесть прежних rollup gaps сведены в **partial**, с actual feature/domain contributions. Число файлов/ключей не создаёт module pass.
- `module.general` — coordinator authorship needed: For remaining GeneralHelper APIs supply members[] with original file/name/parameter_types, native path/symbol, disposition, limitation and owning domain. The inventory already retains the exact original method index.
- `module.settings` — coordinator authorship needed: Supply routes[] with original row/action symbol, native entry/factory, search/subpage/reset route, unavailable-row behavior and source anchor. Scope coverage must be explicit; native UI/frame evidence remains separate.
- `module.plugins` — coordinator authorship needed: Supply member_routes[] keyed by original API/sdk_id with native operation, provider owner, admission/lifecycle contract, source evidence and unavailable reason. Consolidate Host/SDK/UI/NativeServices/TL limits; declaration counts do not fill these fields.

`module.backup` сохраняет Tools primary плюс Retention/Cloud contributions. Все indexed Android public methods остаются в inventory; их полное покрытие не выведено из feature-count.

## SDK308 и SDK925

Blocked overloads: **0**. Прежние четыре get/setTabletMode и get/setUseSystemFonts
имеют actual registered keys в финальном SDK receipt. Все 32 unsupported overloads
с точными причинами сохранены; исходная partition **220/44/44** не менялась.

Все unsupported IDs/reasons и остальные 308 записей сохранены в JSON. Отдельно каждый из 925 SDK IDs имеет exact source relation или явно unreconciled status.
Behavioral compatibility всех 925 неизвестна; class metadata, settings registration и generic helpers не повышают их до implemented/ported.

SDK925 partition: **127 published-source-subset / 4 unsupported / 794 not-individually-reconciled**.
Все 36 SDK source modules byte-identical Original; это source identity, не behavioral compatibility.

## Текущие source-review closures

**В перечисленных final counterexample groups оставшихся reported P1/P2 нет.**
Это срез до позднего atomic Ghost follow-up. 38 опубликованных review layers и их hashes сохранены в JSON, включая прежние
`open_ids`; цепочки `supersedes` и `current_review_groups` отделяют исторический
вердикт от позднего закрытия. Агрегатор не выдаёт собственный review pass.

| Group | Принятый source scope | Final report |
|---|---|---|
| PNP | PNP-01–03 | [navigation-performance-source-closure](../wave-2/reviews/navigation-performance-source-closure.md) |
| Font | PFM-01: 3 consumers, 294 getters / 167 files | [font-consumer-source-closure](../wave-2/reviews/font-consumer-source-closure.md) |
| CMC | 13 прежних + CMC-03/05 = 15 | [chat-source-closure](../wave-2/reviews/chat-source-closure.md), [chat-final-source-closure](../wave-2/reviews/chat-final-source-closure.md) |
| Feed/Player | FPP-FU-01–04 | [feed-player-final-source-closure](../wave-2/reviews/feed-player-final-source-closure.md) |
| TL | TLN-01–11 + TLN-F01/F02 | [tl-network-source-closure](../wave-2/reviews/tl-network-source-closure.md), [tl-validator-source-closure](../wave-2/reviews/tl-validator-source-closure.md) |
| SDK | SDK-01–09; исторический SDK snapshot сохраняется | [sdk-source-closure](../wave-2/reviews/sdk-source-closure.md) |
| TBF | TBF-01–06 | [tools-source-closure](../wave-2/reviews/tools-source-closure.md) |
| CAF | CAF-01–03 | [cloud-source-closure](../wave-2/reviews/cloud-source-closure.md) |
| PFR | PFR01–05 | [privacy-retention-source-closure](../wave-2/reviews/privacy-retention-source-closure.md) |
| HNS | HNS-F01–F04 | [host-native-source-closure](../wave-2/reviews/host-native-source-closure.md) |
| AI | AIAF-01 / AI AF-03 | [ai-source-closure](../wave-2/reviews/ai-source-closure.md) |
| Identity | IDSF-01/02 завершают IDS-02 tails | [identity-source-closure](../wave-2/reviews/identity-source-closure.md) |
| Avatar | Avatar AF-01–04 + ASC-01 | [appearance-source-closure](../wave-2/reviews/appearance-source-closure.md), [avatar-crossfade-source-closure](../wave-2/reviews/avatar-crossfade-source-closure.md) |
| Darwin storage | Пятифайловая root-trust/OS-alias дельта | [darwin-storage-source-closure](../wave-2/reviews/darwin-storage-source-closure.md) |

AI `AF-03` и Avatar `AF-03` — разные report-scoped IDs. Source closures не дают
native/visual parity. Для **SCR-01** найден owner source fix и три named PASS в
Mac Core log; отдельный final independent re-review не опубликован. Это явно
сохранённое ограничение provenance, а не новый найденный дефект.

## Source anchors / data checks

Опубликованные строки сохранены как `reported_line`. Новые `line`/`matches` получены по exact anchors, symbols или явно помеченным field-token candidates; для неопределённых ссылок остаётся file-only pin.
Неоднозначные ссылки не выбираются по близости к старому номеру. Declaration/token counts — не доказательство functional effect.
`data_checks` подтверждает exact ID partitions, первичных владельцев и zero verification promotion. Проверка не исполняет SDK/plugins, не обращается к CI/network.

- Сохранены исходные Android records/configs/UI index/source pins, все **2614** module method bodies и SDK declarations. 36 SDK files совпали с Original bytes.
- Source join: **19 receipt files**, **675 pinned paths** (582 source / 93 docs), **1010** feature callsite references, unavailable callsite paths — **0**. У **346** features есть хотя бы один unique resolved source callsite; это lexical source evidence.
- **56 file-only feature references** остаются точным anchor-granularity пределом. Это не прежние 56 missing receipts: все те IDs теперь имеют claims; неоднозначность не заменена выдуманными строками.
- Однократная post-join сверка выбранных receipts: **0 drift**. Прежний Feed/SDK drift и старые 272/4/32 сохранены в [immutable history locator](cohorts/93a1badc.json), новые hashes не подставлены в старые claims.
- Выполнены `--check-data`, SDK manifest `--check` после join и **42 inventory tests PASS (1.13 s)**; [JUnit](checks/inventory-tests-fac6cf26.xml). Все команды ограничены 30 s, scanner/SDK/runtime/production source readonly.

Пределы полного port acceptance: 32 Config unsupported overloads, 794 SDK symbols без
индивидуального behavior receipt, три module authorship maps, Original asset limits,
native XCTest/frames и новая полная IPA. **567 receipts не означают 567 verified features.**
