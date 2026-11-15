# Appearance — focused follow-up, 2026-11-15

**Итог: AP-01…03 и AP-07…11 source-closed. Исправления AP-04…06 подключены,
но полное закрытие avatar family блокируют четыре оставшихся P2 ниже. P1 не подтверждён.**
`Source-closed` означает устранение исходного контрпримера в прослеженной реализации.
Native execution и AGENTS visual acceptance остаются отдельными незакрытыми gates.

## Проверенный snapshot

- HEAD/Core cohort: `6f718b1108b9f90b5d498e07ee324325842bbe5d`.
  Native working tree зафиксирован raw SHA-256 в **11:59:40 UTC** ниже.
  Читались актуальные consumers, включая coordinator Settings projection и поздние
  Identity/display-filter изменения AvatarNode/PeerAvatar, а не только handoff patches.
  В **12:11 UTC** перечитаны три изменившихся shared files — appearance updates,
  AppDelegate и ClientRuntime; superseding pins приведены в конце. AP-03/09
  сохраняют source closure; добавленная активация Identity observer не возвращает
  appearance revision в theme-loading subscription.
- Все **18 Appearance Core files** по содержимому совпадают с `git show 6f718b11`
  (с нормализацией CRLF). Старый `appearance-core-frozen.sha256` совпал для **17/18**:
  его `AppearanceFeatures.swift` pin предшествует разрешённому append
  `+ AppearanceAdditionalFeatures.settingsSectionDefinitions` на строке 238.
  Удаление только этого append **в памяти проверки** даёт прежний hash
  `4c05813205426b86fbb6be3bd968bd37c429bee10653fdb7c2020aaea0ab023d`.
  Настоящий committed hash —
  `ec7b61074fae6c89f54e7697f60d7780cd3a1f8e9c658ed78ad6a60155a99225`.
- Актуальная сборка definitions содержит **59**, а не 56, уникальных keys.
  Три coordinator controls действительно зарегистрированы и вызваны из native builder.
  Receipt пока оставляет для `nagram.hideHelpSection`, `nagram.hidePremiumSection`,
  `nagram.showStickersRowToplevel` `setting_key=null` / пустые callsites / pending hook
  explanation. Нужен refresh этих трёх receipts и одного frozen pin; это устаревшая
  аттестация, а не три неработающих переключателя.
- Изолированный реальный `merge_parity` — **PASS: 78 IDs + appicons**;
  **290** path/line-bound/explicit-symbol references разрешаются. Статусы fragment:
  15 implemented, 58 partial, 3 compat-storage, 2 unsupported, все `ported=false`.
  Структурный PASS не заменяет проверку конечного эффекта.
- Последний известный green по сообщению coordinator/user:
  **43708260304 / 7d04a35a — 545 Core, 169 Host, 30 Hooks**. Он предшествует AP
  cohort. Новый CI pending; execution этим source/test fixtures не приписывается.
- Применены ранее прочитанные AGENTS/CLAUDE/frame criteria; diff этих инструкций
  относительно первого review пуст. UIKit/Swift tests, CI и simulator не запускались.
  Проверки здесь — bounded read-only Python/hash/source операции.
- Исходный `reviews/appearance.md` сохранён: SHA-256
  `24aa06a5c4b439517545bd5e384f98bd5cdbbba3bbb7c4fbc0ffd3d7b51d482d`.
  Adjacent Privacy/Identity timers/AI и их исправления отдельного verdict не получают.

Пути: **C** = `swift/ExteralessCore/Sources/ExteralessCore`,
**S** = `telegram-ios/submodules`, **U** = `S/TelegramUI`,
**A** = `third_party/exteraless-android/TMessagesProj/src/main`.

## Перепроверка AP-01…11

| AP | Результат source follow-up |
|---|---|
| 01 | **Closed.** `C/AppearanceFeatures.swift:113–118` и `AppearancePolicy.swift:73` дают default 1. Реальный `S/ChatListUI/Sources/TabBarChatListFilterController.swift:311` использует этот pre-registration fallback. Явный 0 не мигрируется. `AppearanceRemediationTests:49–76` проверяет fresh→register→All→reopen→reset→reload; execution pending. |
| 02 | **Closed.** `U/Sources/ExteralessClient/Appearance/ExteralessTabNavigation.swift:9–18` использует фактический `PeerInfoScreen.Type`. Оба root rebuild вызывают фильтр после Feed replacement (`TelegramRootController.swift:257–258,288–296`). Live hide/reinsert сохраняет controller identity и Chats fallback. |
| 03 | **Closed.** `AppDelegate.swift:1622–1624` сначала устанавливает root; `ExteralessClientRuntime.swift:412–415` под current-context guard вызывает `appearance.rootDidBecomeReady` до privacy publication. `ExteralessAppearanceIntegration.swift:27–32,77–81,119–127` повторяет apply через weak attachment dispatcher. Новый worker не ломает ordering: создание shared context gated `clientSettingsReady` (`AppDelegate:1297–1309`), attach синхронен после подготовки. |
| 04 | **Основной profile path исправлен.** `PeerInfoAvatarTransformContainerNode.swift:295,338–345,481–491,512` сохраняет `.none`/unrounded source, а конечные photo/video/markup clips и story fraction получают один resolved style. `PeerInfoHeaderNode:1893–1913` разрешает форму перед collapse и завершает square collapse даже при radius=0. Остаток полного avatar acceptance — AF-01…04. |
| 05 | **Основной video consumer исправлен.** `ChatListItem.swift:5641–5646` берёт `avatarNode.resolvedClipStyle` и применяет его к video layer. `ChatAvatarNavigationNode:143–145,415–431` обновляет video после raster setter. Есть оставшаяся асимметрия image backend в AF-01/02. |
| 06 | **Прежние три ring-пропуска исправлены.** Все wrapper setters вызывают `updateStoryIndicator` (`AvatarNode.swift:1387,1414,1445,1450`); custom/forced forum fractions разрешаются в `1599–1606`. Navigation передаёт flag/fraction (`ChatAvatarNavigationNode:334–335`). `AvatarStoryIndicatorComponent:452–454,493–500,586–622,660–685` использует единый contour, для некруглого loading движется dash phase. Reset одинаковых stats/frame больше не зависит от изменения stats. AF-01…04 всё ещё способны нарушить согласованность самого изображения с корректным ring. |
| 07 | **Closed для исходной geometry.** Header применяет общий effective offset, center, scale, clip frame/content offset и height (`PeerInfoHeaderNode:615–617,1224,1944,1965,1975–1979,2063`). При прежних 390×488/−100/off теперь offset=0, scale=1, photo [0,488], header=488. Landscape positive clip translation перенесён внутрь clip; return/positive scroll имеют прежнюю формулу. Native frame evidence отсутствует. |
| 08 | **Closed для missing-layer/timeline дефекта.** `GlassBackgroundComponent.swift:942–984,2139–2201` добавляет tint/masks/outline/fallback в uniform и four-corner samples; обычный update использует ComponentTransition. `1004–1021` снимает navigation/ordinary geometry keys, включая masks и bounds.size. Platter removal и expansion catch/end вызывают cleanup (`NavigationBarPlatterTransitionView:282–284`, `NavigationExpansionRendererImpl:873–887`). Переходы конечны, новых бесконечных display links этот fix не вводит. |
| 09 | **Closed.** `PresentationData.swift:737–860` отделяет native theme-loading subscription от appearance revisions. `ExteralessAppearanceUpdates.swift:40–57` комбинирует latest native value на main и создаёт новый theme/cache identity без повторного `makePresentationTheme`/file decode. Palette properties проверены как `let`, divider variants создаются через `withUpdated`, reset возвращает native palette. Копируются forceSync/starGift и все поля PresentationData; формат пересчитывает showSeconds + identityCalendar/revision (`PresentationData:166–211`). |
| 10 | **Closed.** `PresenceStrings.swift:614–617,633–636` возвращает date **и** actual timestamp time для старых Gregorian dates/другого года; Persian early return сохранён. Privacy buckets ниже не изменены. Tests вызывают реальные public formatters с `relativeLastSeen:false`, а не только pure policy. |
| 11 | **Closed.** Оба yesterday callsites передают `tm_sec` (`PresenceStrings.swift:533,571`). `TextFormat/DateFormat.swift:135–144` сохраняет local/gmtime выбор и explicit-seconds OR preference; короткие relative hours не превращены в clock time. |

Core dispatcher tests не являются native-root tests: `AppearanceRootTabsTests`
отдельно проверяет реальные метатипы, а composition case фильтрует retained values
в fixture. Настоящие ready-root callbacks/первый frame ещё нужно исполнить.

## AF-01 — P2: legacy→V2 оставляет parent raster предыдущего аватара

**Место:** `S/AvatarNode/Sources/AvatarNode.swift:748–761,804–818`;
реальный выбор backend — `S/ChatListUI/Sources/Node/ChatListItem.swift:2052–2056`.

V2→legacy cleanup действительно добавлен (`AvatarNode:839–847,968–977`). Обратный
переход устанавливает `params` и `imageNode.contents`, но не переводит parent
`ContentNode` из drawable placeholder в image-only state: прежние `parameters`,
`displaySuspended=false` и **parent contents** остаются. Контраст — legacy photo
ветка `:906–908`, которая явно очищает parent contents и suspend-ит его draw.

**Repro/impact:** на одном живом AvatarNode дать полностью нарисоваться square
placeholder при corners=0; обновить тот же peer до фотографии (ChatList выбирает
V2); затем сбросить corners до 28. V2 скругляет только дочерний imageNode, поэтому
за круглой фотографией остаются квадратные углы старой gradient-подложки. Старый
parent draw также может продолжать перерисовываться из legacy parameters. Это
остаток acceptance для фото/placeholder/reset, не дефект Identity name filter.

**Fix/native check:** согласовать parent renderer, pending draw/signal и contents
с входом в V2. На настоящем AvatarNode/ImageCache проверить placeholder→photo→reset
и photo→placeholder→photo с задержанным image delivery. Проверять parent contents
и итоговый clip, а не только `applyExteralessFinalClip` на отдельном CALayer.
Текущие `AppearanceAvatarRenderingTests:23–57,60–92` эту смену backend не выполняют.

## AF-02 — P2: V2 round→bubble сохраняет старый cornerRadius

**Место:** `S/AvatarNode/Sources/AvatarNode.swift:763–799`.

Для `.round` устанавливаются `clipsToBounds=true` и radius; `.bubble` оставляет
их через `break`. Общий final-clip helper здесь намеренно пропущен (`:779`), затем
добавляется bubble mask. В результате работают **оба** ограничения: прежнее
круговое скругление и новый bubble mask. `updateSize` также пропускает bubble
(`:492–498`). Video meanwhile получает `.bubble.applyExteralessFinalClip`, который
обнуляет radius (`ExteralessAvatarShape.swift:50–61`).

**Repro/impact:** на одном V2 node, size=60×60, вызвать `.round`, затем `.bubble`
с той же фотографией. `imageNode.cornerRadius` остаётся 30 вместо 0. Tail bubble
попадает за прежний circle и обрезается; image/video contours расходятся. Такой
style выбирается настоящим monoforum branch ChatList, не тестовой новой enum case.

**Fix/native check:** при смене clip backend сбрасывать прежний radius/mask state
и устанавливать единственный текущий contour. Проверить round→bubble→round и
roundedRect→bubble при прежних size/resource, resize и shared photo/video clipping.
В новых native fixtures перебираются только round/roundedRect, bubble отсутствует.

## AF-03 — P2: PeerAvatar complete-image fallback теряет forum shape

**Место:** `S/AvatarNode/Sources/PeerAvatar.swift:107–125,143–155,388–396`.

Photo ветка выбирает `.roundedRect` для forum, но без representation fallback
передаёт в `drawPeerAvatarLetters` только `round: Bool`; функция всегда разрешает
**`.round`**, а ранее выбранный `clipStyle` теряется. Поздние Identity/zalgo edits
сохраняют font/letters forwarding, но не исправляют этот переход формы.

**Repro/impact:** forum peer, `singleRadius=false`, `size=28`, corners=14, сравнить
local-photo и no-photo результат **публичного** `peerAvatarCompleteImage`.
Photo radius=5pt, placeholder radius=7pt. При default 28 это native forum 7pt
против circle 14pt. После появления/удаления фотографии одна и та же настройка
меняет contour. Живой caller с `round=true` по default — username context menu
(`U/Sources/Chat/ChatControllerOpenUsernameContextMenu.swift:105–116`), допускающий
peer форума; это не только вспомогательный test API.

**Fix/native check:** передать уже разрешённый clip style/fraction и в letters
fallback, сохранив `.none`, caller font и unrounded semantics. Проверить complete
helper с cached PNG / отсутствующей representation для regular/forum, 0/14/28 и
singleRadius on/off. Unit assertions только о layer helper не ловят этот consumer.

## AF-04 — P2: V2→custom letters отправляет nil в backend, который его игнорирует

**Место:** `S/AvatarNode/Sources/AvatarNode.swift:447–450,965–977`;
проверенное поведение callee — `S/Display/Source/ImageNode.swift:156–163,185–205`.

Новый cleanup в `setCustomLetters` вызывает `imageNode.setSignal(.single(nil))`,
но AvatarNode создаёт ImageNode с default **enableEmpty=false**. В `setSignal`
nil очищает contents только при enableEmpty=true. Поэтому прежний V2 bitmap
остаётся дочерним layer поверх новых letters; cleanup при этом уже снял его
cornerRadius/mask. Это не успешное удаление изображения.

**Repro/impact:** на одном реальном AvatarNode показать локальное V2 фото A,
затем вызвать `setCustomLetters(["B"])` или `[" "]`. Фото A остаётся, хотя новый
state/letters уже B. Реальная ветка reuse —
`U/Components/Stories/StoryContainerScreen/Sources/PinnedBarComponent.swift:240–258`:
тот же node используется для peer с фото и следующего message без author.
Это cleanup-owned дефект, независимый от правильности Identity projection.

**Fix/native check:** действительно очистить child contents и отменить старую
image subscription; существующий `ImageNode.clearContents()` это делает
(`ImageNode.swift:222–227`). Проверить V2→letters→V2 с late completion: contents
старого peer отсутствуют после reset, placeholder виден, новый peer появляется.
Текущий same-letters native fixture стартует с letters и этот переход пропускает.

## Три новые native Settings controls

**Source connected, новых P1/P2 в этой проекции не найдено.**

- `AppearanceFeatures.swift:238` включает все три definitions;
  worker регистрирует эту assembly (`ExteralessClientRuntime.swift:54–62,83–84`).
- `PeerInfoSettingsItems.swift:387–393` действительно возвращает
  `exteralessAppearanceSettingsItems`, а не исходный массив.
  Helper (`ExteralessAppearanceSettingsItems.swift:8–22`) убирает `.support` /
  `.payment` по section identity, а не по локализованному тексту. `.wallet`,
  `.accounts`, `.advanced` и Exteraless Settings entry (`PeerInfoSettingsItems:279–285`)
  остаются в результирующей последовательности.
- Stickers вставляется после Appearance (native row id=3), получает собственный
  `AnyHashable("appearance.stickers")`, предварительная фильтрация предотвращает
  дубли. При `globalSettings=nil` row не публикуется; action вызывает существующий
  `.stickers` handler, который строит настоящий installed packs controller
  (`PeerInfoScreenSettingsActions.swift:171–175`). Иконка `PresentationResourcesSettings.stickers`
  существует в определении, это не guessed API.
- Пустые секции удаляются. `PeerInfoScreen.swift:5680–5742` измеряет только
  возвращённые секции и удаляет отсутствующие nodes; отдельный spacer для скрытой
  Help/Payment не резервируется. Toggle/reset снова строит исходный native source.
  Переходные frames удаления и скролл при keyboard/layout change ещё не проверены.
- Android source подтверждает те же три флага и Wallet exemption
  (`A/java/org/telegram/ui/SettingsActivity.java:817–879`).

## 18 дополнительных IDs + 5 прежних pending: конечная source-disposition

**Есть** ниже означает прослеженный native effect/callback, не execution или visual
parity. Для original bookkeeping state явно сохраняется partial adaptation:
доступность родственного native экрана не переносит автоматически Android slot.

| Original ID | Проверенный consumer / оставшийся предел |
|---|---|
| neko.forceFontWeightFallback | Есть: `Display/Font.swift:164,298–303,330` разрешает weight до cache key, включая italic; camera design исключён. ChatListTitleView пересобирает attributed text с computed titleFont при theme revision. |
| nagram.springAnimationCrossfade | Есть: `NavigationBarPlatterTransitionView:559–560` latch; live/sampled opacity и inspection state используют `AppearanceMotionPolicy.headerContentAlpha`. Активен в Spring, off — midpoint switch. |
| neko.hideAllTab | Есть: modern `ChatListControllerNode:1625–1667` и legacy tabs `:701–821` фильтруют presentation, выбирают реальные IDs. All сохраняется при selection All, reorder/transition/no custom folders. Native filter order не записывается этим toggle. |
| nagram.hideDividers | Canonical alias `appearance.dividerStyle`; fresh immutable list/context-menu palette при Hidden, native palette возвращается при reset. Android alias migration подтверждён в `AppearanceConfig.kt:729–735`. |
| nagram.hideHelpSection | Есть: фактическая `.support` projection; default true; см. раздел выше. Receipt отстал от coordinator integration. |
| nagram.hidePremiumSection | Есть: фактическая `.payment` projection; default false; Wallet отдельно. Receipt отстал. |
| nagram.showStickersRowToplevel | Есть: stable native row→существующий `.stickers` route, default true, ready-data gate. Receipt отстал. |
| draweraccountpickerview.expanded | Partial native presentation: реальная Settings account list / switch callbacks вместо persisted `accountsShown=true` drawer expansion. Сам expansion slot не перенесён. |
| drawercontainer.lastDayTheme | Partial: настоящий native selected theme/reference и theme editor. Android last-day-name history/quick toggle остаётся отличием. |
| drawercontainer.lastDarkTheme | Partial: настоящий automatic/night reference/editor; Android lastDarkTheme/history slot не эмулируется сохранением строки. |
| iconpickerview.fabX | Partial: named-resource editor и UIDocumentPicker с pinned target; floating inspector / Android x-coordinate отсутствует. |
| iconpickerview.fabY | Partial: тот же native editor; Android persisted/clamped y отсутствует. |
| mainmenuhelper.channel_intro | Есть: Main Menu `:348`→`ExteralessChannelCreation.swift:9–16`→реальный PermissionController intro→createChannelController. Native intro per entry отличается от Android first-use flag. |
| nagram.customTitleUserName | Alias к реальному titleText=2. Android migration действительно выбирает name и очищает boolean (`AppearanceConfig.kt:791–802`). Import migration — отдельный владелец. |
| nagram.folderNameAsTitle | Source-unused raw boolean / compat disposition; живой **другой** getter derives tabsTitleType==ICON. Его actual selected-folder header есть в `ChatListControllerNode:1455–1467`; это не независимый boolean port. |
| nagram.strokeOnViews | Source-unused client setting: declaration/ConfigCell/performance initialization, renderer read не установлен. Нет field-setter-only native control. |
| nekodelegatefragment.view_animations | Partial native list/Reduce Motion adaptation; Android global animator slot и его exact choreography не перенесены. |
| regexfiltereditactivity.view_animations | Partial mapping к реальному native regex editor; shared Android global slot и 200ms focus choreography не объявляются новым implemented toggle. Privacy editor отдельно. |
| nagram.switchStyle | Есть: actual SwitchComponent→UISwitch(0) / vector UIControl(2 filled, 3 outlined). Real `.valueChanged`, tap/drag/cancel и accessibility activation; style участвует в equality. Android slot 2 действительно вызывает drawExteraSwitch (`Switch.java:696–705`); legacy 1→2 migration сохранена как import boundary. |
| nagram.sliderStyle | Есть: eligible component использует реальный TG slider callback, 8pt rail и cached 3×24 grip; reset восстанавливает native/legacy backend. Explicit/min-limited/two-sided geometry не переопределяется в проверенных обычных native cases. Exact Android rail gap/palette остаётся partial. |
| nagram.centerActionBarTitleType | Есть: реальные action-safe chat-list и AppearanceListController title views используют scope 0/1/2/3 совместно с boolean. Это scoped native headers, не весь Android ActionBar. |
| icons.useSystemIconShape | Есть: actual App Icon table header, circle/continuous square, long press и accessibility action→persist→render. SpringBoard exact mask/launcher selection этим флагом не меняются. |
| nagram.backAnimationStyle | Есть: latched 0/1/2/3 в NavigationTransitionCoordinator, finite tap/release/reverse spring policy; 3 — paired translation. Fresh/reset=1, explicit raw choices сохраняются. Android predictive shrinking-card path адаптирован, не pixel parity. |

Также оба folder renderers реально используют title/entity projection и полное
accessibility name; selected-folder header derives icons-only mode. Monet/font
asset prerequisites из handoff сохраняются: native theme/system-font alternatives
не закрывают отсутствующие Telemone/Classic assets или original font-family selector.

## Рекомендуемый native gate

Новые fixtures прочитаны, не исполнены. Проверки Core/defaults/geometry полезны,
но Avatar helper test не исполняет image backend transitions, Switch fixture
исполняет accessibility activation, а не HID drag, и root fixture не создаёт
actual mounted account root. Source closure выше не повышает эти fixtures до PASS.

1. Исполнить соответствующие native targets из remediation на source cohort с
   обновлёнными pins; execution после build ограничить 20–30s. Добавить AF-01…04
   к настоящим AvatarNode/PeerAvatar cases с локальными fixtures, не к копии policy.
2. Root: callbacks до/после mount, повторный ready, смена/clear account, hide/revert
   выбранных tabs, Feed/Calls rebuild. С первого resting frame соблюдены flags,
   Settings/Search recovery доступен. Help/Premium оба hidden + Stickers on/off:
   нет пустой секции/дубля, action открывает настоящий packs screen.
3. Avatar: cached/no-photo/V2/legacy, круг/forum/bubble, cutout и `.none`, 28→14→0→28,
   singleRadius, 38/60/100/200pt, photo/video и normal/loading ring. Нет старого
   parent raster, double clip, detached corners; first image delivery и cancel
   не возвращают прошлый backend. Для profile pull 0/50/100pt — общий covered
   viewport в portrait/landscape/Duo и непрерывный return/collapse.
4. Glass/motion: grow/shrink, uniform/asymmetric corners, ordinary/sampled update,
   catch/cancel, mode switch/revert, off-window/background. Fill/stroke/masks/effect
   идут по одной phase; конечные animations снимаются, background не будит
   бесконечный driver. Motion 0/1/2/3 и crossfade on/off — screen/bar/keyboard вместе.
5. Switch 0/2/3: реальный tap, drag за порог/назад, cancel, disabled, RTL, style
   change во время tracking; ровно фактическое новое Bool передаётся callback.
   Slider: endpoints, min/range и backend reset; explicit geometry/hit target
   сохраняются. Не ограничивать проверку наличием setting getter.
6. Dates: real public formatters, 12/24h, seconds false→true→false и explicit
   withSeconds=true, local=false, non-UTC midnight/year/DST, Gregorian/Persian/Latin.
   В revision result сохраняются date separators/suffix/full-year/grouping и
   актуальные identityCalendar/revision. Date и clock принадлежат одному timestamp;
   native theme I/O не перезапускается от дешёвого appearance revision.

До capture ожидание: перечисленные вместе движущиеся элементы остаются в одной
phase, reset возвращает прежний layout/renderer, нет gaps, double images и stale
corner paths. Запись — `simctl io recordVideo`; сравнение — штатные labelled sheets
и tracks с **ffprobe PTS**, фактическим 2x/3x pixel ratio. Итоговые утверждения о
клиппинге/движении требуют scenario/sheet/#frame/timestamp references. Кадров сейчас нет.

## Source pins

Raw-byte manifest, 11:59:40 UTC; **51 paths**. Digest алгоритма
`sorted path + NUL + raw SHA-256 + LF`:
`12e06d55fc21b8f0fe46002b82e456fd0239863def3b00eeeae13ff9b72bb8f8`.
Для остальных 17 frozen Core файлов authoritative pins остаются в проверенном
`appearance-core-frozen.sha256`; для Features — актуальный hash ниже.

```text
aa36b2c803314b8dcbedc72ad71e18d91f9affc7c4a36b92b9e0becea5c629a5 docs/wave-2/appearance-core-frozen.sha256
c484fb21ee6798fec8f305524c84ec3ff3d471bc2ec8a9007a9d7a258da212fc docs/wave-2/appearance-owner-completion.md
7c397ebf12dc7a1e5f1a1bb54dc3b7925469af15bd2d395225fa62dbe00fb0c3 docs/wave-2/appearance-parity.json
9e359d910000a3c048c55222b483eeda07194d166d9dad1a7276865ac98479d1 docs/wave-2/appearance-remediation.md
ec7b61074fae6c89f54e7697f60d7780cd3a1f8e9c658ed78ad6a60155a99225 swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift
229c3a88cbfa8ef440893f70ec276258212942e1f1453a44989f43c40277fe0d telegram-ios/submodules/AvatarNode/Sources/AvatarNode.swift
924273af1481ae050584ea2cb5fce705402fcf595758668fa2d8e2a75541d2ce telegram-ios/submodules/AvatarNode/Sources/ExteralessAvatarShape.swift
403f43e74ce5d61856037f2a0b6562cc7544ca5a795eba9b54ac8f41354aecc9 telegram-ios/submodules/AvatarNode/Sources/PeerAvatar.swift
42034e4441fab6320b7800df89925ce26ae24b34a49e1c10241fe2514899f712 telegram-ios/submodules/AvatarNode/Tests/AppearanceAvatarRenderingTests.swift
2438ecb8590e7628ce289f49e8406dddfea90347928956d6e7bb14ecc46af770 telegram-ios/submodules/ChatListUI/Sources/ChatListControllerNode.swift
5460b5ab8802973940afcca4964fc18bff1fd8421c36030a192ef634e6cfa110 telegram-ios/submodules/ChatListUI/Sources/Node/ChatListItem.swift
78a44c1736d4f33e56a27da0b8f8afe608c5830790074a061db65c046d205685 telegram-ios/submodules/ChatListUI/Sources/TabBarChatListFilterController.swift
f7a0d1306664df65b450a9d8d33b9184ee992457cf27a470a68e288d51c0b112 telegram-ios/submodules/Display/Source/Font.swift
eded9a2bf12ad18312030da2832f8cccf97f30efed5dd8246450408e5acc733d telegram-ios/submodules/Display/Source/NavigationTransitionCoordinator.swift
a746d3354fb0fded57fb9ecd67bf186ea7bd890c77c52cd944211dae0a5fe36e telegram-ios/submodules/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift
f210596261c0ad92b0c6256bd5ef8be9fb40681d8b99c786c5f14c0480f9a6de telegram-ios/submodules/TelegramPresentationData/Sources/PresentationData.swift
e0df884681e586f848df68b939c4c53d0ed6e1dec53472a54f65f9037884dcd5 telegram-ios/submodules/TelegramPresentationData/Sources/PresentationTheme.swift
0975f21dfb09e1e13ab24a68e2610a29c381d2a9dbac8abcf3a4131d70cfcbfa telegram-ios/submodules/TelegramPresentationData/Tests/AppearancePresentationRevisionTests.swift
35c2045e612b9cd001b3bb2ccc85420b6a74af3d0a01c8bc29a359512d5ece68 telegram-ios/submodules/TelegramStringFormatting/Sources/PresenceStrings.swift
1c104dad794ebb3c7d960fd64df8236a6865d209656dbb5a8a6be722e248958b telegram-ios/submodules/TelegramStringFormatting/Tests/AppearancePresenceTests.swift
7ccb8e474979a67f60ce4ab0808be1df9c348d400276e39eb86f04cfa62afe2a telegram-ios/submodules/TelegramUI/Components/Chat/ChatAvatarNavigationNode/Sources/ChatAvatarNavigationNode.swift
8bc919df11bb1df19d5e98d2b5cbba8b05274c2d86e064edb6f63cda973732a7 telegram-ios/submodules/TelegramUI/Components/ChatList/ChatListFilterTabContainerNode/Sources/ChatListFilterTabContainerNode.swift
55007b987996a55976b1f85fd00c74b555fc8ed2474c5e0b3e98b28408add1c0 telegram-ios/submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift
7f400caf0f2070c26f5772f7a7733441f1a5a44e4a319d3388b4f4e0e1749f93 telegram-ios/submodules/TelegramUI/Components/NavigationBarComponent/Sources/NavigationBarPlatterTransitionView.swift
ee2a7dc3a571a33e8056ec6c1ca1855f7a72f12b5af97338cc509e427f6e15c5 telegram-ios/submodules/TelegramUI/Components/NavigationExpansionTransition/Sources/NavigationExpansionRendererImpl.swift
0cc3377eb4a7fc2a7c1c97de993d0416a8357093b84e6147fc94fad086b56c56 telegram-ios/submodules/TelegramUI/Components/NavigationExpansionTransition/Tests/GlassShapeKeyframesTests.swift
f008a1bb762e6ee9de0167ccaf561b2466dd787a3fbf46ea4ee852a1727c8a4a telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/ExteralessAppearanceSettingsItems.swift
2cc0e0fceab6715841114ba85f3dd21b4987a3db421e1ac41699d9e28e60704d telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoAvatarTransformContainerNode.swift
2d3e959c505b31a5c240b71a1508761273a955470080fa33a1be7272fdc34992 telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift
ecbedfd0769269b8907f6063bf557b4a8594c976c5904505d48c9de8802163ae telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift
35aeabc16d7923a1d74550145561d3ccf94bb61b5c1cdeae70fbb98210b54bda telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenSettingsActions.swift
9c1ff02e4a17096b0eacb2630d5f9218c439625fbd1467abe534de318f1f05e2 telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift
7bd9d6e5514570cba892f6dfd3d3edbef3736ff6397dd789609d3b58beee73c0 telegram-ios/submodules/TelegramUI/Components/SliderComponent/Sources/SliderComponent.swift
f1592379cbef19cb0337d1cf4d5a0ed01565748bd6ed52eafbc265fb182a87ea telegram-ios/submodules/TelegramUI/Components/Stories/AvatarStoryIndicatorComponent/Sources/AvatarStoryIndicatorComponent.swift
b71b220fd5bc0063056cffcd54c4a12620811a6aca0316718d1217932a779986 telegram-ios/submodules/TelegramUI/Components/SwitchComponent/Sources/AppearanceSwitchControl.swift
ce0a4c2c9aa06862917897223531b4f730d53c7c91651b886581b37a9398dc14 telegram-ios/submodules/TelegramUI/Components/SwitchComponent/Sources/SwitchComponent.swift
1fd6f325c7f31192bf674541d1928f234ce92d11b99cc7b88b7e495c8ed56076 telegram-ios/submodules/TelegramUI/Components/SwitchComponent/Tests/AppearanceSwitchTests.swift
facfd295a9bad78ade086802d2786165d281c43a17e0b2b56e9229b1ed040cce telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift
57e1d5d2ce42bc039c455aad8e283163e4d19487f6f8c92d31fa841eb59fd571 telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerOpenUsernameContextMenu.swift
0a8c5a9770f35e03cef485901228a980871506a83c400e4a637bf77405abc63e telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppIconLogoView.swift
295d19fa74545e7211d4b5b26ff168692dc224d2509e441fbeac95874bcbb13c telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppIcons.swift
e7a85334583e9f2658e7950dfe55ad7af167e7722833cac6882a57c7c19e0a6b telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppearanceIntegration.swift
f4c3020c85dfef975f07a68f87ebae89d77ea5d4b06cdba41b9abf90330bc5c9 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppearanceListController.swift
32796143060bed037dd77005deac42e06d3553253b8f9982a3984bacfe259e55 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppearanceTitleView.swift
c385ccbd2d52c8297d0e24b0b152568b14c5aa07a9ffdb1b4f650d10f62b6d6c telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessChannelCreation.swift
7a2dfd195995304bfca748787426e838ad80e3f18645b8b91c2628a7daefa261 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessMainMenu.swift
8cf07324211385839c6e111674031e500e63f1e3e3868a3f165d198a4d4f0453 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessTabNavigation.swift
68bf0031a8f309251776610c36e782bb53a5674aa8449756272104b43c6a86b1 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
e0cd5988728ce4c960160d2ec4a3bef3633d3cf1876f45315393df9cd3ddeeda telegram-ios/submodules/TelegramUI/Sources/TelegramRootController.swift
f4fa68c99eef0959441e213162ba2eeccb195d74e6f78e290710b84ad2d6972a telegram-ios/submodules/TelegramUI/Tests/Appearance/AppearanceRootTabsTests.swift
0b91b9e5b514cdb8cd2c42a787ce6ea72e3907299107c4092b468451ef6f6fc2 telegram-ios/submodules/TextFormat/Sources/DateFormat.swift
```

Дополнительные definition/caller pins, перечитанные при проверке AF-04 и title
bindings (12:06–12:07 UTC; не входят в digest 51 paths):

```text
46d65f25b002062f21c7b30c803a7a1b8318366848e8947842fd827fdf47887c telegram-ios/submodules/Display/Source/ImageNode.swift
a1e19866f5579da228c2f1eec2148b9ae5c5068a4b77410b430a59e8d91fe1e7 telegram-ios/submodules/TelegramUI/Components/ChatListHeaderComponent/Sources/ChatListTitleComponent.swift
50db29c756d91a16b0ab9aa0b7d01d7ee050aecc225c35b6cda2497c49bd5d47 telegram-ios/submodules/TelegramUI/Components/ChatListTitleView/Sources/ChatListTitleView.swift
c0c88a0e678eeb8397c86b87be85250f29556d65dde32d8466b4c42d927cb1a9 telegram-ios/submodules/TelegramUI/Components/Stories/StoryContainerScreen/Sources/PinnedBarComponent.swift
```

Superseding shared-source pins, 12:11:17 UTC (первый manifest оставлен историческим):

```text
099662fd1f7646dc1488ebaf1fccdea4e3cfa7ea4a26a37d8a28c6ce18bca6d2 telegram-ios/submodules/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift
0edec5c81f5b70c6a76bd281047e379c3734228cd972487d174bdd65efc66b70 telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift
ea4803af9ca289db7135b90ca8d9bdc0bccbcfc62fc321c04475f640a61c8dc1 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
```

Закрывающая read-only проверка: digest manifest, immutable original review,
23-ID таблица, четыре findings, их точные source anchors и whitespace — PASS.
После последнего чтения снова изменились полные AppDelegate/ClientRuntime;
проверенные AP ready-callsite anchors сохранились. Вердикт по этим shared files
ограничен последним перечитанным snapshot 12:11:17 выше, а не последующими edits
других владельцев. Остальные 53 latest file pins на закрывающей проверке совпали.
