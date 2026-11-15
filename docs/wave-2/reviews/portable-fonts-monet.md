# Portable Fonts + Monet — независимый source review

**Найден один новый P2: PFM-01 — process-wide UIFont globals переживают смену
семейства. Новых P1 не найдено. В проверенных путях Monet новых P1/P2 не выявлено.**
Полная source-closure живого переключения шрифтов пока не дана.

Срез: **2026-11-15 14:39 UTC**, HEAD
`4476f853e27d011ee7acc43cadccf5f7da9f7eb1`; основание — прочитанные working-tree
bytes, включая уже применённые source/BUILD joins. Прочитаны AGENTS/CLAUDE,
`font-family-parity.md`, `monet-parity.md`, actual producers, native preferences,
resource writers, lifecycle и все 5 font + 6 Monet native cases. Изменён только
этот review. Swift/Core/UIKit XCTest, Apple build, runtime bundle loading и
recorded frames **не выполнялись**; CI/HTTP/downloads не использовались.

Сокращения путей: `C/` = `swift/ExteralessCore/Sources/ExteralessCore/`,
`S/` = `telegram-ios/submodules/`, `P/` = `S/TelegramPresentationData/Sources/`,
`U/` = `S/TelegramUI/Sources/ExteralessClient/`.

## PFM-01 · P2 — новые layouts продолжают брать старое семейство из глобальных let

**Места:** `S/ListSectionHeaderNode/Sources/ListSectionHeaderNode.swift:8–9,28,127,139–147`;
`S/ChatListUI/Sources/Node/ChatListArchiveInfoItem.swift:65–66,115–116`;
`S/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift:21–22,219–220`.

Новый selector в `S/Display/Source/Font.swift:163–178` правильно перечитывает
семейство **при вызове**. Однако указанные реальные потребители вызывают его один
раз для file-global `let titleFont/textFont/actionFont`. `UIFont` уже полученного
семейства остаётся в этих globals на весь процесс. Даже `updateTheme` с новой
theme identity заново создаёт attributed string из **того же** `titleFont`, а не
запрашивает новый шрифт. Новые экземпляры node читают те же globals.

**Контрпример без предположения о кадрах:**

1. При `appearance.useSystemFonts = true` открыть Archive intro, чтобы создать
   его title/body/header. Это shipping path:
   `S/ChatListUI/Sources/Node/ChatListNode.swift:798,1120` создаёт/обновляет
   `ChatListArchiveInfoItem`; тот обновляет header на `:249–258`.
2. Переключить настройку в `false`, дождаться appearance delivery, снова открыть
   Archive. `Font.regular(13/15/20)` теперь возвращает Roboto, но новые attributed
   strings этого экрана всё ещё получают ранее сохранённые system UIFont.
   Новый `PresentationTheme.resourceCache` этого не исправляет.
3. Обратный порядок — впервые открыть экран с `false`, затем reset в `true` —
   оставляет в этих же полях Roboto. Контактная карточка в чате имеет тот же
   контрпример: её новый layout на `:219–220` использует оба прежних globals.

Это пропуск consumer integration новой изменяемой настройки, а не проблема
Roboto registration или сохранения старого CTLine. Разрешённое сохранение уже
созданного CTLine не должно фиксировать семейство **новых** layouts.

**Исправление:** разрешать обычные sans-serif fonts в актуальном layout/update
либо кешировать их по family/revision у потребителя. Очистки `Font.cache`
недостаточно: globals удерживают сами UIFont. Нужен native regression на реальном
header/contact consumer: первый layout → true/false/reset → новый theme/layout,
включая новый экземпляр node в том же процессе. Пять подготовленных font tests
проверяют factory/CTLine/TextNode с заново запрошенным font и этот порядок не
покрывают (`S/Display/Tests/ExteralessFontFamilyTests.swift:59–259`).

## Что подтверждено в исходниках

### Font producer, подготовка и lifetime

- Android default/направление выбора сверены с `NekoConfig.typeface` и
  `AndroidUtilities.java:2452–2463`: true — system, false — asset.
  `C/CoreAppearanceFontFamilyPolicy.swift:6–15,31–41` задаёт public Bool/default
  true, включая pre-registration fallback. Это отдельный key от native
  Dynamic Type `useSystemFont` и weight fallback.
- Реальная root registration включает обе новые policy groups:
  `C/AppearanceFeatures.swift:238–240`. В `U/ExteralessClientRuntime.swift:71–89`
  worker завершает font prepare до configure/register/reload publication;
  `S/TelegramUI/Sources/AppDelegate.swift:1297–1303` допускает начальный
  presentation factory только после ready. Share `ShareRootController.swift:49–55`
  и NotificationContent `NotificationViewController.swift:40–46` также готовят
  fonts и регистрируют font/Monet definitions до своих renderers.
- `ExteralessFontFamily.swift:42–95` проверяет размеры/SHA-256/PostScript identity
  и обе variation axes до использования. Registration collision возвращает
  failure; чужой font по совпавшему имени не принимается. Успешный static Result
  удерживает CGFont/providers и CTFont templates; unregister при reset/account
  change отсутствует. Failure также запоминается. Nonthrowing Font API реально
  возвращает UIKit fallback; root сообщает preparation failure, а не ready с
  якобы рабочим Roboto (`ExteralessClientRuntime.swift:23,72–74,115–117`).
- После подготовки selector читает только settings cache и static Result:
  `ClientSettings.swift:244–251,271–272,373–377`, `Font.swift:164–179`.
  Повторных file reads/registration на font request нет. Это source-свойство;
  время первого cold prepare и длительность frames не измерялись.
- Factory cache различает family, size, design, **resolved** weight, width и
  traits. Реальные upright/italic templates и wght 200…800, wdth 75/100,
  `tnum`, merged native traits и matching Apple cascade видны на
  `ExteralessFontFamily.swift:97–163`, `Font.swift:163–240,298–347`.
  Explicit mono/serif/rounded/camera, compressed/expanded и alternate-dollar
  сохраняют native role. Размер не масштабируется повторно. Текст/UTF-16/entities
  не переписываются; CJK/emoji fallback остаётся CoreText, custom emoji — своему
  отдельному renderer. Фактические outlines/shaping/selection bounds ждут native
  исполнения. Consumer cache gap выделен в PFM-01.

**Resources:** `S/Display/BUILD:64–72` перечисляет два TTF и OFL через flat
filegroup. Прямые `resources` edges обнаружены во всех пяти bundle roots:

| Root | Actual declaration |
|---|---|
| Telegram | `telegram-ios/Telegram/BUILD:1954` |
| ShareExtension | `telegram-ios/Telegram/BUILD:1142` |
| NotificationContentExtension | `telegram-ios/Telegram/BUILD:1253` |
| NativeTestHost | `telegram-ios/Tests/Exteraless/BUILD:30–39` |
| ClientUIHarness | `telegram-ios/Tests/ExteralessHarness/BUILD:154–163` |

Roboto не добавлен в `UIAppFonts` параллельно explicit registration. Это
подтверждение source graph, **не проверка содержимого собранных .app/.appex**.

### Monet: actual selection, replay и сохранение

- `U/Appearance/ExteralessAppearanceIntegration.swift:63,78–83,128–146` реально
  подключает экран, attach и detach. Mode action перечитывает `seedText` при
  нажатии (`ExteralessMonetSettingsController.swift:93,128–140`), а не захватывает
  seed при построении rows; apply блокирует повторную команду и отменяется при
  уходе с экрана (`:43–48`).
- `C/CoreAppearanceMonetPolicy.swift:5–27,85–101` сохраняет 0 Telemone / 1 Classic,
  default 0 и Light/Dark/AMOLED. Единственная client preference — public style;
  selection хранится в native day/night reference. DTO fields/initializers,
  используемые другими модулями, public.
- Production `P/MakePresentationTheme.swift:22–28,109–111` вызывает customizer до
  stock fast path; codec вызывает replay на `P/PresentationThemeCoder.swift:408`.
  `P/ExteralessMonetTheme.swift:15–20,171–205` действительно читает **текущее**
  cached setting, с сохранением encoded style до регистрации. Memo различает
  native object identity и style; новый same-index source не даёт stale seed.
- `P/ExteralessAppearanceUpdates.swift:14–19,40–58` получает appearance events и
  применяет replay к последнему native result. `P/PresentationData.swift:737–860`
  не перезапускает file-backed native source из-за style update. Palette/replay
  работают в памяти. Свежий theme/cache сохраняет native index, preview,
  forceSync/starGift и поля PresentationData; `chatWallpaper` переносится отдельно.
- Local-index namespace + canonical descriptor gate
  (`P/ExteralessMonetTheme.swift:10–12`, `C/CoreAppearanceMonetPolicy.swift:69–80`)
  оставляет ordinary builtin/cloud/local themes вне Monet. Проверка exact
  re-encoding отвергает неверный title/mode, extra fields, noncanonical seed/style
  и неверный outgoing flag. Decode/replay не записывает preferences и не
  инъецирует дополнительное enabled/mode state.
- В customizer accent становится новым seed; explicit native bubble/wallpaper
  аргументы проходят stock customizers (`P/ExteralessMonetTheme.swift:213–235`).
  При последующем style-only replay outgoing с descriptor override сохраняется
  из source (`:115,119`), wallpaper — из `source.chat.defaultWallpaper` (`:176`).
- `ExteralessMonetThemeActions.swift:63–117` создаёт настоящий encoded local
  resource, ограничивает его 256 KiB и **до reference publication** синхронно
  сохраняет/проверяет bytes в account и AccountManager stores на worker.
  Проверен реальный writer: `S/Postbox/Sources/MediaBox.swift:318–327` использует
  atomic write, а wrappers передают synchronous flag без подмены API.
- После resource I/O и внутри native transaction снова проверяются account и
  operation tokens. Старый callback после detach/dispose не выбирает reference
  нового context. CAS перечитывает выбранный slot из live native settings;
  helper `P/ExteralessMonetTheme.swift:248–256` меняет только этот reference.
  Schedules/force, typography и другие dictionaries сохраняются. Cloud tracking
  для активного slot очищается в той же transaction. Проверен реальный
  AccountManager execution/commit (`S/TelegramCore/Sources/AccountManager/AccountManagerImpl.swift:236–344,745–755`):
  уже допущенная atomic transaction может закончиться, как оговорено в handoff.
  Нового detached selection callback после неё нет.

## Независимые локальные проверки и предел доказательства

Выполнены два read-only stdin fixtures с внешним timeout **30 s** каждый:

1. Python/stdlib: **3/3 font files** совпали по size/SHA-256/Git blob SHA-1.
   Обе SFNT имеют in-bounds tables, version 3.015, разные ожидаемые PostScript
   names, wght `[100,400,900]`, wdth `[75,100,100]`, gvar и реальный GSUB `tnum`.
   Дополнительно совпал **21 Monet pin**: 7 Swift math, 3 Original source,
   2 licenses, 2 уже имеющихся Classic references и 7 cached TypeScript sources
   после обратной нормализации только import suffix `.ts` → `.js`.
2. Node/pinned TypeScript math, **не Swift/UIKit execution**: независимая
   численная проверка source recipe/role pairs для `007AFF`, `6750A4`, `777777`,
   `FF0000`, `00FF00`, `FFC107`. Все шесть blue variants совпали с literal vectors
   prepared tests; **396** проверенных text pairs после source tone correction
   дали минимум **4.500409:1**. Для gray обычный primary — `#5E5E5E`, link —
   `#00629D` / `#99CBFF`. Classic blue outgoing links требуют объявленной native
   correction: Light `#DEBCDF → #F0CDF1`, Dark `#715573 → #654A68`.
   Это oracle/model calculation, не PASS реального native factory.

Original role/shade tables и 0/1 selector сверены с поставленными Java/Kotlin.
OFL/MCU/Classic provenance явно отделяет Roboto 3.015 и старые public Classic
tokens от отсутствующих Android assets. Exact Original assets/Android wallpaper
colors/visual parity этими проверками не установлены.

К концу review Monet notices/test BUILD joins уже присутствуют:
`S/TelegramPresentationData/BUILD:33–71`, `S/TelegramUI/BUILD:15`,
`telegram-ios/Tests/Exteraless/native-tests.json:79–83`. Подготовленные **5 font +
6 Monet native tests остаются pending**, как и Core tests, actual resource
save/relaunch и labelled frame acceptance по AGENTS. Font/TextNode cases не
заменяют missing consumer case PFM-01; Monet model/codec tests не исполняют
настоящий account-bound UI writer.

Прочитан successor SDK handoff `sdk-font-layout-cohort.md`; текущий receipt
содержит **276 implemented / 0 blocked / 32 unsupported**. Старые четыре blocked
dispositions не переоткрываются. Это owner SDK evidence, не native-font proof.

## Raw SHA-256 среза

```text
8a492071f5195321e6df2c9f36ba74b9f81716712c2ac5a52cb4c11df857d132 C/AppearanceFeatures.swift
7673b03a438e9fcfc2e32a171b4f625b2a2fa267c1ae7f907a454ea31a1b639f C/CoreAppearanceFontFamilyPolicy.swift
7285eb59f890530ab9b366d4edd5552b918b88868ac1fd5c3fd15d03a94a6980 C/CoreAppearanceMonetPolicy.swift
5ad75e8071e7fb8dbd0ff1bcc0e656a8b45ace518cdd71695bae6022fe5526b8 S/Display/Source/ExteralessFontFamily.swift
dd3c497460f0e638326b9138a99a4b787538cb8e4a2158575bbeff43565a4df2 S/Display/Source/Font.swift
8bdc7bd9387e123f1c5440b23d901e7581ea03ad0d4ec85b099d62800d59db8e U/ExteralessClientRuntime.swift
32b1663e87bfda3f72fa7282db7be11f902e7845969bf99311a5b08966284157 P/ExteralessAppearanceUpdates.swift
720d9e2c4f6d15b5feb6d5c09950209dbe3788770f97630be343c4245713b9d3 P/MakePresentationTheme.swift
41754a308e86a5076b6e4114c5fef351a9a51914357d4e6c03fe4db10de46582 P/PresentationThemeCoder.swift
24d00c0dbcbe0eb9c68dbbddf3ded1de335fed756f1153afa2c3ade98295e95a P/ExteralessMonetPalette.swift
e3fac28d6acbbe1a3a02e7a0c723fc91079c8e958c490282a0a7baf0914afed6 P/ExteralessMonetTheme.swift
b192d1f82cea62edcb440081b837d92fc2e2828aa932202ce3dfc64021828520 U/Appearance/ExteralessMonetThemeActions.swift
d6db3995c9b304250cdf0c2c9c893e9cb2a73a22118807d9a94f57c5458807df U/Appearance/ExteralessMonetSettingsController.swift
5397fb6cab83199b8bbc50a34418b73fe2566fe8b0c80cb42e7989b9be446541 S/ListSectionHeaderNode/Sources/ListSectionHeaderNode.swift
f680a2fb231ef4abc3b98c6e4ce0ab30bb935ef4f4c3a51391e1227b1767b9bc S/ChatListUI/Sources/Node/ChatListArchiveInfoItem.swift
5d926ac0bf6594f0b98505de77dabe404ddb2d6534c06452144c8b4480a09dbd S/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift
```
