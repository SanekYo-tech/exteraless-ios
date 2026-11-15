# Независимое ревью Native Appearance — 2026-11-15

**Итог: 11 P2; подтверждённых P1 не найдено. Полную original parity принимать рано.**
Ниже — проверяемые дефекты исходников, включая пропущенные конечные render-consumers.
Геометрические контрпримеры не являются измерениями кадров. UIKit build и visual pass
этим ревью не установлены.

## Срез и границы доказательств

- Начало ревью: HEAD `b1424e109ce1562ffc2a74e428e7577b0432dbd0`. При фиксации
  файлов в **08:30:12 UTC** HEAD уже был
  `2a03061d20921e2e87d6c674d2d56810674bdd34`. Это общий изменяющийся checkout;
  точные raw-byte SHA-256 приведены ниже. Проверенные Appearance Core sources и
  три `Appearance*Tests.swift` совпали с `b1424e10` после нормализации CRLF;
  соответствующий diff до `2a03061d` пуст.
- В **08:36–08:38 UTC** перечитаны изменившиеся shared date/video/runtime seams.
  Для них ниже есть отдельные superseding pins и актуальные номера строк.
  Identity добавил calendar/video gates; они не закрыли соответствующие Appearance
  findings. Остальные ссылки относятся к зафиксированному основному срезу.
- Прочитаны `telegram-ios/AGENTS.md`, `CLAUDE.md`, frame criteria,
  `docs/wave-2-contract.md`, оба appearance handoff, receipt, правила parity,
  UI-harness contract и реальные перечисленные ниже реализации/потребители.
- Последнее **сообщение coordinator** в прочитанном `progress.md:5–7`:
  Linux gate `43693106297`, `b1424e10`, **280 Core + 89 Host + 16 Hooks passed**.
  Старое число 122 в appearance handoff — прежний base. В этой сессии XCTest
  не запускались; логи CI не запрашивались. В трёх Appearance test sources есть
  27 методов; совпадение их source с base не доказывает UIKit/root/render coverage.
- На Windows найдён Python, `swift`/`swiftc` отсутствуют. Выполнены только bounded
  read-only Python/source checks. Нет CI dispatch, сети, пользовательского аккаунта,
  commit/push или изменений реализации.
- Реальный `tools.compat.feature_inventory.merge_parity` с Appearance fragment:
  **PASS**, 60 исходных IDs + `module.appicons`; 48 уникальных typed keys имеют
  consumer receipts; 203 ссылки проходят path/line-bound/explicit-symbol check.
  Это структурная проверка: живое поведение дополнительно прослежено ниже.
- Пересчитан весь Android Java/Kotlin snapshot: **2781 файл**, digest
  `8ef4beb977e16fc92583851958c906cfcf2e2f3a0a9c635e35209d3ad0e25cf4`, совпал с
  inventory. Алгоритм: SHA-256 от сортированных `src/main` relative path + NUL +
  raw-file SHA-256 + LF. Upstream commit у plain-source snapshot неизвестен.
- Dialog/story, identity/local-Premium, privacy, Feed/Player и общие bootstrap
  изменения использованы для трассировки взаимодействий. Findings относятся к
  Appearance; исправления общих файлов согласуются с их текущими владельцами.

Сокращения путей: **C** = `swift/ExteralessCore/Sources/ExteralessCore`,
**S** = `telegram-ios/submodules`, **U** = `S/TelegramUI`,
**A** = `third_party/exteraless-android/TMessagesProj/src/main`.

## AP-01 — P2: fresh/reset default unread counters не совпадает с оригиналом

**Место:** `C/AppearanceFeatures.swift:113–118`;
`S/ChatListUI/Sources/TabBarChatListFilterController.swift:311`.

**Источник:** `A/kotlin/xyz/nextalone/nagram/NaConfig.kt:1314–1319,1576–1587,1706–1709`.
Без сохранённых ключей `IgnoreFolderCount` читается как false, а
`IgnoreMutedCount` — как **true**, поэтому вычисленный default равен
`DIALOG_FILTER_EXCLUDE_MUTED = 1` (`NekoConfig.java:42–44`).
`ConfigItem.java:34–38` сохраняет именно этот default; `NaConfig.fixConfig` и
`LegacyDefaults.java:16–36,38–62` его не меняют. Это не только случай старого
сохранённого `IgnoreMutedCount=true`, как утверждает handoff.

**Repro/impact:** fresh store, папка с 30 unread, из них 7 unmuted: Android
показывает 7; iOS с `.integer(0)` показывает 30. Reset возвращает тот же неверный
режим. Сам числовой unmuted consumer подключён правильно.

**Fix/проверка:** default и до-registration fallback должны быть 1; явно выбранный
0 сохранить. Проверить fresh registration, явный All и reset на реальных
all/unmuted агрегатах. Исправить также утверждение в `docs/wave-2/appearance.md:284`.

## AP-02 — P2: пересборка root tabs возвращает скрытую Settings

**Место:** `U/Sources/ExteralessClient/Appearance/ExteralessTabNavigation.swift:10–16`.

Фильтр проверяет `controller is SettingsController`. Реальная вкладка создаётся
как `PeerInfoScreenImpl` (`U/Sources/TelegramRootController.swift:248–258`), а
root property имеет тип `PeerInfoScreen?` (`:82`). Проверены определения:
`S/SettingsUI/Sources/SettingsController.swift:10–12`,
`S/AccountContext/Sources/ChatController.swift:1113–1131`,
`PeerInfoScreen.swift:6527`: ни class, ни protocol не реализуют старый
`SettingsController`. Это функционально ложный predicate, не предположение об API.

**Repro/impact:** включить Hide Profile/Settings; вызвать реальную пересборку
`updateRootControllers` (например, Feed presentation callback на root `:114–117`).
`ExteralessTabNavigation:37–42` сначала умеет удалить вкладку по identity, но
`TelegramRootController:287–296` заново добавляет её и пропускает через неверный
type filter. Исправление следующим appearance callback зависит от порядка событий;
непосредственный rebuild уже нарушает persisted preference.

**Fix/проверка:** фильтровать переданный retained settings controller по identity
либо фактическому протоколу, одинаково во всех rebuild paths. Проверить hide,
Feed on/off, native Calls on/off и callback ordering; удалённый selected tab
должен перейти на Chats. Не подменять Feed старым News controller.

## AP-03 — P2: persisted tab hiding может не примениться после установки нового root

**Место:** `U/Sources/ExteralessClient/Appearance/ExteralessAppearanceIntegration.swift:71–109`;
`ExteralessTabNavigation.swift:24–29,44–51` в той же директории.

Все initial apply ищут **уже установленный** `mainWindow.viewController` и требуют
`root.chatListController.context === context`. В прочитанной композиции runtime
attach происходит в `U/Sources/AppDelegate.swift:1576`, установка ready root — лишь
в `:1586–1601`. `ExteralessClientRuntime.swift:138–141` при ready публикует только
privacy identity. Повторный `appearance.update` для того же context тоже выходит
раньше (`ExteralessAppearanceIntegration:72`).

**Repro/impact:** в offline account-switch fixture задержать `isReady`, завершить
initial presentation/native-Calls/identity/icon callbacks до установки нового root,
затем разрешить ready. При сохранённом Hide Bottom Navigation новый
`TabBarControllerNode.tabBarHidden` остаётся false: все apply ушли в guard старого
root, а root publication не повторяет применение. Настройка начинает действовать
лишь после постороннего следующего события. Это допустимый порядок, а не утверждение,
что каждый запуск обязательно воспроизводит гонку.

**Fix/проверка:** account-generation-checked appearance apply после фактической
установки root либо явная передача целевого root в composition. Проверить оба
порядка ready/callbacks и переход к новому account; скрытый bar не должен стать
видимым даже на первый resting frame.

## AP-04 — P2: форма аватара не доходит до конечного profile clip/morph

**Место:** `S/AvatarNode/Sources/ExteralessAvatarShape.swift:16–25` и пропущенный
consumer `U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoAvatarTransformContainerNode.swift:293,336–350,455–463`.

Profile намеренно просит `clipStyle: .none`, хранит unrounded bitmap и затем сам
маскирует `avatarNode.contentNode` радиусом `avatarSize/2` или `avatarSize*0.25`.
`cornerFraction` также остаётся 0.5/0.25; его использует
`PeerInfoExpansionDestination.swift:151`. Header collapse оставляет ещё один
stock radius в `PeerInfoHeaderNode.swift:1888–1896`.
Обход `.none` в общем helper корректен для unrounded consumers, но он означает,
что добавленная настройка **не управляет этим финальным clip**.

**Repro/impact:** поставить Avatar Corners=0 или Same Shape for Forums=true,
открыть профиль обычного пользователя/форума. Chat-list raster меняет форму,
profile photo/placeholder/video и morph используют старый круг/четверть радиуса.
Android profile вызывает реальный `AppearanceConfig.getAvatarCorners`
(`A/java/org/telegram/ui/ProfileActivity.java:6811`).

**Fix/проверка:** разрешать форму у владельца profile clip и передавать одну
fraction в mask, video, story и expansion destination. Сохранить unrounded image
для галереи. Проверить 28→14→0→28 и singleRadius на photo/placeholder/video,
включая chat↔profile переход.

## AP-05 — P2: video avatar в Chat List остаётся круглым поверх изменённой фотографии

**Место:** `S/ChatListUI/Sources/Node/ChatListItem.swift:2050–2055,2085–2096,5631–5637`.

Статическая фотография проходит новый AvatarNode shape, но video sibling добавлен
в `avatarNode.contentNode` и получает безусловный `width / 2.0`.
Проверено, что `S/AvatarVideoNode/Sources/AvatarVideoNode.swift:55,360–368` действительно
включает clipping и применяет переданный cornerRadius. V2 маскирует только
`imageNode`, не этот sibling.

**Repro/impact:** Avatar Corners=0, видимый premium peer с video avatar и включённым
loopEmoji. Квадратный static preview и круглый video не совпадают; при attach/detach
video форма меняется, а углы статического кадра могут остаться вокруг видео.
Исправление в `ChatAvatarNavigationNode` не закрывает отдельный ChatList consumer.
В перечитанном source также требуется `identity.premiumItemVideoAvatar=true`
(его default); новый Identity gate изменяет visibility, не форму.

**Fix/проверка:** передавать сюда ту же resolved fraction, что использована для
текущего raster, с теми же displayDimensions. Записать первый video frame,
scroll off/on и reset, а не только still photo.

## AP-06 — P2: story contour теряется на трёх реальных путях

**Места:**

1. `U/Components/Chat/ChatAvatarNavigationNode/Sources/ChatAvatarNavigationNode.swift:326–340`
   передаёт `customCornerFraction`, но оставляет `isRoundedRect=false` по default.
   В `AvatarStoryIndicatorComponent.swift:441–452,702,846` fraction используется
   только внутри `if component.isRoundedRect`: даже новый square avatar получает круг.
2. `S/AvatarNode/Sources/AvatarNode.swift:1379–1392,1415–1420` меняет content shape
   через `setPeer`, но обновляет ring только при изменении stats/presentation params.
   При прежнем frame и прежних stories shape не является условием invalidation.
   Новое поле equality у вложенного Component не поможет, пока `update` не вызван.
3. `AvatarStoryIndicatorComponent.swift:607–635,920` переключает загрузку на
   `ProgressLayer`: тот строит только ellipse, игнорирует `isRoundedRect` и вовсе
   не получает custom fraction. На открытии/loading contour снова круглый.

Здесь `AvatarStoryIndicatorComponent.swift` —
`U/Components/Stories/AvatarStoryIndicatorComponent/Sources/AvatarStoryIndicatorComponent.swift`.

**Repro/impact:** поставить 0 до открытия chat header; отдельно изменить 28→0 на
видимой строке с неизменившимися stories; затем открыть эти stories с задержанным
локальным loading signal. Фото и ring расходятся в каждом из указанных случаев.

**Fix/проверка:** единый resolved shape для normal/progress ring, explicit shape
invalidation при `setPeer`/reset и правильный rounded-path flag у navigation
consumer. Проверить также forceRoundedRect/singleRadius, одинаковые stats,
неизменённый frame и отмену loading. Dialog-owned disableStories не подменяет эту
appearance invalidation.

## AP-07 — P2: отключение gooey scale оставляет геометрию растянутого header

**Место:** `U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift:1938–1963,1997–2000,2056–2060`.

Scale теперь ограничен единицей, но центр по-прежнему движется на
`-contentOffset/2`, а высота header растёт на `-contentOffset`. Parent chain
проверен в `PeerInfoAvatarListNode.swift:52–57` той же директории.

**Repro/impact:** раскрытый профиль, Elastic Profile Avatar=false, pull с
`contentOffset=-100`. При scale=1 верх фото оказывается на **y=50**, а нижний
край — на `expandedAvatarHeight+50`; header требует покрытие до
`expandedAvatarHeight+100`. Получаются два непокрытых диапазона по 50pt. При stock
scale соответствующие scale/offset вместе обеспечивали покрытие. Это расчёт
реальной иерархии, не результат измерения screenshot. Read-only числовой check
для width=390, height=488 подтвердил off: top=50/bottom=538, on:
top=−25.128205/bottom=588 при требуемом bottom=588.

**Fix/проверка:** отключать elastic stretch согласованно с center/height/clipping
policy, а не только одним scale. Проверить pull/return при 0/50/100pt, rectangular
expanded photo, landscape и live toggle; зафиксировать, чем покрывается вся
высота header без щелей и скачка при reset.

## AP-08 — P2: новые glass layers не участвуют в штатных shape keyframes

**Место:** `U/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift:923–968,2081–2139`.

Solid/Hidden/opaque добавляют tint view, tint mask, outline и старо-iOS fallback
blur/mask. `animateShape` сначала устанавливает **последний** размер через
`update(..., .immediate)`, затем `addShapeKeyframes` анимирует только прежний набор
native/legacy/content/shadow views. Ни один новый слой в него не включён; их paths
остаются final-size и в четырёхугольном Duo варианте.
Это живой путь: `NavigationBarPlatterTransitionView.swift:931–949` вызывает
`glass.animateShape`, expansion renderer тоже его использует.

**Repro/impact:** выбрать Solid, выполнить push/back с меняющей ширину navigation
capsule; либо подать в настоящий GlassBackgroundView shape samples 140×44→340×444.
Эффект/контент получает samples, а outline/tint/mask сразу конечную геометрию.
При уменьшении заливка не покрывает ранние размеры; при увеличении новый outline
может выступать за ещё маленькую форму. Простые animated `update` также напрямую
записывают новые paths под `setDisableActions(true)`.

**Fix/проверка:** включить все добавленные geometry-bearing слои в общие sampled
timelines и их catch/cancel cleanup; для обычного transition обновлять их той же
кривой. Дополнить реальные `GlassShapeKeyframesTests` новыми mode/path assertions,
затем проверить frames на iOS 15 и 26/27, narrow/wide и Duo, включая возврат к Glare.

## AP-09 — P2: appearance invalidation запускает theme file I/O на main

**Место:** `S/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift:9–19`;
`PresentationData.swift:737–765,813` в той же директории.

Notification и settings emission принудительно идут на main, затем без queue hop
попадают в `combineLatest`/`mapToSignal` реконструкции themes.
Проверена реализация `S/SSignalKit/SwiftSignalKit/Source/Signal_Combine.swift:25–41,103–106`:
с default `queue=nil` downstream работает на emitting thread.
`MakePresentationTheme.swift:106–108,127–128` синхронно читает локальный/cloud theme
через `Data(contentsOf:)` и декодирует его.

**Repro/impact:** выбрать file-backed theme без отдельного theme-specific wallpaper,
затем менять любую Appearance
настройку либо применять icon resources. Даже unrelated avatar/menu change идёт
по этому main-thread disk/decode пути, создавая блокировку UI. Число миллисекунд
без Instruments не заявляется. Это отдельный Appearance путь, сверх уже известного
coordinator-owned synchronous `ClientSettings.configure/reload`.

**Fix/проверка:** serial worker для тяжёлой реконструкции, generation cancellation
и доставка готовых immutable presentation values на main; либо отдельная cheap
appearance revision без повторного чтения неизменённого theme. Проверить thread
у file read и отсутствие stale theme после быстрой смены режима/account.

## AP-10 — P2: non-relative last seen теряет время для известных старых timestamps

**Место:** `S/TelegramStringFormatting/Sources/PresenceStrings.swift:614–615,631–632`
(в первоначальном чтении до Identity insertion: `597–598,614–615`).

При relativeLastSeen=false свежие known timestamps стали абсолютными, но для
даты старше вчера/другого года fallback оставляет только `stringForTimestamp`
(день/месяц/год). Android `LocaleController.formatDateOnline` сохраняет
`formatDateAtTime(..., getFormatterDay())` в обеих ветках
(`A/java/org/telegram/messenger/LocaleController.java:2833–2847`).

**Repro/impact:** известный lastSeen `2026-11-13 10:15:47`, now `2026-11-15`,
relativeLastSeen=false, обычный Gregorian calendar; повторить expanded=true.
iOS теряет 10:15 (и секунды при
showSeconds=true), оригинал их показывает. Это незакрытый source-parity участок
существующего native fallback, не требование раскрыть privacy-hidden presence.
Перечитанный `ExteralessIdentityDateFormat.swift:35–45` действительно добавляет
date+time, но только при `usePersianCalendar=true`; его guard возвращает nil для
обычного default calendar. Этот helper другого владельца не закрывает AP-10.

**Fix/проверка:** передавать known absolute date **и время** во все соответствующие
ветки. Проверить сегодня/вчера/два дня/другой год, 12/24h и reset; recently/week/month
privacy buckets должны остаться исходными.

## AP-11 — P2: yesterday activity bypasses Show Seconds

**Место:** `S/TelegramStringFormatting/Sources/PresenceStrings.swift:533,571`
(до Identity insertion: `517,555`).

Новый optional `seconds` у `humanReadableStringForTimestamp` здесь не передан,
хотя timestamp и `dateTimeFormat.showSeconds` доступны. В соседних precise-date
ветках (`:535,584`) он уже передаётся. Живой consumer второй ветки —
`U/Components/Stories/StoryContainerScreen/Sources/StoryAuthorInfoComponent.swift:170`.

**Repro/impact:** `showSeconds=true`, yesterday story/activity в 10:15:47,
`short=false`. Строка остаётся `Yesterday at 10:15`, тогда как более старая precise
date содержит `10:15:47`. Android formatterDay применяет seconds consistently
(`LocaleController.java:95,102–107`). Relative «hours ago» менять не требуется.

**Fix/проверка:** передать фактический `tm_sec` в обе yesterday ветки при включённом
флаге. Проверять public native formatting functions, а не только pure
`AppearanceTimePolicy.seconds`; после reset секунды должны исчезать.

## Проверенные взаимодействия и оставшаяся приёмка

- `openContacts/openSettings` whole-bar-hidden fallbacks **уже стоят** в
  `TelegramRootController.swift:855–873`; старый handoff pending здесь устарел.
  Main Menu имеет принудительный Settings при скрытом tab/bar и отдельный Search
  при скрытом idle field. Settings/Search providers нельзя считать отсутствующими.
- Feed заменяет Contacts в обоих root rebuild и в appearance re-composition;
  `ExteralessClientRuntime.update` вызывает Feed перед Appearance. Проверена
  реализация replacement с fallback index 0. AP-02/03 относятся к соседнему
  appearance состоянию, не к отсутствию Feed wiring.
- `AppearanceMenuLayout(... preserveUnavailable:true)` сохраняет исходные и
  extension IDs при unregistration; capabilities фильтруются при render.
  Ограничения parser — 8192 characters, 128 entries на сторону. Нет finding о
  потере обычных persisted IDs только из-за отсутствия provider.
- Persistent/native tab-hide requests действительно OR-composed. System/custom/
  Material spinner backend реально переключается; snow имеет конечный cap и
  off-window/background/Low Power/Reduce Motion gates. Touch, accessibility и
  реальная cadence ещё требуют native проверки.
- Проверены finite/clamp policies: avatar 0…28, FAB `ceil(side*16/56)`, parallax
  0…0.6, drawer не шире available и 420pt, action-safe title lane, snow cap 8/32.
  Avatar policy округляет в logical points; Android `getAvatarCorners` округляет
  после перехода к physical pixels. Вместе с явно адаптированным default forum
  radius это не доказательство pixel-exact parity: сравнение нужно на указанных
  2x/3x scales, с одной resolved fraction у всех слоёв, а не повторным округлением.
- В прочитанном Appearance коде не обнаружена запись в shared theme palettes
  или UIKit appearance proxies. `makeDefaultPresentationTheme` создаёт theme;
  изменение flags через новый PresentationData не равно проверке всех equality
  gates (пример пропуска — AP-06). Identity/localPremium helpers других владельцев
  не означают завершения Appearance.
- Проверены определения `ContextControllerSourceView`,
  `NavigationBarTitleEnvironment.leftButtonsExtent`, `SettingsController`,
  `PeerInfoScreen` и `CornerRadii.insetBy`. Подозрения вида «несуществующий API» или
  «unused import обязательно ломает build» не включены без доказательства.
  **Native compile verdict отсутствует**, warnings-as-errors gate тоже не запускался.
- Immersive drawer держит сильный `backdrop` snapshot от открытия до освобождения
  controller (`ExteralessMainMenu.swift:55,66,152–153`). Account entry change
  dismisses старое меню, delayed route completion проверяет root/context. Snapshot
  не перерисовывается на rotation/theme/reload и не сбрасывается на resign-active.
  Его privacy/background/lock взаимодействие и визуальное поведение **не принято**;
  доказательства утечки/private-content exposure по одним этим строкам нет.
- После новых fragments нужен общий inventory regeneration с согласованными
  владельцами и module dispositions. На этом snapshot старый Tools duplicate
  predictive-back уже заменён `delegated_features` (`tools-parity.json:313–315`
  в перечитанном срезе; ранее `307–309`):
  владелец — Appearance, настоящий key — `appearance.predictiveBackIntensity`.
  Повторно удалять implementation из Appearance нельзя. Изолированный merge PASS
  не является вердиктом о полном наборе fragments.

### Пререквизиты / известные незакрытые переносы

Нет registered consumers для Monet 0/1, font-family selector, switchStyle=2,
sliderStyle=2, settings-logo shape, forced phone/tablet mode, selective centered-title
scopes и independent back-animation selector. Exact Telemone/Classic palettes и
Android artwork/fonts отсутствуют в этом source/assets наборе; native Themes
action не является `monetStyle` consumer. Для шрифтов `useSystemFont` в
`PresentationData.swift:859–870` — Dynamic Type size, не выбор семейства. Наличие
UIKit font/drawing/layout APIs означает pending implementation, не невозможность
переноса. Android-only notification icon и kill-app остаются отдельными platform
dispositions. Дополнительные R-appearance IDs из `remaining-ownership.json` не
закрываются этим receipt автоматически.

### Ожидаемые frames для следующего harness — до записи

Текущий `ClientUIHarness` имеет core-light/core-dark/sdk-ui; его success не
покрывает TelegramRoot tabs/profile/avatars. Нужны отдельные bounded offline
scenarios на **реальных** этих controllers, с явно предоставленными account
services. Для каждого — start/end still, open/close, light/dark, narrow/landscape,
Duo asymmetric corners, RTL и large text там, где затронут layout.

| Scenario | Что должно быть на frames |
|---|---|
| Avatars / AP-04…06 | Photo, placeholder, video, normal/loading ring используют одну форму при 28→14→0→28. Нет старого circular crop, кругового video поверх square photo, замершего ring или лишних pixels на handover. Sender name/18pt image движутся вместе при typing/topic extraction; draft/self не получают mini-avatar. |
| Profile / AP-07 | Pull 0/50/100pt и возврат: всё поле header покрыто; при disabled elasticity нет 25/50pt верхней/нижней щели. Collapse, controls и chat↔profile morph не скачут; reset возвращает исходную геометрию. |
| Glass / AP-08 | На push/back/catch/cancel stroke, tint, mask и effect меняют размер в общей фазе. Ни один слой не показывает final size раньше остальных. Повторить Solid/Hidden/Glare, opaque menus и 4 разных Duo corner radii. |
| Root / AP-02…03 | С первого resting frame соблюдены persisted hidden flags; Feed/Calls callbacks не возвращают Settings. Menu/Search и recovery Settings доступны; native transient search не сбрасывает user hide. FAB выше фактического bottom inset, исчезает в search/edit и возвращается после cancel. |
| Drawer | Header/list идут одним transform, ease-in-out около 0.28s без overshoot; cancelled pan возвращает исходное положение, fling dismisses один раз. Проверить interrupted open, vertical scroll, rotation, theme/reload, resign-active, lock/unlock и account replacement: старые private pixels/actions не должны переживать новый lifetime. |
| Navigation | Intensity 0/100/200, push/swipe/cancel/caught push: screen/bar/keyboard используют один timeline, нет uncovered gaps. 100 сохраняет stock 0.3; 0 убирает parallax, не ломает Back. Flat/expand режимы сохраняют свои правила. |
| Decorations/loading | Snow ниже bubbles, без hit interception; исчезает off-window/inactive/system-limited. Material spinner останавливается и восстанавливает настоящий system/custom backend. |

Формат evidence: scenario + `sheet-NN.png` + `#frame start–end` + **ffprobe PTS**,
сравнение tracks в points при известном pixel ratio, разбор каждого gap/jump и
соседних кадров. `simctl io recordVideo` → штатный `animation_sheet.py`, не
index/FPS и не нарисованный model screenshot. Кадров для такого сравнения сейчас нет.

## Каталог: 60 original IDs, 48 registered keys, реальные consumers

В колонке key указан суффикс `appearance.`; `—` означает отсутствие отдельного
registered key. **Есть** — прослежен source путь registration→consumer→эффект,
не runtime/visual approval. Ограничения и AP findings сохраняют статус partial.

| Original ID | Key | Живой consumer / disposition |
|---|---|---|
| appearance.avatarCorners | avatarCorners | Есть: AvatarNode raster/V2, PeerAvatar; AP-04…06, profile/video/ring не закрыты. |
| appearance.singleCornerRadius | singleCornerRadius | Есть: resolved AvatarNodeClipStyle; AP-04/06, profile и forced forum ring. |
| appearance.senderMiniAvatars | senderMiniAvatars | Есть: ChatListItem eligibility→author/preview cutout→18pt node, removal возвращает ширину. |
| appearance.hideActionBarStatus | hideActionBarStatus | Есть: ChatList, ChatTitleComponent, PeerInfoHeader status branches. |
| appearance.titleText | titleText | Есть: account-scoped header identity→пять режимов actual ChatList title. |
| appearance.monetStyle | — | Нет: native theme action не реализует Telemone/Classic selector. |
| appearance.squareFab | squareFab | Есть: ExteralessComposeButton radius/shadow, controller размещает 56pt target. |
| appearance.centerTitle | — | Legacy alias/storage; реальный boolean ниже, не второй control. |
| appearance.gooeyAvatarAnimation | gooeyAvatarAnimation | Есть: profile scale; нарушена совместная geometry, AP-07. |
| appearance.customThemes | customThemes | Есть: ChatController фильтрует render overrides, saved values остаются, forced preview precedence сохранён. |
| appearance.sectionRadius | sectionRadius | Есть: per-cell mask в appearance/menu/icons и shared Exteraless lists. |
| appearance.separateHeaders | separateHeaders | Есть: section→row transform; segmented/M3 force separated. |
| appearance.dividerStyle | dividerStyle | Есть: separatorStyle/background insets/masks; feature-list scope. |
| appearance.glassOutlineStyle | glassOutlineStyle | Есть: effect/tint/stroke selection и reset; AP-08. |
| appearance.glassMessageMenu | glassMessageMenu | Есть: stacked LensTransition и legacy context containers, opaque fill/removal/reset; AP-08 для shape animation. |
| appearance.newLoadingStyle | newLoadingStyle | Есть: ActivityIndicator выбирает system/legacy/Material; Android line/cache variants отсутствуют. |
| appearance.newChatHeaderStyle | newChatHeaderStyle | Есть: actual title pill, avatar inset, wallpaper top fade; morphology acceptance pending. |
| appearance.newNavigationBarStyle | newNavigationBarStyle | Есть: Material tab parent/chip/full-width bottom fill; gestures retained, native frames pending. |
| appearance.m3ListItems | m3ListItems | Есть: tonal cell background, min-height constraint, dividers/header policy; feature lists only. |
| appearance.iosNavigationBarStyle | iosNavigationBarStyle | Есть: uncapped tab layout/8pt sides; Material precedence. |
| appearance.iosChatHeader | — | Native centered title — candidate equivalent; independent original scope не проверен. |
| appearance.navigationDrawer | navigationDrawer | Есть: page versus window-root drawer, shared real routes. |
| appearance.immersiveDrawerAnimation | immersiveDrawerAnimation | Есть: passive backdrop scale; snapshot lifecycle/frames не приняты. |
| appearance.mainMenuLayout | mainMenuLayout | Есть: parser/editor/render/actions, mandatory Settings/Search, unavailable IDs retained. |
| icons.enabled | enabled | Есть: decoded image provider gate, base style независим. |
| icons.activePacks | activePacks | Есть: ordered owners→files→decode→immutable cache; 38 mappings. |
| icons.editingPackId | editingPackId | Есть: selected-pack editor и pinned picker target, replace/restore/export operations. |
| icons.customNotificationIcon | — | Android small-notification-icon API отсутствует; отдельный control не зарегистрирован. |
| icons.useSystemIconShape | — | Нет settings-logo consumer; launcher mask — другое системное поведение. |
| nagram.iconReplacements | iconReplacements | Есть: 0 native/1 regular SF/2 light SF, не Android artwork parity. |
| nagram.customTitle | customTitle | Есть: header mode 4, bounded single-line title. |
| neko.tabsTitleType | tabsTitleType | Есть: values [2,0,1], actual folder text/entities transform, исходное VoiceOver имя. |
| nagram.ignoreUnreadCount | ignoreUnreadCount | Есть: numeric all/unmuted/off; неверный fresh/reset default, AP-01. |
| nagram.mainTabsHideTitles | mainTabsHideTitles | Есть: modern/legacy icon/title geometry, badge offsets. Modern VoiceOver acceptance не установлена. |
| nagram.mainTabsHideCallsSettings | mainTabsHideCallsSettings | Есть: real native Calls preference, off-main mirror; Calls-only adaptation. |
| nagram.mainTabsHideContacts | mainTabsHideContacts | Есть: root identity filter/reinsert и native fallback; Feed replacement учтён. |
| nagram.mainTabsHideProfile | mainTabsHideProfile | Есть только устойчивый live-apply path; rebuild predicate неверен, AP-02/03. |
| neko.typeface | — | Системное UIFont family — baseline; original family selection не подключён. |
| nagram.switchStyle | — | Нет selector/drawing alternatives; original default 2, pending. |
| nagram.sliderStyle | — | Нет selector/drawing alternatives; original default 2, pending. |
| neko.actionBarDecoration | actionBarDecoration | Есть: ChatListTitleComponent→bounded header snow. |
| nagram.chatDecoration | chatDecoration | Есть: real wallpaper subview→bounded snow ниже history. |
| nagram.centerActionBarTitle | centerActionBarTitle | Есть: action-safe title lane, leading/center alignment, bounded hitTest. |
| nagram.centerActionBarTitleType | — | Нет independent selective scopes; не считать boolean полной заменой. |
| nagram.disableAvatarBlur | disableAvatarBlur | Есть: profile actions/edge/search/Dynamic Island blur gates, не thumbnail decoding. |
| neko.tabletMode | — | Automatic master/detail есть; forced layout selector отсутствует. |
| nagram.backAnimationStyle | — | Нет selector; effective Android fresh=SPRING(1) через UtilsConfig, не declaration 0. |
| utils.predictiveBackIntensity | predictiveBackIntensity | Есть: latched stack parallax, общий live/baked screenLayout; explicit iOS adaptation. |
| nagram.alwaysShowDownloadIcon | alwaysShowDownloadIcon | Есть: actual header action→Downloads search pane, reset убирает action. |
| nagram.hideBottomNavigationBar | hideBottomNavigationBar | Есть: persistent OR transient hide и forced Chats; initial mount gap AP-03. |
| neko.disableNumberRounding | disableNumberRounding | Есть: actual compact formatter→точный integer string без grouping. |
| neko.showSeconds | showSeconds | Есть: PresentationDateTimeFormat→message/precise formatters; пропущенные branches AP-10/11. |
| neko.disableVibration | disableVibration | Есть: HapticFeedback gate и stop ContinuousHaptic; system-owned feedback не проверен. |
| openextera.relativeLastSeen | relativeLastSeen | Есть: known timestamp branch/refresh boundaries; absolute fallback parity gap AP-10. |
| general.showNagramSettings | — | Original hidden/forced-false route; iOS Nagram settings root отсутствует, unsupported receipt. |
| nagram.disableDialogsFloatingButton | disableDialogsFloatingButton | Есть: floating/header compose selection, active-search hide и cancel relayout. |
| nagram.hideStoriesFromHeader | hideStoriesFromHeader | Есть: единый strip/expansion visibility predicate, default true. |
| nagram.hideDialogsSearchField | hideDialogsSearchField | Есть: idle search gate с current-account menu guard; active search и fallback сохранены. |
| neko.mediaPreview | mediaPreview | Есть: thumbnail eligibility→native image removal и text cutout reset. |
| nagram.disableBotOpenButton | disableBotOpenButton | Есть: layout eligibility→width restore→disabled hit target/removal. |

`module.appicons`: **есть** plist-driven catalog + native UIApplication completion,
реальная primary/alternate selection и actual-state checkmark; device acceptance
не выполнена. Все 60 receipt features остаются `ported=false` (15 implemented,
37 partial, 5 pending, 2 unsupported, 1 compat-storage); этот отчёт их не повышает.

## SHA-256 pin manifest

Raw bytes, snapshot 08:30:12 UTC. Полный manifest из 77 paths ниже имеет digest
`2cc576821d099331377d43ffbe584a406ca062489c0de3dfba222fbb22e3bf41`
по алгоритму `sorted path + NUL + sha256 + LF`. Изменение строки в общем файле
после этого snapshot требует проверки соответствующего finding по новому source.

```text
9b03ccabb1ea630fa95326b2a0d4461feb960a72f588614207dfaba369ea88db docs/wave-2/appearance-parity.json
7b7840e008b9f2e38ac96414a4b8379c45030a5f64d659702087c1be81428ddf docs/wave-2/appearance-subwave.md
1916e2c47a197b0a40aecc2afac9721f8f96dfcae7b28b28416df6ef991a7982 docs/wave-2/appearance.md
217c75d214a7b303d210e7fa81c25d1bd83804a8d397ae744bd1dfc00891eb48 docs/wave-2/progress.md
8b16917749c62983002053afa6291bdd930f8b6e1a93e67ec2844451dbf1dd07 docs/wave-2/tools-parity.json
9e95847a3607de4129fe84464d7369278b281cd196ba657ba9f42b83ffb0a3a8 telegram-ios/Telegram/Telegram-iOS/Info.plist
670cee104398e29bcd21c4f7e3bf27ee49ff0e2eb6feea970427a2257ab89804 telegram-ios/submodules/AccountContext/Sources/ChatController.swift
c828d633dc2e1181c9c9477cd57931363dec43f012a0c4c36626085c9f846ca9 telegram-ios/submodules/AccountContext/Sources/ExteralessAppearanceEntry.swift
0c0af60eca47b6d7c739e8d84e334d21419c23c99a564797dbe8fcdd97f6b7df telegram-ios/submodules/ActivityIndicator/Sources/ActivityIndicator.swift
611a16a4f5d86dbc698da12a36b13384eaca98245881fff6018f330f8942eb37 telegram-ios/submodules/ActivityIndicator/Sources/ExteralessMaterialSpinner.swift
1191b378eb0aec3085a06694a2fa52de6b54fc18b5b8edb5f282e280a8e49af4 telegram-ios/submodules/AppBundle/Sources/AppBundle/AppBundle.m
c4e44ade05622117ce5890861e7eb66e472fb28b362901c0f556b235b39cdfcd telegram-ios/submodules/AvatarNode/Sources/AvatarNode.swift
1331301ae06b7cc889d4e60c789e81541bffcb033ff58c910bbe9e8dd1d88af6 telegram-ios/submodules/AvatarNode/Sources/ExteralessAvatarShape.swift
360e7d6081fb6a6e5b9ac3ed3ed430fc5b7dc50feb624fc1734b617e3b1d8c5c telegram-ios/submodules/AvatarNode/Sources/PeerAvatar.swift
eba82d56e3991ed4ddb5b1e727d7dfcbae92a0f872e080ff993ab6d2576f9afb telegram-ios/submodules/AvatarVideoNode/Sources/AvatarVideoNode.swift
fab0ed9c7dc1a5eecb93de3d1a566a206a82c0af08d67121efcedc880cbbf776 telegram-ios/submodules/ChatListUI/Sources/ChatListController.swift
952327093dc522cdea5103b132390518b8a63397e70624e7fed05005d37387d3 telegram-ios/submodules/ChatListUI/Sources/ChatListControllerNode.swift
1981e9f5338ddf55816380eafe77845b8e58fdb9b5ff05b9a59780f1f3433aa3 telegram-ios/submodules/ChatListUI/Sources/ExteralessComposeButton.swift
f436ff58772e5b8aca1847d057e74e57c525f0e01e98688f0a7c9c3b7eb3094e telegram-ios/submodules/ChatListUI/Sources/Node/ChatListItem.swift
fd4aadf2182f418d6513165328418c472dba71c1d9bd79bf8cfbd4d4f6981a55 telegram-ios/submodules/ChatListUI/Sources/TabBarChatListFilterController.swift
df293a2decd1ac707e538945752876cb47ec78844b8a2659df2e0fc4ddad1a82 telegram-ios/submodules/DirectMediaImageCache/Sources/DirectMediaImageCache.swift
4348603279cff5c80efeb734fee2ce6c260071145dab5dc6237ac18f3ee928b5 telegram-ios/submodules/Display/Source/ExteralessSnowView.swift
60f893239e07f8763455fc15cf5c4674ae334841d0df7947140cee841f5fc226 telegram-ios/submodules/Display/Source/HapticFeedback.swift
551425e73ed93c2964b0cd13b05e334386f26de25f65f15d87b66e24b40b86cc telegram-ios/submodules/Display/Source/NativeWindowHostView.swift
05a3f0d0e66fab0cc895da32eb274100c4919a1ed9b107bf95aad164dab375ac telegram-ios/submodules/Display/Source/NavigationTransitionCoordinator.swift
994f52d6459d2251a2880f7d0827f853e74c4bd20ab7896386f4152215723450 telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Signal_Combine.swift
ebad57c5d1afdc3f5bf8cf1299aab1ed5b071b8a5ce03ddf7b0f25c308b7ded0 telegram-ios/submodules/SettingsUI/Sources/SettingsController.swift
3383bce8204d42e75614a8e0cb209c1cde8cd3bbe5668302a061c5fb316f4972 telegram-ios/submodules/TabBarUI/Sources/TabBarContollerNode.swift
b01f269cdfd7bc7010c35330b41acea80da6cbe56adbf5f1c1fda6df51d5b57f telegram-ios/submodules/TabBarUI/Sources/TabBarController.swift
124dce34cd155381145169bf21f68e403feda64db6d3f70585a101e7b5c8bdc1 telegram-ios/submodules/TabBarUI/Sources/TabBarNode.swift
0724c8b57e2a692e9e63342fa398365fc69b7545616774794f7fbcc4ac0ee100 telegram-ios/submodules/TelegramPresentationData/Sources/ExteralessFolderTitle.swift
d57da611ae3f69a5dd7436f90c9931bc7a9ee0e7a670aeae2de3ebb329ccc881 telegram-ios/submodules/TelegramPresentationData/Sources/ExteralessHeaderIdentity.swift
3719cb5c9edeb987ab274bfa2d448dd36bdb248d232ef485d43c318a4e3e8f8b telegram-ios/submodules/TelegramPresentationData/Sources/MakePresentationTheme.swift
16c8f0509b196912956b4ce27ad6445b036ae45de592cfd27dd0d2f4f929fed0 telegram-ios/submodules/TelegramPresentationData/Sources/NumericFormat.swift
766d0fb57fb89b57e850b0843dd9863b4c7514201c7670b1116bb196cf0d7780 telegram-ios/submodules/TelegramPresentationData/Sources/PresentationData.swift
ee6c5585fe66a9b00cd5b5b58316eeaf3d0df394bf2a28b8229e4f2d6f9a57aa telegram-ios/submodules/TelegramStringFormatting/Sources/DateFormat.swift
dbd5d1d3a88decf3ab7aa5adce68cb7c797c34882efd6156a69047c0e7324f69 telegram-ios/submodules/TelegramStringFormatting/Sources/PresenceStrings.swift
01ff2bf6e03b2c96c98773ebfa1842ace65334837d8c49c2d603bb364cd5fe0a telegram-ios/submodules/TelegramUI/Components/Chat/ChatAvatarNavigationNode/Sources/ChatAvatarNavigationNode.swift
9028a9df0e25e79001c287742cb6a454b40fe43485d3541e5cdfb2a7c0fee2ae telegram-ios/submodules/TelegramUI/Components/ChatList/ChatListFilterTabContainerNode/Sources/ChatListFilterTabContainerNode.swift
1589f8504a6d59d3de827616d2222d501eb6f839b3e2ad4c479a65b106d2d24a telegram-ios/submodules/TelegramUI/Components/ChatListHeaderComponent/Sources/ChatListTitleComponent.swift
f5a1a08e5c81f46fb8d384128da8eefead89fee3acabc333172ad87b6341807f telegram-ios/submodules/TelegramUI/Components/ChatListTitleView/Sources/ChatListTitleView.swift
d8436e85e1d12aa179ea8bbd4df81e41da2405f8db1f05e23fe93675fe8488aa telegram-ios/submodules/TelegramUI/Components/ChatTitleView/Sources/ChatTitleComponent.swift
e47bc5219ebfb2a4df1ad3ec6974ed85bd90025766ac29027f8d826d2654b6a7 telegram-ios/submodules/TelegramUI/Components/ContextControllerImpl/Sources/ContextActionsContainerNode.swift
d4aec078a7538a95e02356850fb41ea2a713d36a190e3e763c68b192529229eb telegram-ios/submodules/TelegramUI/Components/ContextControllerImpl/Sources/ContextControllerActionsStackNode.swift
908ce19e07910faccfafcdf41731d5f40191aed01f1ea40a1f99ac9e56ee5602 telegram-ios/submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift
cedc0eaa813c8eceb704757923659d121951b7c3cc01ffa4ab8ccd8671642443 telegram-ios/submodules/TelegramUI/Components/LensTransition/Sources/LensTransitionContainer.swift
e4565333276f23436808b6dce6bbf92e238d8bd13778dfa2ac27f2106c1c6d78 telegram-ios/submodules/TelegramUI/Components/NavigationBarComponent/Sources/NavigationBarComponentContent.swift
1d4dd44ad9f421352cc631ed24de4c5b17ad4a87805fc18fdd2ae4cccd1dc549 telegram-ios/submodules/TelegramUI/Components/NavigationBarComponent/Sources/NavigationBarPlatterTransitionView.swift
6be24fe4405f8ae609d0882fc10754c72594521607163e1cba1363332a349477 telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoAvatarListNode.swift
c551dcaf99338052a937e1e0e9b179eb83bb917252f093e6d6e728f27247b2ea telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoAvatarTransformContainerNode.swift
4a99c7b435386018d38c9d612bef838a47ce0c21bd0d112152f99253871369d8 telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift
a36d984df56806c244bcd6020242c2fdb23acdb09b070492aed48f5e8b6d9b69 telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift
1864559d4a3339f3b10fb734b353db0854298ea14cb6a5c5e45c10c98762d45d telegram-ios/submodules/TelegramUI/Components/Stories/AvatarStoryIndicatorComponent/Sources/AvatarStoryIndicatorComponent.swift
96d72087184053e71155cf13bd78e6c7633faea816375d643d20d69582515d46 telegram-ios/submodules/TelegramUI/Components/Stories/StoryContainerScreen/Sources/StoryAuthorInfoComponent.swift
df4aaeffe5a6ce5a77509aaf9a37ff04d8885ed74898aac87162ac8b48bd7189 telegram-ios/submodules/TelegramUI/Components/TabBarComponent/Sources/TabBarComponent.swift
d1198e1dc885826859192359e7078b84ade2c3fd9d62dc57023fe764bce66bcc telegram-ios/submodules/TelegramUI/Components/TabBarLayout/Sources/TabBarItemsLayout.swift
459a3257e0429ee1c3afcdefa0e93b2d357db22ceae6bf31c8160edb5eaf70ac telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift
a48c7f41e9e39f1c02a75fb7df3a6a1a83f3cfabd224533d37cdde0c862c63f7 telegram-ios/submodules/TelegramUI/Sources/ApplicationContext.swift
5b799c6cc3bc970bd5e2c2113f552f4b06bd090c2d9fc6f7c6fac3e2f162498f telegram-ios/submodules/TelegramUI/Sources/ChatController.swift
65358ebb2f85f75e08903486c7a8038d26c71053f0ae5fa0a79644090f0d344d telegram-ios/submodules/TelegramUI/Sources/ChatControllerNode.swift
2efbc39538adffee7b457d0e359da2937d5c76d5184313c90330ab7b721d0e0c telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginUIHelpers.swift
edba1b31ccf7af2eb79d0b5f5863215e8e8bc6978978857333a991e63c35d0ba telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppIcons.swift
593ca6950cc2748ab02b8b4e47799f49d654367339fb88ba4fc8cb7fbde79ed3 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppearanceIntegration.swift
430c426220d022ec6c8af132a29833bef60ee4edeac8df6e199cc596784e7a54 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppearanceLifetime.swift
8d8e9b0a6bc7d519d7fc0ad0f19a8543bb715d00cb13ced769375675b9fce1a3 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessAppearanceListController.swift
2bc6cb756bf2817cb4eb7d1e9cd3d0693c86b3c118164db55e4d76a961a66687 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessChatThemeOverrides.swift
d1e8c058d24fef23bde031cf0ef7f247fa4ace88717cf4e5e112d3889a613041 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessIconPacks.swift
c083f0767c99e12d19132dbc4d46daaea42d7dc947a0fc91d918e72efbe04033 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessIconPacksController.swift
110a115eb250716f46be97ddaaacee4eed5053406a25742ba1da4897d7bb3d2c telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessMainMenu.swift
1ffbc696dbecb46c7af093a826911304cdd7a22d3f56df6e4eb5c1503c208c84 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessMainMenuRegistry.swift
8afc82998d20f16ac9b452b3d7b10c552282f24d6de2240abe3029802ebb934b telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessTabNavigation.swift
58ed7a23b07479320e5577cbcdd78c3698f36ab7deba75a8011ce17e9914c8ee telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
79ac4211fb894dcfc200b2d668964616582339d9476918c6536495e029be79a2 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift
48f54e3c6223b6f15c6ae2c51fcd3fa7f83418edd861e64c86855bd369d21dac telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Feed/ExteralessFeedIntegration.swift
e0cd5988728ce4c960160d2ec4a3bef3633d3cf1876f45315393df9cd3ddeeda telegram-ios/submodules/TelegramUI/Sources/TelegramRootController.swift
7e48e47ef6a80e51352edb2ced23cf6890033b3ecc87c7afd842f270dac94865 telegram-ios/submodules/TelegramUIPreferences/Sources/CallListSettings.swift
9c5936dabefd0f3a0aef3169a656dac36ea07c51423f7834fce8569b7acce9ba telegram-ios/submodules/TextFormat/Sources/DateFormat.swift
```

### Дополнительные pins Core / leaf consumers / original evidence

Сняты в 08:36:17 UTC. В основной digest 77 paths не входят.

```text
c6d832932260aa24ee6fa8ff5de4c773dd08420605ced830f9c2a9e270273805 swift/ExteralessCore/Sources/ExteralessCore/AppearanceDrawerPolicy.swift
a5b01bd410db51d37941ccee4ba7d7b6eee127a3a07a50a0f23a53bd86bfab0f swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift
1b48c99f310ac75aada352c3da46680cf803ceca6969f55f43953b8589c52b48 swift/ExteralessCore/Sources/ExteralessCore/AppearanceIconArchive.swift
368eea93538bb99f7f42fd9b3a2ec209ece8a8e4c7eb88e476ad5aa7bdfc204a swift/ExteralessCore/Sources/ExteralessCore/AppearanceIconPackPolicy.swift
68bb6cdf08430533b4ddfc716603204a48d7fe439d4b275490af325f8451bceb swift/ExteralessCore/Sources/ExteralessCore/AppearanceIconPackStore.swift
2c9542ae3e2b3ac62337b87ea650bf2f8fbf461d8d4ad64bd98249967c622b16 swift/ExteralessCore/Sources/ExteralessCore/AppearancePolicy.swift
f620ed3a160a4302a2774f0201dfa29815e6165445d5465ae5d6eff3dee044a9 swift/ExteralessCore/Sources/ExteralessCore/AppearancePresentationPolicy.swift
3ca8177e72702b8f0b43f34d29de604dbfc33b27afa0804d43358f66f18d91ae swift/ExteralessCore/Sources/ExteralessCore/AppearanceSnowPolicy.swift
89704b22870db8b762557c19dedcf2b501e6756535c4defbda1fffcaf1e080c6 swift/ExteralessCore/Tests/ExteralessCoreTests/AppearanceIconPackTests.swift
65aae6991b1121918cd4dff660c0c6b42f155dde4067401b477ee4e347a97580 swift/ExteralessCore/Tests/ExteralessCoreTests/AppearancePolicyTests.swift
2e1268c84c4d06eda60f103f509ce0108d26ab60a1b979a76d0e4f8856030ce0 swift/ExteralessCore/Tests/ExteralessCoreTests/AppearancePresentationPolicyTests.swift
ef18bba2b6c04546645565f7e0274527aca289c7f3e75c1ccbe7185a9462dc88 telegram-ios/submodules/SettingsUI/Sources/Themes/ThemeSettingsAppIconItem.swift
07ec84594e010e1b727e3131466dd1870beb68c8a88336802d6a406595973be2 telegram-ios/submodules/SettingsUI/Sources/Themes/ThemeSettingsController.swift
c81f2da215f7fcc0f075f0635ee5362a180ac9ba3b072c57200c647c81b55192 telegram-ios/submodules/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift
bc1696a40a4c680f6deaf8f24354ba507b140d9feb9f4616e931ffb7f0540459 telegram-ios/submodules/TelegramPresentationData/Sources/ExteralessTabIcons.swift
115fdc4d1185bdd9d257dde8885816f6f0989c74c3bc365e82702751ce42020a third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/config/LegacyDefaults.java
9290ec10efce2897b6f554784115cb4763998f993c594a1ac15ed97b655fc907 third_party/exteraless-android/TMessagesProj/src/main/java/org/telegram/messenger/LocaleController.java
f053a0330cc0e6093a70a21cbb8e8c83898d74d1271065ff56e893203a7f846c third_party/exteraless-android/TMessagesProj/src/main/java/org/telegram/ui/ProfileActivity.java
65161f6ed60e2439f6c783b51aa3e31ad30f13d92743bde384ee1e6036c5dbd6 third_party/exteraless-android/TMessagesProj/src/main/java/tw/nekomimi/nekogram/config/ConfigItem.java
495356be6d7050b4c5ca313ff5d4bb6be61d6ce4f3022c47fcddead222014646 third_party/exteraless-android/TMessagesProj/src/main/kotlin/xyz/nextalone/nagram/NaConfig.kt
```

### Superseding pins после bounded перечитывания shared hunks

08:38:01 UTC. Для повторяющихся paths это более поздний проверенный source.
AP-03, AP-05, AP-09…11 сохраняются; Identity/calendar/video changes не получают
самостоятельного review verdict. Основной исторический manifest не переписан.

```text
396ac2ea18f5f8377fefc507abf67f44f64584f64d1cc4654454c36bec2a5bd0 docs/wave-2/tools-parity.json
d675d9006c9210ec18aee7999258f71ffe11b9b0cf2957038768cd332c97ecdf telegram-ios/submodules/AvatarVideoNode/Sources/AvatarVideoNode.swift
f216cab71f68cc1728c9843d24a019acd96f86da5fe420d45576b8c42778a935 telegram-ios/submodules/TelegramStringFormatting/Sources/DateFormat.swift
3e5e1c727055fab99d57677a3a8b0b05b0a873dadf20aefc371a8cdfe607ef79 telegram-ios/submodules/TelegramStringFormatting/Sources/PresenceStrings.swift
c9d296279bc69754bcc10ac879779d7fa962ad15c6186a8e8d3b44ee00711a08 telegram-ios/submodules/TelegramStringFormatting/Sources/ExteralessIdentityDateFormat.swift
766d0fb57fb89b57e850b0843dd9863b4c7514201c7670b1116bb196cf0d7780 telegram-ios/submodules/TelegramPresentationData/Sources/PresentationData.swift
a0606d13701d039f2b1b4ac98bff27c6199dbfd36b9cbad613058c0c43116a2f telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift
2a4ec95284696a79c5db3bcba3742bea0f333132ed1dcc27ba944921aefa13d0 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
0b91b9e5b514cdb8cd2c42a787ce6ea72e3907299107c4092b468451ef6f6fc2 telegram-ios/submodules/TextFormat/Sources/DateFormat.swift
3e84de941e12c4e28596eeb81cb9bb72ba876d685a320d0d44da98a273169d53 telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoExpansionDestination.swift
1aca621fb2c99d743970e651f4109beb7b379229ad1256aa8bb990ab36fdd4bf swift/ExteralessCore/Sources/ExteralessCore/IdentityFeatures.swift
```
