# Поверхность моста: контракт сервисов Swift

Ранжирование снято с корпуса этого прогона. Сборщик и генератор манифеста отработали по одному разу, симуляция рантайма не запускалась. Swift здесь не реализуется: документ только сопоставляет вызовы плагинов с уже существующими заглушками `PluginMessagesService`, `PluginSettingsService` и `PluginUIService`.

## Корпус

Источники уже лежали в `third_party/corpus-sources` (десять каталогов из списка clone в `.github/workflows/compat-tests.yml`). Повторный clone не делался, файлы источников не менялись.

`python -m tools.compat.collect_corpus` оставляет только файлы с маркером `__id__`. Итог сборщика: скопировано 20, дубликатов 0, пустых 1, без метаданных 18. В `third_party/corpus/all` — **20** плагинов:

`adb_lite`, `AisE`, `animtou v2.3.0`, `auto_forwarder`, `botile`, `dev-fastparse`, `direct`, `extera-easter-eggs-protector`, `LodraBu`, `Logcat viewer`, `muztep`, `plugin_creator`, `premium`, `privacy_cleaner`, `privacy_cleaner_1`, `repeater_pro`, `SearchID`, `templates`, `tg-streaks`, `Word-spam`.

`python -m tools.compat.generate_manifest` завершился успешно и записал `build/compat/manifest.json` и `build/compat/report.md`.

Из свежего отчёта:

* плагинов в корпусе: **20** (AST парсится у всех 20);
* Java-классов с префиксами `org.telegram.` / `com.exteragram.` / `app.exteraless.`: **93**, все найдены в исходниках форка, отсутствующих 0;
* Xposed-целей: **0**, плагинов с Xposed-мостом: **0**;
* плагинов с subclass-хуками (`PyMethodHook` и наследники): **14**.

### SDK-хуки

Числа — столбец «плагинов» из раздела «SDK-хуки» отчёта. Хук попадает в строку, если шаблон сканера (`tools/compat/scanner.py`, `SDK_HOOK_PATTERNS`) нашёлся в исходнике плагина. Один плагин считается один раз.

| хук | плагинов |
|---|---|
| `create_settings` | 14 |
| `add_on_send_message_hook` | 9 |
| `on_send_message_hook` | 8 |
| `on_updates_hook` | 2 |

Имя `on_updates_hook` в отчёте — это шаблон `\bon_update(s)?_hook\b` после замены `(s)?` на `s`. Под эту метку попадают и `on_update_hook`, и `on_updates_hook`; отдельной разбивки отчёт не даёт. То же правило действует для `add_on_updates_hook`, но этой строки в отчёте нет. Шаблоны request-хуков (`add_on_(pre|post)_request_hook`, `on_(pre|post)_request_hook`) и app-event (`add_on_app_event_hook`, `on_app_event_hook`) в отчёт не попали: ни один плагин их не содержит, и отдельных чисел у них нет.

Топ классов из того же отчёта (сколько плагинов вообще упоминает класс, не сколько членов зовёт): `AndroidUtilities` 10, `ApplicationLoader` 9, `Theme` 8, `Browser` 7, `PluginsController` 6, `LocaleController` 6, `UserConfig` 6, `TLRPC` 6. Дальше в отчёте идут `LaunchActivity` 6, `PluginSettingsActivity` 4, `MessagesController` 4, `SendMessagesHelper` 4, `MessageObject` 2.

## Как член сопоставлен с сервисом

Операции бэкенда (`python/virtualjava/backend.py`): `construct`, `call`, `call_instance`, `get`, `get_instance`, `set`, `set_instance`, `member_kind`, `class_exists`. Заглушка принимает их JSON-запросом `{"op","fqcn","member","args","kwargs","instance","value","pluginId"}`.

Колонка «сервис» в таблице ниже — это то, куда `BridgeServices` в `swift/PluginHost/Sources/PluginHost/BridgeServices.swift` направляет член сейчас:

* `org.telegram.messenger.AndroidUtilities#dp` и `#runOnUIThread` → `PluginUIService` (`dp`, `runOnUIThread`);
* `org.telegram.ui.ActionBar.Theme#getColor` и любой член `key_*` класса, чей fqcn заканчивается на `.Theme` → `PluginSettingsService` (`themeColor`, `themeKey`);
* `org.telegram.messenger.UserConfig#selectedAccount` и любой член с именем `getInstance` → `PluginMessagesService` (`selectedAccount`, `instanceHandle`);
* `<init>` класса с префиксом `org.telegram.ui.` → `PluginUIService` (`constructUI`);
* `<init>`, в fqcn которого есть `BadgesController` или `MessagesController` → `PluginMessagesService`. В этом корпусе таких конструкторов нет: `BadgesController` читают как поле `INSTANCE`;
* всё остальное → **нет сервиса / честный отказ**. Незнакомый член на `call` / `call_instance` / `get` / `get_instance` / `set` / `set_instance` даёт `JavaMemberError` («нет члена … на стороне iOS (v1)»). Конструктор вне двух веток выше даёт `Unimplemented`.

`call`, `call_instance`, `get`, `get_instance`, `set` и `set_instance` проходят один и тот же `switch`. Попавший в ветку ключ возвращает значение сервиса; отдельной записи для `set` нет. `class_exists` и `member_kind` эту таблицу не смотрят.

Комментарии протоколов перечисляют `TLRPC`, `SendMessagesHelper`, `MessageObject`, `Browser`, `LocaleController`, `ApplicationLoader` как зону сервисов, но методов под их члены в протоколах нет. `LocaleController#getInstance` оказывается в `PluginMessagesService` только потому, что ветка `getInstance` общая для любого класса. `PluginSettingsActivity#<init>` лежит в пакете `app.exteraless.plugins.ui`, префикс `org.telegram.ui.` не совпадает, и конструктор — честный отказ, хотя комментарий UI-сервиса этот класс называет.

Порядок строк совпадает с `write_report`: число плагинов по убыванию, при равенстве — fqcn, затем имя члена. Отчёт печатает только первые 60 членов (последняя строка отчёта — `SendMessagesHelper#getClass`, 2 плагина). Ниже полный список: **198** членов. Пустая арность `[]` значит, что сканер увидел атрибут без вызова (`argc is None`): это чтение поля (`get` / `get_instance`), не `call`.

Из 198 строк к сервисам привязаны 51: `PluginUIService` — 14, `PluginSettingsService` — 27, `PluginMessagesService` — 10. Остальные 147 — честный отказ.

Сканер пишет вызовы только для owned-префиксов `org.telegram.`, `com.exteragram.`, `app.exteraless.`. Вызовы вне этих префиксов в манифест членов не попадают, и чисел по ним здесь нет.

## Ранжирование членов

| # | класс#член | плагинов | арности | сервис |
|---|---|---|---|---|
| 1 | `org.telegram.messenger.ApplicationLoader#applicationContext` | 8 | [] | нет сервиса / честный отказ |
| 2 | `org.telegram.messenger.AndroidUtilities#dp` | 6 | [1] | PluginUIService |
| 3 | `org.telegram.ui.ActionBar.Theme#getColor` | 6 | [1] | PluginSettingsService |
| 4 | `app.exteraless.plugins.PluginsController#getInstance` | 5 | [0] | PluginMessagesService |
| 5 | `org.telegram.ui.ActionBar.Theme#key_dialogTextBlack` | 5 | [] | PluginSettingsService |
| 6 | `org.telegram.messenger.LocaleController#getInstance` | 4 | [0] | PluginMessagesService |
| 7 | `org.telegram.messenger.Utilities#Callback` | 4 | [] | нет сервиса / честный отказ |
| 8 | `org.telegram.ui.ActionBar.Theme#key_windowBackgroundWhiteBlackText` | 4 | [] | PluginSettingsService |
| 9 | `org.telegram.ui.Components.UItem#asShadow` | 4 | [0, 1] | нет сервиса / честный отказ |
| 10 | `org.telegram.ui.LaunchActivity#getClass` | 4 | [0] | нет сервиса / честный отказ |
| 11 | `app.exteraless.plugins.ui.PluginSettingsActivity#<init>` | 3 | [1] | нет сервиса / честный отказ |
| 12 | `app.exteraless.plugins.ui.PluginSettingsActivity#getClass` | 3 | [0] | нет сервиса / честный отказ |
| 13 | `com.exteragram.messenger.api.dto.BadgeDTO#<init>` | 3 | [2] | нет сервиса / честный отказ |
| 14 | `com.exteragram.messenger.api.model.ProfileStatus#DEVELOPER` | 3 | [] | нет сервиса / честный отказ |
| 15 | `com.exteragram.messenger.badges.BadgesController#INSTANCE` | 3 | [] | нет сервиса / честный отказ |
| 16 | `com.exteragram.messenger.badges.source.BadgeInfo#<init>` | 3 | [3] | нет сервиса / честный отказ |
| 17 | `org.telegram.messenger.AndroidUtilities#TYPEFACE_ROBOTO_MEDIUM` | 3 | [] | нет сервиса / честный отказ |
| 18 | `org.telegram.messenger.AndroidUtilities#bold` | 3 | [0] | нет сервиса / честный отказ |
| 19 | `org.telegram.messenger.AndroidUtilities#decelerateInterpolator` | 3 | [] | нет сервиса / честный отказ |
| 20 | `org.telegram.messenger.AndroidUtilities#getTypeface` | 3 | [1] | нет сервиса / честный отказ |
| 21 | `org.telegram.messenger.AndroidUtilities#runOnUIThread` | 3 | [2] | PluginUIService |
| 22 | `org.telegram.messenger.FileLoader#getInstance` | 3 | [1] | PluginMessagesService |
| 23 | `org.telegram.messenger.ImageLocation#getForDocument` | 3 | [1] | нет сервиса / честный отказ |
| 24 | `org.telegram.messenger.MediaDataController#getInstance` | 3 | [1] | PluginMessagesService |
| 25 | `org.telegram.messenger.MessagesController#getInstance` | 3 | [1] | PluginMessagesService |
| 26 | `org.telegram.messenger.UserConfig#selectedAccount` | 3 | [] | PluginMessagesService |
| 27 | `org.telegram.messenger.browser.Browser#openUrl` | 3 | [2, 10] | нет сервиса / честный отказ |
| 28 | `org.telegram.tgnet.TLRPC#TL_inputStickerSetShortName` | 3 | [0] | нет сервиса / честный отказ |
| 29 | `org.telegram.ui.ActionBar.BottomSheet#<init>` | 3 | [2, 3] | PluginUIService |
| 30 | `org.telegram.ui.ActionBar.BottomSheet#setApplyBottomPadding` | 3 | [1] | нет сервиса / честный отказ |
| 31 | `org.telegram.ui.ActionBar.BottomSheet#setApplyTopPadding` | 3 | [1] | нет сервиса / честный отказ |
| 32 | `org.telegram.ui.ActionBar.BottomSheet#setCanDismissWithSwipe` | 3 | [1] | нет сервиса / честный отказ |
| 33 | `org.telegram.ui.ActionBar.Theme#createSimpleSelectorRoundRectDrawable` | 3 | [3] | нет сервиса / честный отказ |
| 34 | `org.telegram.ui.ActionBar.Theme#key_chat_inLoader` | 3 | [] | PluginSettingsService |
| 35 | `org.telegram.ui.ActionBar.Theme#key_dialogBackground` | 3 | [] | PluginSettingsService |
| 36 | `org.telegram.ui.ActionBar.Theme#key_dialogTextBlue` | 3 | [] | PluginSettingsService |
| 37 | `org.telegram.ui.ActionBar.Theme#key_dialogTextGray` | 3 | [] | PluginSettingsService |
| 38 | `org.telegram.ui.ActionBar.Theme#key_divider` | 3 | [] | PluginSettingsService |
| 39 | `org.telegram.ui.ActionBar.Theme#key_featuredStickers_addButton` | 3 | [] | PluginSettingsService |
| 40 | `org.telegram.ui.ActionBar.Theme#key_featuredStickers_addButtonPressed` | 3 | [] | PluginSettingsService |
| 41 | `org.telegram.ui.ActionBar.Theme#key_featuredStickers_buttonText` | 3 | [] | PluginSettingsService |
| 42 | `org.telegram.ui.ActionBar.Theme#key_premiumGradient1` | 3 | [] | PluginSettingsService |
| 43 | `org.telegram.ui.ActionBar.Theme#key_windowBackgroundGray` | 3 | [] | PluginSettingsService |
| 44 | `org.telegram.ui.ActionBar.Theme#key_windowBackgroundWhiteGrayText` | 3 | [] | PluginSettingsService |
| 45 | `org.telegram.ui.Components.BackupImageView#<init>` | 3 | [1] | PluginUIService |
| 46 | `org.telegram.ui.Components.BackupImageView#setRoundRadius` | 3 | [1] | нет сервиса / честный отказ |
| 47 | `org.telegram.ui.Components.LayoutHelper#createFrame` | 3 | [3, 7] | нет сервиса / честный отказ |
| 48 | `org.telegram.ui.Components.LayoutHelper#createLinear` | 3 | [2, 3, 4, 6, 7] | нет сервиса / честный отказ |
| 49 | `org.telegram.ui.Components.Premium.StarParticlesView#<init>` | 3 | [1, 2] | PluginUIService |
| 50 | `org.telegram.ui.Components.Premium.StarParticlesView#doNotFling` | 3 | [] | нет сервиса / честный отказ |
| 51 | `org.telegram.ui.Components.Premium.StarParticlesView#drawable` | 3 | [] | нет сервиса / честный отказ |
| 52 | `org.telegram.ui.Components.Premium.StarParticlesView#setClipWithGradient` | 3 | [0] | нет сервиса / честный отказ |
| 53 | `org.telegram.ui.Components.UItem#asCustom` | 3 | [1] | нет сервиса / честный отказ |
| 54 | `org.telegram.ui.Gifts.GiftSheet#<init>` | 3 | [5] | PluginUIService |
| 55 | `org.telegram.ui.Gifts.GiftSheet#show` | 3 | [0] | нет сервиса / честный отказ |
| 56 | `org.telegram.ui.LaunchActivity#instance` | 3 | [] | нет сервиса / честный отказ |
| 57 | `org.telegram.ui.SettingsActivity#getClass` | 3 | [0] | нет сервиса / честный отказ |
| 58 | `org.telegram.ui.SettingsActivity$SettingCell$Factory#getClass` | 3 | [0] | нет сервиса / честный отказ |
| 59 | `app.exteraless.plugins.PluginsConstants#PYTHON` | 2 | [] | нет сервиса / честный отказ |
| 60 | `org.telegram.messenger.SendMessagesHelper#getClass` | 2 | [0] | нет сервиса / честный отказ |
| 61 | `org.telegram.messenger.UserConfig#MAX_ACCOUNT_COUNT` | 2 | [] | нет сервиса / честный отказ |
| 62 | `org.telegram.messenger.UserConfig#getInstance` | 2 | [1] | PluginMessagesService |
| 63 | `org.telegram.messenger.Utilities#pluginsQueue` | 2 | [] | нет сервиса / честный отказ |
| 64 | `org.telegram.tgnet.TLRPC#TL_inputDocument` | 2 | [0] | нет сервиса / честный отказ |
| 65 | `org.telegram.tgnet.TLRPC#TL_inputMediaDocument` | 2 | [0] | нет сервиса / честный отказ |
| 66 | `org.telegram.tgnet.TLRPC#TL_inputMediaPhoto` | 2 | [0] | нет сервиса / честный отказ |
| 67 | `org.telegram.tgnet.TLRPC#TL_inputPhoto` | 2 | [0] | нет сервиса / честный отказ |
| 68 | `org.telegram.tgnet.TLRPC#TL_inputReplyToMessage` | 2 | [0] | нет сервиса / честный отказ |
| 69 | `org.telegram.tgnet.TLRPC#TL_messageMediaDocument` | 2 | [] | нет сервиса / честный отказ |
| 70 | `org.telegram.tgnet.TLRPC#TL_messageMediaPhoto` | 2 | [] | нет сервиса / честный отказ |
| 71 | `org.telegram.tgnet.TLRPC#TL_messages_sendMedia` | 2 | [0] | нет сервиса / честный отказ |
| 72 | `org.telegram.tgnet.TLRPC#TL_messages_sendMessage` | 2 | [0] | нет сервиса / честный отказ |
| 73 | `org.telegram.ui.ActionBar.ActionBarMenuItem$Item#getClass` | 2 | [0] | нет сервиса / честный отказ |
| 74 | `org.telegram.ui.ActionBar.BottomSheet#dismiss` | 2 | [0] | нет сервиса / честный отказ |
| 75 | `org.telegram.ui.ActionBar.BottomSheet#setCustomView` | 2 | [1] | нет сервиса / честный отказ |
| 76 | `org.telegram.ui.ActionBar.BottomSheet#show` | 2 | [0] | нет сервиса / честный отказ |
| 77 | `org.telegram.ui.ActionBar.Theme#key_dialogTextLink` | 2 | [] | PluginSettingsService |
| 78 | `org.telegram.ui.ActionBar.Theme#key_text_RedRegular` | 2 | [] | PluginSettingsService |
| 79 | `org.telegram.ui.ActionBar.Theme#key_windowBackgroundWhite` | 2 | [] | PluginSettingsService |
| 80 | `org.telegram.ui.Components.ItemOptions#makeOptions` | 2 | [2, 3] | нет сервиса / честный отказ |
| 81 | `org.telegram.ui.Components.ShareAlert#<init>` | 2 | [14] | PluginUIService |
| 82 | `org.telegram.ui.Components.ShareAlert#setDelegate` | 2 | [1] | нет сервиса / честный отказ |
| 83 | `org.telegram.ui.Components.UItem#asHeader` | 2 | [1] | нет сервиса / честный отказ |
| 84 | `app.exteraless.appearance.AltSeekbar#<init>` | 1 | [7] | нет сервиса / честный отказ |
| 85 | `app.exteraless.appearance.AltSeekbar#OnDrag` | 1 | [] | нет сервиса / честный отказ |
| 86 | `app.exteraless.appearance.AltSeekbar#setProgress` | 1 | [1] | нет сервиса / честный отказ |
| 87 | `app.exteraless.plugins.Plugin#_chaquopy_reflector` | 1 | [] | нет сервиса / честный отказ |
| 88 | `app.exteraless.plugins.PluginsController#getPluginEngine` | 1 | [1] | нет сервиса / честный отказ |
| 89 | `app.exteraless.plugins.PluginsController#openPluginSettings` | 1 | [1] | нет сервиса / честный отказ |
| 90 | `app.exteraless.plugins.ui.PluginsActivity#_chaquopy_reflector` | 1 | [] | нет сервиса / честный отказ |
| 91 | `app.exteraless.plugins.ui.components.templates.UniversalFragment#<init>` | 1 | [1] | нет сервиса / честный отказ |
| 92 | `com.exteragram.messenger.ExteraConfig#getAvatarCorners` | 1 | [1] | нет сервиса / честный отказ |
| 93 | `com.exteragram.messenger.plugins.ui.components.InstallPluginBottomSheet#PluginInstallParams` | 1 | [2] | нет сервиса / честный отказ |
| 94 | `org.telegram.messenger.AccountInstance#getInstance` | 1 | [1] | PluginMessagesService |
| 95 | `org.telegram.messenger.AndroidUtilities#addToClipboard` | 1 | [1] | нет сервиса / честный отказ |
| 96 | `org.telegram.messenger.AndroidUtilities#dpf2` | 1 | [1] | нет сервиса / честный отказ |
| 97 | `org.telegram.messenger.AndroidUtilities#getClass` | 1 | [0] | нет сервиса / честный отказ |
| 98 | `org.telegram.messenger.AndroidUtilities#getDeclaredMethod` | 1 | [2] | нет сервиса / честный отказ |
| 99 | `org.telegram.messenger.AndroidUtilities#getPhotoSize` | 1 | [1] | нет сервиса / честный отказ |
| 100 | `org.telegram.messenger.AndroidUtilities#notifyDataSetChanged` | 1 | [1] | нет сервиса / честный отказ |
| 101 | `org.telegram.messenger.AndroidUtilities#openSharing` | 1 | [2] | нет сервиса / честный отказ |
| 102 | `org.telegram.messenger.AndroidUtilities#readRes` | 1 | [1] | нет сервиса / честный отказ |
| 103 | `org.telegram.messenger.FileLoader#getClosestPhotoSizeWithSize` | 1 | [2] | нет сервиса / честный отказ |
| 104 | `org.telegram.messenger.FileLoader#getDocumentFileName` | 1 | [1] | нет сервиса / честный отказ |
| 105 | `org.telegram.messenger.ImageLoader#scaleAndSaveImage` | 1 | [5] | нет сервиса / честный отказ |
| 106 | `org.telegram.messenger.ImageLocation#getForPhoto` | 1 | [2] | нет сервиса / честный отказ |
| 107 | `org.telegram.messenger.LocaleController#getLocaleStringIso639` | 1 | [0] | нет сервиса / честный отказ |
| 108 | `org.telegram.messenger.LocaleController#getString` | 1 | [1] | нет сервиса / честный отказ |
| 109 | `org.telegram.messenger.MediaDataController#getClass` | 1 | [0] | нет сервиса / честный отказ |
| 110 | `org.telegram.messenger.MessageObject#<init>` | 1 | [4] | нет сервиса / честный отказ |
| 111 | `org.telegram.messenger.MessageObject#isTopicMainMessage` | 1 | [] | нет сервиса / честный отказ |
| 112 | `org.telegram.messenger.MessageObject#replaceAnimatedEmoji` | 1 | [3] | нет сервиса / честный отказ |
| 113 | `org.telegram.messenger.MessagesController#getClass` | 1 | [0] | нет сервиса / честный отказ |
| 114 | `org.telegram.messenger.NotificationCenter#NotificationCenterDelegate` | 1 | [] | нет сервиса / честный отказ |
| 115 | `org.telegram.messenger.NotificationCenter#didReceiveNewMessages` | 1 | [] | нет сервиса / честный отказ |
| 116 | `org.telegram.messenger.NotificationCenter#getInstance` | 1 | [1] | PluginMessagesService |
| 117 | `org.telegram.messenger.SendMessagesHelper#getInstance` | 1 | [1] | PluginMessagesService |
| 118 | `org.telegram.messenger.SendMessagesHelper#prepareSendingArticle` | 1 | [16] | нет сервиса / честный отказ |
| 119 | `org.telegram.messenger.SendMessagesHelper$SendMessageParams#of` | 1 | [2] | нет сервиса / честный отказ |
| 120 | `org.telegram.messenger.browser.Browser#getClass` | 1 | [0] | нет сервиса / честный отказ |
| 121 | `org.telegram.tgnet.TLRPC#TL_channel` | 1 | [] | нет сервиса / честный отказ |
| 122 | `org.telegram.tgnet.TLRPC#TL_chat` | 1 | [] | нет сервиса / честный отказ |
| 123 | `org.telegram.tgnet.TLRPC#TL_contacts_resolveUsername` | 1 | [0] | нет сервиса / честный отказ |
| 124 | `org.telegram.tgnet.TLRPC#TL_document` | 1 | [] | нет сервиса / честный отказ |
| 125 | `org.telegram.tgnet.TLRPC#TL_documentAttributeAudio` | 1 | [0] | нет сервиса / честный отказ |
| 126 | `org.telegram.tgnet.TLRPC#TL_documentAttributeFilename` | 1 | [] | нет сервиса / честный отказ |
| 127 | `org.telegram.tgnet.TLRPC#TL_inputSingleMedia` | 1 | [0] | нет сервиса / честный отказ |
| 128 | `org.telegram.tgnet.TLRPC#TL_keyboardButtonCallback` | 1 | [0] | нет сервиса / честный отказ |
| 129 | `org.telegram.tgnet.TLRPC#TL_keyboardButtonRow` | 1 | [0] | нет сервиса / честный отказ |
| 130 | `org.telegram.tgnet.TLRPC#TL_messageEntityBlockquote` | 1 | [0] | нет сервиса / честный отказ |
| 131 | `org.telegram.tgnet.TLRPC#TL_messageEntityBold` | 1 | [0] | нет сервиса / честный отказ |
| 132 | `org.telegram.tgnet.TLRPC#TL_messageEntityCustomEmoji` | 1 | [0] | нет сервиса / честный отказ |
| 133 | `org.telegram.tgnet.TLRPC#TL_messageEntityTextUrl` | 1 | [0] | нет сервиса / честный отказ |
| 134 | `org.telegram.tgnet.TLRPC#TL_messageMediaEmpty` | 1 | [] | нет сервиса / честный отказ |
| 135 | `org.telegram.tgnet.TLRPC#TL_messageMediaWebPage` | 1 | [] | нет сервиса / честный отказ |
| 136 | `org.telegram.tgnet.TLRPC#TL_messages_checkChatInvite` | 1 | [0] | нет сервиса / честный отказ |
| 137 | `org.telegram.tgnet.TLRPC#TL_messages_getChats` | 1 | [0] | нет сервиса / честный отказ |
| 138 | `org.telegram.tgnet.TLRPC#TL_messages_sendMultiMedia` | 1 | [0] | нет сервиса / честный отказ |
| 139 | `org.telegram.tgnet.TLRPC#TL_peerChannel` | 1 | [] | нет сервиса / честный отказ |
| 140 | `org.telegram.tgnet.TLRPC#TL_peerChat` | 1 | [] | нет сервиса / честный отказ |
| 141 | `org.telegram.tgnet.TLRPC#TL_peerUser` | 1 | [] | нет сервиса / честный отказ |
| 142 | `org.telegram.tgnet.TLRPC#TL_photo` | 1 | [] | нет сервиса / честный отказ |
| 143 | `org.telegram.tgnet.TLRPC#TL_replyInlineMarkup` | 1 | [0] | нет сервиса / честный отказ |
| 144 | `org.telegram.tgnet.TLRPC#TL_updateMessageID` | 1 | [] | нет сервиса / честный отказ |
| 145 | `org.telegram.tgnet.TLRPC#TL_updateNewMessage` | 1 | [] | нет сервиса / честный отказ |
| 146 | `org.telegram.tgnet.TLRPC#TL_updateShortSentMessage` | 1 | [] | нет сервиса / честный отказ |
| 147 | `org.telegram.tgnet.TLRPC#TL_user` | 1 | [] | нет сервиса / честный отказ |
| 148 | `org.telegram.ui.ActionBar.AlertDialog#<init>` | 1 | [2] | PluginUIService |
| 149 | `org.telegram.ui.ActionBar.AlertDialog#Builder` | 1 | [1] | нет сервиса / честный отказ |
| 150 | `org.telegram.ui.ActionBar.AlertDialog#OnButtonClickListener` | 1 | [] | нет сервиса / честный отказ |
| 151 | `org.telegram.ui.ActionBar.BottomSheet#Builder` | 1 | [1] | нет сервиса / честный отказ |
| 152 | `org.telegram.ui.ActionBar.BottomSheet#dismissFast` | 1 | [0] | нет сервиса / честный отказ |
| 153 | `org.telegram.ui.ActionBar.BottomSheet#dismissInternal` | 1 | [0] | нет сервиса / честный отказ |
| 154 | `org.telegram.ui.ActionBar.BottomSheet#fixNavigationBar` | 1 | [1] | нет сервиса / честный отказ |
| 155 | `org.telegram.ui.ActionBar.BottomSheet#getContainer` | 1 | [0] | нет сервиса / честный отказ |
| 156 | `org.telegram.ui.ActionBar.BottomSheet#getParent` | 1 | [0] | нет сервиса / честный отказ |
| 157 | `org.telegram.ui.ActionBar.BottomSheet#hide` | 1 | [0] | нет сервиса / честный отказ |
| 158 | `org.telegram.ui.ActionBar.BottomSheet#setAllowNestedScroll` | 1 | [1] | нет сервиса / честный отказ |
| 159 | `org.telegram.ui.ActionBar.BottomSheet#setAnimateKeyboard` | 1 | [1] | нет сервиса / честный отказ |
| 160 | `org.telegram.ui.ActionBar.BottomSheet#setBackgroundColor` | 1 | [1] | нет сервиса / честный отказ |
| 161 | `org.telegram.ui.ActionBar.BottomSheet#setOnDismissListener` | 1 | [1] | нет сервиса / честный отказ |
| 162 | `org.telegram.ui.ActionBar.BottomSheet#setResizeKeyboardArea` | 1 | [1] | нет сервиса / честный отказ |
| 163 | `org.telegram.ui.ActionBar.BottomSheet#setUseSmoothKeyboard` | 1 | [1] | нет сервиса / честный отказ |
| 164 | `org.telegram.ui.ActionBar.BottomSheet#setUseSmoothKeyboardTransition` | 1 | [1] | нет сервиса / честный отказ |
| 165 | `org.telegram.ui.ActionBar.Theme#key_chat_messagePanelSend` | 1 | [] | PluginSettingsService |
| 166 | `org.telegram.ui.ActionBar.Theme#key_checkbox` | 1 | [] | PluginSettingsService |
| 167 | `org.telegram.ui.ActionBar.Theme#key_checkboxCheck` | 1 | [] | PluginSettingsService |
| 168 | `org.telegram.ui.ActionBar.Theme#key_checkboxDisabled` | 1 | [] | PluginSettingsService |
| 169 | `org.telegram.ui.ActionBar.Theme#key_dialogRoundCheckBox` | 1 | [] | PluginSettingsService |
| 170 | `org.telegram.ui.ActionBar.Theme#key_dialogRoundCheckBoxCheck` | 1 | [] | PluginSettingsService |
| 171 | `org.telegram.ui.ActionBar.Theme#key_dialogTextGray3` | 1 | [] | PluginSettingsService |
| 172 | `org.telegram.ui.ActionBar.Theme#key_dialogTextHint` | 1 | [] | PluginSettingsService |
| 173 | `org.telegram.ui.ActionBar.Theme#key_listSelector` | 1 | [] | PluginSettingsService |
| 174 | `org.telegram.ui.ActionBar.Theme#key_windowBackgroundWhiteBlueHeader` | 1 | [] | PluginSettingsService |
| 175 | `org.telegram.ui.ActionBar.Theme#multAlpha` | 1 | [2] | нет сервиса / честный отказ |
| 176 | `org.telegram.ui.ChatActivity#getClass` | 1 | [0] | нет сервиса / честный отказ |
| 177 | `org.telegram.ui.Components.BackupImageView#setTag` | 1 | [1] | нет сервиса / честный отказ |
| 178 | `org.telegram.ui.Components.BulletinFactory#of` | 1 | [2] | нет сервиса / честный отказ |
| 179 | `org.telegram.ui.Components.ChatActivityEnterView#getClass` | 1 | [0] | нет сервиса / честный отказ |
| 180 | `org.telegram.ui.Components.CheckBox2#<init>` | 1 | [3] | PluginUIService |
| 181 | `org.telegram.ui.Components.EditTextCaption#getClass` | 1 | [0] | нет сервиса / честный отказ |
| 182 | `org.telegram.ui.Components.Premium.StarParticlesView#flingParticles` | 1 | [1] | нет сервиса / честный отказ |
| 183 | `org.telegram.ui.Components.RLottieImageView#<init>` | 1 | [1] | PluginUIService |
| 184 | `org.telegram.ui.Components.RLottieImageView#playAnimation` | 1 | [0] | нет сервиса / честный отказ |
| 185 | `org.telegram.ui.Components.RLottieImageView#setAnimation` | 1 | [4] | нет сервиса / честный отказ |
| 186 | `org.telegram.ui.Components.RLottieImageView#setBackgroundColor` | 1 | [1] | нет сервиса / честный отказ |
| 187 | `org.telegram.ui.Components.RecyclerListView#OnItemClickListener` | 1 | [] | нет сервиса / честный отказ |
| 188 | `org.telegram.ui.Components.RecyclerListView#OnItemLongClickListener` | 1 | [] | нет сервиса / честный отказ |
| 189 | `org.telegram.ui.Components.SeekBarView#<init>` | 1 | [1] | PluginUIService |
| 190 | `org.telegram.ui.Components.SeekBarView#SeekBarViewDelegate` | 1 | [] | нет сервиса / честный отказ |
| 191 | `org.telegram.ui.Components.UItem#asButton` | 1 | [3] | нет сервиса / честный отказ |
| 192 | `org.telegram.ui.DialogsActivity#<init>` | 1 | [1] | PluginUIService |
| 193 | `org.telegram.ui.DialogsActivity#getClass` | 1 | [0] | нет сервиса / честный отказ |
| 194 | `org.telegram.ui.DialogsActivity#setDelegate` | 1 | [1] | нет сервиса / честный отказ |
| 195 | `org.telegram.ui.LogoutActivity#<init>` | 1 | [0] | PluginUIService |
| 196 | `org.telegram.ui.SettingsActivity$AccountCell$Factory#of` | 1 | [2] | нет сервиса / честный отказ |
| 197 | `org.telegram.ui.Stars.SuperRipple#<init>` | 1 | [1] | PluginUIService |
| 198 | `org.telegram.ui.Stars.SuperRipple#effect` | 1 | [] | нет сервиса / честный отказ |

## Минимум для hello-плагина

Пять точек. Первые четыре — Java-члены из таблицы, пятая — payload настроек, который загрузчик собирает на стороне Python и который экран настроек должен принять. Без любой из них плагин не получает аккаунт, плотность, цвет темы или экран настроек.

### Theme.getColor

`org.telegram.ui.ActionBar.Theme#getColor` — 6 плагинов, арность `[1]`, операция `call`. Сервис: `PluginSettingsService.themeColor(forKey:)`, ответ заглушки — ARGB. Ключ цвета плагин обычно перед этим читает как поле `Theme#key_*` (`get` → `themeKey`, заглушка возвращает само имя ключа).

```json
{"op":"call","fqcn":"org.telegram.ui.ActionBar.Theme","member":"getColor","args":["dialogTextBlack"],"kwargs":{}}
```

### AndroidUtilities.dp

`org.telegram.messenger.AndroidUtilities#dp` — 6 плагинов, арность `[1]`, операция `call`. Сервис: `PluginUIService.dp(_:)`. Если UI-сервис не подставлен, заглушка возвращает 0.

```json
{"op":"call","fqcn":"org.telegram.messenger.AndroidUtilities","member":"dp","args":[16],"kwargs":{}}
```

### UserConfig.selectedAccount

`org.telegram.messenger.UserConfig#selectedAccount` — 3 плагина, арность `[]`, операция `get` (поле, не вызов). Сервис: `PluginMessagesService.selectedAccount()`. Если сервис сообщений не подставлен, заглушка возвращает 0.

```json
{"op":"get","fqcn":"org.telegram.messenger.UserConfig","member":"selectedAccount","args":[],"kwargs":{}}
```

### getInstance

Любой член `getInstance` — операция `call`, сервис `PluginMessagesService.instanceHandle(fqcn:account:)`. Заглушка берёт аккаунт из `args[0]`; если числа нет, подставляет 0 и всё равно регистрирует дескриптор инстанса. Поэтому нулевая арность у `PluginsController` и `LocaleController` на заглушке тоже жива, просто с аккаунтом 0.

Фактические вызовы корпуса:

| класс#член | плагинов | арности |
|---|---|---|
| `app.exteraless.plugins.PluginsController#getInstance` | 5 | [0] |
| `org.telegram.messenger.LocaleController#getInstance` | 4 | [0] |
| `org.telegram.messenger.FileLoader#getInstance` | 3 | [1] |
| `org.telegram.messenger.MediaDataController#getInstance` | 3 | [1] |
| `org.telegram.messenger.MessagesController#getInstance` | 3 | [1] |
| `org.telegram.messenger.UserConfig#getInstance` | 2 | [1] |
| `org.telegram.messenger.AccountInstance#getInstance` | 1 | [1] |
| `org.telegram.messenger.NotificationCenter#getInstance` | 1 | [1] |
| `org.telegram.messenger.SendMessagesHelper#getInstance` | 1 | [1] |

Для hello достаточно пары с аккаунтом: прочитать `selectedAccount`, затем вызвать `MessagesController.getInstance` или `UserConfig.getInstance` с этим числом.

```json
{"op":"call","fqcn":"org.telegram.messenger.MessagesController","member":"getInstance","args":[0],"kwargs":{}}
```

### Payload create_settings

`create_settings` — не Java-член и не операция моста. В корпусе его объявляют **14** плагинов. Это метод `BasePlugin.create_settings()`: список элементов `ui.settings` либо `None`.

Сериализация живёт в загрузчике (`get_settings_json`): на выходе JSON-массив.

* `None` или пустой список → `[]`;
* исключение внутри `create_settings` → один элемент `{"type":"divider","text":"<текст ошибки>"}`;
* неизвестный тип элемента пропускается;
* у каждого записанного элемента есть `type` и `row_id` (sha256 идентичности строки);
* необязательные поля не пишутся, если значения нет: `subtext`, `icon`, `link_alias`, `callback_id`, `long_callback_id`, `max_length`, текст у `divider`.

Форма по типам:

| type | поля |
|---|---|
| `header` | `text` |
| `divider` | `text?` |
| `switch` | `key`, `text`, `value` (bool из хранилища настройки) |
| `selector` | `key`, `text`, `items` (список строк), `value`, `default` |
| `slider` | `key`, `text`, `min`, `max`, `step`, `integral`, `value` |
| `input` | `key`, `text`, `value` (строка) |
| `edittext` | `key`, `hint`, `value`, `multiline`, `max_length?` |
| `text` | `text`, `accent`, `red`, `subtext?`, `icon?`, `sub_page?` |
| `custom` | `view_id`, `sub_page?` |

`sub_page` — такой же массив элементов. `callback_id` / `long_callback_id` — идентификаторы колбэков, которые загрузчик вызывает отдельно; в JSON самих функций нет.

`PluginSettingsService` сейчас содержит только `themeColor` и `themeKey`. Payload настроек — отдельный вход этого же сервиса: протокол его ещё не объявляет, и честный отказ его не заменяет. Минимальный hello-экран:

```json
[
  {"type": "header", "text": "Hello", "row_id": "<sha256>"},
  {"type": "switch", "key": "enabled", "text": "Включено", "value": true, "row_id": "<sha256>"}
]
```
