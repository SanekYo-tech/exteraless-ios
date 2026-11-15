# Wave 2 — final DATA join

**567/567 Original IDs имеют source receipt; receipt gaps: 0. Verified/ported promotions: 0.**

[Точная карта](wave-2-reconciliation.json) · [Основной inventory](client-features.json) · [SDK925](sdk-surface.json)

567 features, 30 modules, 925 SDK symbols, 308 Config overloads, 20 Pill settings и 15 отдельных Pill types сохранены.
`implemented` — claim автора о source, не native/runtime/visual pass. Старые 56 gaps теперь представлены все.

## Snapshot

- HEAD при join: `93a1badcb0ef414ca5218cf938e3b8e2be47a828`; исходный request pin — `6f718b1108b9f90b5d498e07ee324325842bbe5d`.
- Последний сообщённый полный Linux green: **43708260304 / 7d04a35a — 545 Core, 169 Host, 30 Hooks**.
- CI для 6f718b11 pending/unread; новый native build/frames не получены. Fingerprints не являются compiled-status.
- SDK Config: **{"blocked": 4, "implemented": 272, "unsupported": 32}**; SHA-256 `63264b9f1c8b8b88c2903b9f4f598b19c68027cf3d7590b19eafa1d290e06bfe`.
- Это именно опубликованный snapshot. Его original-inventory/source pins сохранены; после обновления входного inventory SDK owner может выпустить следующий receipt.

## Выбранные source claims

| Owner | IDs | Author statuses |
|---|---:|---|
| ai | 79 | `{"implemented": 55, "partial": 24}` |
| ai-visibility | 3 | `{"implemented": 3}` |
| appearance | 78 | `{"compat-storage": 3, "implemented": 15, "partial": 58, "unsupported": 2}` |
| chat | 137 | `{"partial": 135, "unsupported": 2}` |
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
| tools | 43 | `{"implemented": 23, "partial": 10, "unsupported": 10}` |

Owner precedence сохранён: Feed; Player 33 Appearance fields + player/nowplaying; Pills; Dialogs; Appearance predictiveBack; Tools crash/favorites.
`nagram.showTextTranslate` — один Original ID: **Chat primary / chats.showTextTranslate**, AI secondary evidence сохранён.
Actual policy reader, отсутствие отдельной AI definition и обе Root/Share migrations найдены по символам и закреплены свежими hashes/lines.
Пять `defaultDeleteMenu*` теперь имеют actual Android derived-reader/effect chain и Chat moderation consumers; старое «нет consumer» снято.

## Конкретные незакрытые ограничения

- **`nagram.performanceClass`** (partial): Original int 0=measure, 1=high, 2=average, 3=low overrides a cached Android Canvas/Lottie class. Stock native automatic/energy policy has real consumers; the forced global Android class has no one-key native mapping and is not registered as unused state.
- **`etgbackup.ChatSwipeAction`** (partial): Original int -1 selects folders when filters exist, archive otherwise; 0/1/2/3/4/5 are pin/read/archive/mute/delete/folders. A native global primary-action/folder-gesture adapter is not installed. Exact eligible-reveal insertion boundary is handed to Chat/Root; the raw mainconfig field remains reported/ignored rather than bypassing admitted public writes.
- **`neko.tabletMode`** (partial): Native automaticMasterDetail follows actual size classes and safe areas. Forced tablet/phone layout override is not implemented; no fake device-mode preference or blanket unavailable-UIKit claim.
- **`neko.typeface`** (partial): Native Font/UIFont is the platform family. The supplied source snapshot has no Android bundled font bytes/assets; TypefaceHelper's asset/system Google Sans lookup cannot be reproduced by renaming a system font. No inert family toggle, and no conflation with useSystemFont (Dynamic Type size). Bold fallback has its own real forceFontWeightFallback consumer. Exact family-selection parity remains absent.
- **`appearance.monetStyle`** (partial): Native themes/colors remain a real alternative, not a monetStyle consumer. The supplied Android src/main has Java/Kotlin/Python only, no res/assets palette base; monetAssetSuffix selects missing Telemone/Classic token assets. Exact selector/palette parity remains unimplemented, not declared impossible merely because iOS lacks a stock switch.

Applied shared source receipts (Root/TLN04/05/CA04/AP/Tools modes/IDS Avatar/AF History) приведены с точными report anchors в JSON.
Их более поздний статус приоритетнее старых ‘unapplied’ заметок внутри receipts; независимые findings этим join не закрываются.

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

Точные blocked overloads выбранного SDK snapshot:
- `compat.ExteraConfig.getTabletMode()` — NekoConfig.tabletMode: Frozen AP receipt still has setting_key=null: native automaticMasterDetail follows size classes, while the original forced phone/tablet override has no key or provider. This portable policy remains unimplemented; automatic native layout does not supply a zero-valued Config setting.
- `compat.ExteraConfig.setTabletMode(int)` — NekoConfig.tabletMode: Frozen AP receipt still has setting_key=null: native automaticMasterDetail follows size classes, while the original forced phone/tablet override has no key or provider. This portable policy remains unimplemented; automatic native layout does not supply a zero-valued Config setting.
- `compat.ExteraConfig.getUseSystemFonts()` — NekoConfig.typeface: Frozen AP receipt still has setting_key=null: the bundled/system font-family selector has no native key/provider or supplied Android font assets. UIFont is only the native baseline; useSystemFont changes Dynamic Type size, and forceFontWeightFallback changes weight, so neither is this Boolean.
- `compat.ExteraConfig.setUseSystemFonts(boolean)` — NekoConfig.typeface: Frozen AP receipt still has setting_key=null: the bundled/system font-family selector has no native key/provider or supplied Android font assets. UIFont is only the native baseline; useSystemFont changes Dynamic Type size, and forceFontWeightFallback changes weight, so neither is this Boolean.

Все unsupported IDs/reasons и остальные 308 записей сохранены в JSON. Отдельно каждый из 925 SDK IDs имеет exact source relation или явно unreconciled status.
Behavioral compatibility всех 925 неизвестна; class metadata, settings registration и generic helpers не повышают их до implemented/ported.

## Review layers

| Report | Published state | Open / follow-up IDs |
|---|---|---|
| [settings-core-followup.md](../../docs/wave-2/reviews/settings-core-followup.md) | independent-source-closure | See scoped source closure in report |
| [settings-recovery-followup.md](../../docs/wave-2/reviews/settings-recovery-followup.md) | followup-open | SCR-01 |
| [ai-core-followup.md](../../docs/wave-2/reviews/ai-core-followup.md) | historical-source-followup | See scoped source closure in report |
| [ai-final-followup.md](../../docs/wave-2/reviews/ai-final-followup.md) | historical-source-followup | See scoped source closure in report |
| [ai-af-followup.md](../../docs/wave-2/reviews/ai-af-followup.md) | followup-open | AF-03, AIAF-01 |
| [host-native-services-followup.md](../../docs/wave-2/reviews/host-native-services-followup.md) | active | HNS-F01, HNS-F02, HNS-F03, HNS-F04 |
| [privacy-retention-followup.md](../../docs/wave-2/reviews/privacy-retention-followup.md) | active | PFR01, PFR02, PFR03, PFR04, PFR05 |
| [chat-media-composer.md](../../docs/wave-2/reviews/chat-media-composer.md) | active | CMC-01, CMC-02, CMC-03, CMC-04, CMC-05, CMC-06, CMC-07, CMC-08, CMC-09, CMC-10, CMC-11, CMC-12, CMC-13, CMC-14, CMC-15 |
| [feed-player-pills-followup.md](../../docs/wave-2/reviews/feed-player-pills-followup.md) | active | FPP-FU-01, FPP-FU-02, FPP-FU-03, FPP-FU-04 |
| [sdk-config-adapters.md](../../docs/wave-2/reviews/sdk-config-adapters.md) | active | SDK-01, SDK-02, SDK-03, SDK-04, SDK-05, SDK-06, SDK-07, SDK-08, SDK-09 |
| [tools-backup-followup.md](../../docs/wave-2/reviews/tools-backup-followup.md) | active | TBF-01, TBF-02, TBF-03, TBF-04, TBF-05, TBF-06 |
| [identity-dialogs-stickers.md](../../docs/wave-2/reviews/identity-dialogs-stickers.md) | source-fixes-reported-followup-pending | IDS-01, IDS-02, IDS-03, IDS-04, IDS-05, IDS-06, IDS-07, IDS-08 |
| [appearance.md](../../docs/wave-2/reviews/appearance.md) | source-fixes-reported-followup-pending | AP-01, AP-02, AP-03, AP-04, AP-05, AP-06, AP-07, AP-08, AP-09, AP-10, AP-11 |
| [tl-network.md](../../docs/wave-2/reviews/tl-network.md) | source-remediation-reported-followup-pending | TLN-01, TLN-02, TLN-03, TLN-04, TLN-05, TLN-06, TLN-07, TLN-08, TLN-09, TLN-10, TLN-11 |
| [native-owner-token-followup.md](../../docs/wave-2/reviews/native-owner-token-followup.md) | independent-source-closure | See scoped source closure in report |

HNS-F/PFR/CMC/FU/SDK и остальные открытые хвосты сохраняются. Existing independent source closures импортированы только в review layer; никаких новых закрытий от агрегатора.

## Source anchors / data checks

Опубликованные строки сохранены как `reported_line`. Новые `line`/`matches` получены по exact anchors, symbols или явно помеченным field-token candidates; для неопределённых ссылок остаётся file-only pin.
Неоднозначные ссылки не выбираются по близости к старому номеру. Declaration/token counts — не доказательство functional effect.
`data_checks` подтверждает exact ID partitions, первичных владельцев и zero verification promotion. Проверка не исполняет SDK/plugins, не обращается к CI/network.

**Проверки выполнены:** `--check-data` passed; **42 inventory tests passed**; scoped whitespace check passed. Это проверки данных/адаптера, не Swift/SDK/runtime acceptance.

### Однократно обнаруженный post-join drift

- **Feed:** выбран `21152aea…`, после join опубликован `145146c6…`.
- **SDK Config:** выбран `63264b9f…`, после join опубликован `e0d2d881…`.
  Числа нового receipt тоже 272/4/32, но его input inventory — `0d4c6096…`,
  а окончательный `client-features.json` — **`8fa5e3e5…`**.

Новые revisions не смешаны с выбранными claims; полные hashes сохранены в JSON.
Для следующего cohort SDK owner должен привязать свою генерацию к окончательному
input snapshot. Сравнение выполнено один раз, без polling; SDK-owned outputs здесь
не перезаписывались. Матрица сохраняет исходные **0 verified** и открытые findings.
