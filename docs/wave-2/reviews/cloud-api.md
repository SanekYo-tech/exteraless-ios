# Независимое ревью Cloud / Client API — 2026-11-15

**Итог: 4 P1 и 2 P2; P0 не найден. Full Android port / native acceptance пока не закрыт.**
Основные дефекты: расширение restore за пределы preview, обход native-owned
настроек через Tools backup, удаление здоровой истории действием repair и сырые
RPC errors в сетевом логе. Ниже — source findings, не результаты native execution.

## Срез и метод

- Начальный HEAD: `ddc25d69`. Во время ревью HEAD перешёл на
  `f99909b58968b69dfb57132db9dd84d2e28889cc`. В первом срезе scoped diff относительно `ddc25d69`
  для Core `Cloud*.swift`, `ClientAPI*.swift`, `CoreCloudFeatures.swift` и их
  Cloud/ClientAPI tests был пуст. Перед завершением появились dirty refresh/schema
  изменения, перечисленные ниже; их diff и затронутые границы перечитаны.
  Native и общие интеграционные файлы читались из рабочего дерева; C1–C6 продолжал
  применять app-integrator. Anchors и fingerprints относятся к последнему срезу.
- Прочитаны `telegram-ios/AGENTS.md`, `telegram-ios/CLAUDE.md`,
  `docs/wave-2-contract.md`, Cloud/API handoff, legacy remediation и parity receipt.
  Android source tree: `5cc4ad2225889bcd149fa14dc6e447b92a3fc341`
  (`HEAD:third_party/exteraless-android`, именно tree, не отдельный checkout commit).
- Полностью просмотрены **20 Core Cloud/API sources**, **6 Core test/support
  files / 51 XCTest method**, **4 native TelegramCore sources**, **5 Cloud UI/host
  files**, **3 native test files / 4 XCTest method**. Дополнительно прослежены
  ClientSettings CAS/secret storage, AI credential API, Tools archive/restorer,
  lease/schema binding, Account/Network, Root/AppDelegate, share/notification
  bootstrap, native settings/SDK setters и сетевые logging sinks.
- Выполнены только чтение, scoped Git inspection, поиск callsites и Python stdlib
  hashing/counting с timeout 20 s. `swift`/`swiftc` не обнаружены. XCTest, UIKit,
  Keychain, MTProto, CI и реальные аккаунты здесь не запускались. Счётчики и
  authored fixtures не считаются пройденными тестами.
- Сообщённая coordinator ошибка compilation `CloudLegacyRules` →
  `ChatDoubleTapAction` учтена как известная, отдельного finding нет. Новый CI
  после `f99909b5` здесь не запрашивался. Уже применённый AI Android-import
  presence fix прочитан; старый AICF-02 не продублирован.
- Единственный записанный reviewer файл — этот отчёт. Старые reports сохранены.

## Findings

### CA-01 — P1: native restore применяет поля, исключённые из Cloud preview

**Источники:**
`swift/ExteralessCore/Sources/ExteralessCore/CloudArchive.swift:7–20,85–100,160–172`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudArchiveHost.swift:17–25,49–54`;
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupRestore.swift:135–147,234–235`;
`swift/ExteralessCore/Sources/ExteralessCore/PrivacyFeatures.swift:35`.

**Сценарий:** корректный native envelope содержит обычный portable flag и
`privacy.botPrivacyUserId`. Последний зарегистрирован, но явно исключён
`CloudArchivePolicy`. Cloud inspection считает его ignored; preview-CAS проверяет
только `inspection.settings/resetting`. Однако `publicInspection.payload`
сохраняет исходное поле. Native host передаёт этот inspection в Tools, который
повторно строит `checked` из **исходного payload и всех текущих definitions**.
Исключённый user ID становится обычной записью forward CAS.

Если после preview native editor изменил этот ID, Tools снимает новый before-image
уже с этой правкой и успешно заменяет её imported значением: Cloud preview-CAS
данный key вообще не охватывает. В результате меняется account-routing preference,
которую preview обещал пропустить. `CloudSettingsArchive.apply` в Core tests
использует отфильтрованный inspection напрямую и этого native расхождения не имеет.

**Исправление:** передавать Tools ограниченный публичный payload, содержащий ровно
проверенные Cloud keys и их presence metadata; повторная schema validation не
должна расширять admitted write set. Preview-CAS и forward CAS должны охватывать
один и тот же набор. Отдельные credential metadata сохранить внутри Cloud plan.

**Regression:** tiny envelope с portable flag и исключённым bot-user-ID, затем
изменение ID после preview. Прогнать настоящий `ToolsBackupRestorer` через native
host binding: разрешённое поле применено, ignored field и его override presence
сохранены; отображаемые counts соответствуют фактическим writes.

### CA-02 — P1: обычный Tools backup обходит native API tuple и key-inclusion ownership

**Источники:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupArchive.swift:177–197,303–322`;
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupRestore.swift:139–147,234–235`;
`swift/ExteralessCore/Sources/ExteralessCore/ClientAPISettings.swift:46–62,85–95`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudAutoSync.swift:57–101`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift:47–58,77–87`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Tools/ExteralessBackupController.swift:37–52,66–95`.

**Сценарий API:** на устройстве есть сохранённая custom пара ID_A/hash_A. Обычный
Tools archive от другой конфигурации содержит `clientAPI.customApi = 3` и ID_B;
hash правильно исключён как secret. Import принимает оба public fields и оставляет
hash_A в Keychain. Он не создаёт pending draft и не вызывает native tuple editor.
При следующем запуске `selection` принимает ID_B/hash_A: проверяются форма hash и
постоянство public ID/mode, но принадлежность hash этому ID не установлена.
Новый account record получает постоянный pin этой смешанной пары. Existing pins
сохраняются, но новый login начинает сеть и auth с несогласованной identity.

**Сценарий Cloud:** тот же обычный archive может содержать
`cloud.autoSync = true` и `cloud.includeApiKeys = true`. Restore меняет их как
обычные public preferences; активный scheduler затем экспортирует локальные
service keys. Отдельного native выбора включения ключей не происходило.
Это достижимо и через обычный экспорт такого состояния, без подделки hash/checksum.

Применённый C6 запрещает эти mutations в SDK и API fields в generic editor, но
его защита не распространяется на уже существующий native Tools restore.

**Исправление:** исключить native-managed API identity/pins и key-inclusion
permission из general backup writes, включая старые входные archives. Изменение
API draft должно проходить согласованный native tuple transaction; import других
настроек не должен изменять разрешение на экспорт локальных keys.

**Regression:** два fake credential stores с разными парами; Tools export/import
должен сохранить локальный draft tuple и pins. Archive с двумя Cloud flags не
должен включить key export; проверить отсутствие credential reads и remote writes
при исходном opt-out. Проверять реальный Tools apply, не только SDK permission guard.

### CA-03 — P1: repair удаляет здоровые backups вместе с повреждённым manifest

**Источники:**
`swift/ExteralessCore/Sources/ExteralessCore/CloudRemoteStore.swift:23–49,163–185`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudController.swift:79–83,199–206`.

**Сценарий:** namespace содержит полностью исправную revision H с её chunks и
дополнительный malformed `neko_ios_v1.r.*` record. `catalog()` бросает
`.malformedRemote`. Repair перехватывает это как разрешение на удаление,
повторно перечисляет **все** keys с native prefix и удаляет также H.
Проверка `current.revisions.isEmpty` выполняется только при успешном catalog;
именно в повреждённом случае она обходится.

UI предлагает «Remove incomplete native backup data» и прямо утверждает, что
healthy history не eligible. Реальное действие уничтожает last good backup.
Дополнительное окно: здоровая revision, опубликованная другим устройством между
неудачным catalog и вторым `keys()`, тоже попадает в deletion без acknowledgement.
Сохранённая локальная last-success date потерянный remote payload не восстанавливает.

**Исправление:** удалять только доказанно повреждённые/uncommitted records из
проверенного captured набора; не расширять его вторым listing. Здоровые revisions
и необходимые им chunks/parents сохранять; неоднозначное состояние отклонять.

**Regression:** in-memory transport с одной здоровой revision и одним malformed
manifest. Repair должен сохранить полный byte-identical healthy backup. Второй
fixture публикует новую revision между двумя reads: её keys удаляться не должны.
Текущий `CloudRemoteTests.testCycleMissingParentAndFutureSchemaCannotBeMistakenForEmptyCloud`
проверяет repair только без независимой здоровой истории.

### CA-04 — P1: raw RPC error text попадает в log до Cloud redaction

**Источники:**
`telegram-ios/submodules/TelegramCore/Sources/ExteralessCloud/ExteralessCloudTransport.swift:103–127`;
`telegram-ios/submodules/TelegramCore/Sources/Network/MtProtoKitEngine.swift:415–420,445–450`;
`telegram-ios/submodules/MtProtoKit/Sources/MTRequestMessageService.m:819–850`;
`telegram-ios/submodules/MTProtoRustEngine/Sources/MTProtoRustEngine/RustNetworkSession.swift:940–976`;
`telegram-ios/submodules/TelegramCore/Sources/Utils/Log.swift:284–314,379–385`.

**Сценарий:** credential-bearing Cloud RPC возвращает `rpc_error`, текст которого
содержит submitted value. На MtProtoKit строка 850 логирует
`rpcError.errorDescription`; Rust делает то же с `event.text` на строке 953.
Это происходит **до** completion, где Cloud заменяет failure на `.network`.
Name-only request metadata и `ExteralessCloudReply` защищают другие пути.

`Logger.log` печатает/записывает полученную строку без content redaction; значение
`redactSensitiveData = true` этот sink не меняет. Поэтому при включённом network
logging error text может сохранить credential в plaintext log, хотя UI показывает
правильную фиксированную ошибку. Сценарий подтверждён call chain; реальный ответ
бота или native logging fixture здесь не исполнялся.

**Исправление:** пронести privacy classification credential-bearing requests до
обоих engine logging boundaries и исключить raw error text до форматирования.
Оставить method/code и фиксированную безопасную категорию. Тот же контракт нужен
hash-bearing auth methods; C5 metadata helper один эту ветку не закрывает.

**Regression:** canned RPC error с synthetic sentinel через оба native engine
logging paths при redaction on/off. Sentinel отсутствует во всех captured logs и
UI errors; code/method остаются. Не ограничиваться тестом `FunctionDescription`.

### CA-05 — P2: native key-enabled backup теряет Cloudflare account destination

**Источники:**
`swift/ExteralessCore/Sources/ExteralessCore/CloudArchive.swift:7–9,23–32,132–138`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudCredentials.swift:6–17,81–105`;
`swift/ExteralessCore/Sources/ExteralessCore/AITranscription.swift:62–82,106–115`;
Android `third_party/exteraless-android/TMessagesProj/src/main/java/tw/nekomimi/nekogram/helpers/SettingsBackupHelper.java:132–135,150–169`.

**Сценарий:** работающее Workers AI transcription, Include service API keys on,
native backup → восстановление на чистой конфигурации. Token экспортируется как
`.translation(.cloudflareAudio)`, но `ai.transcribeProviderCfAccountID` исключён
из portable snapshot **безусловно**, в том числе при include=true. В credential
entry account ID также отсутствует. Restore может сообщить успешное добавление
ключа, но explicit Workers AI падает на account-ID validation; Auto выбирает
другого provider/Apple. При уже заполненном target ID получается другая destination.

Android включает эту `AccountID` preference при include=true; legacy iOS importer
тоже уже имеет её conditional rule. Дефект относится к native Cloud round-trip.

**Исправление:** переносить проверенную account metadata вместе с opt-in
Cloudflare credential и captured destination; при opt-out по-прежнему исключать.
Restore/preview должны описывать и применять согласованную пару.

**Regression:** native prepare → inspect → restore на empty fake store;
построить request без отправки и сравнить account path/provider с исходным.
Отдельно include=false: account metadata и token отсутствуют, secure reads — ноль.

### CA-06 — P2: отменённый queued native writer всё равно меняет настройки

**Источники:**
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudUI.swift:53–78,84–102`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudController.swift:125–129`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessClientAPIController.swift:116–123`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudIntegration.swift:89–98`.

**Сценарий:** native toggle ставит работу через `run`; в том же MainActor turn
account context заменяется и `clearCloudContext` отменяет `work`. Когда уже
cancelled Task получает исполнение, он всё равно сначала вызывает `operation()`:
проверки context/generation/cancellation стоят только **после** await. `setFlag`
создаёт новый `Task.detached`, который не наследует эту cancellation и без
admission check вызывает `settings.applyPublic`. API draft save имеет тот же путь.

Результат для старого экрана подавляется, но глобальная Cloud preference/API draft
уже изменена после retirement. Для cancellable flag это также возможно после
кнопки Cancel. Это отдельный путь от `CloudSyncSession` generation guards и от
разрешённого завершения уже admitted journal commit.

**Исправление:** проверять context/generation/cancellation до вызова operation и
перед фактическим queued writer; передавать native admission token в detached
работу. После начала атомарного commit завершать его согласованно, не выдавая
предварительно отменённую работу за admitted transaction.

**Regression:** bounded native fixture ставит toggle/API save в очередь, затем
retire/cancel до входа в writer и освобождает barrier. Значения, Keychain bytes и
observer notifications не меняются. Control: уже admitted commit завершается один раз.

## Независимая сверка Android → Swift

Основной original prefix ниже:
`third_party/exteraless-android/TMessagesProj/src/main/java/`.

| Original ID / реальный источник | Проверенный native контракт |
|---|---|
| `cloudsettingshelper.autoSync`, `CloudSettingsHelper.java:59,290–303` | Default false, 1200 ms debounce сохранены. `CloudAutoSync` использует actual settings observation, foreground и captured session; отдельного failure polling нет. |
| `cloudsettingshelper.includeApiKeys`, `CloudSettingsHelper.java:60,300`; `SettingsBackupHelper.java:132–169` | Default false; typed service whitelist вместо Android suffix filter. Native bound strings сохраняются целиком, импорт add-only. CA-02/04/05 остаются открытыми. |
| `cloudsettingshelper.localSyncedDate`, `CloudSettingsHelper.java:58,311–318,374–376` | Default -1; вместо global preference — account/user/environment-scoped state. `CloudSyncSession` записывает receipt после успешного remote readback либо завершённого restore/key phase. |
| `nekox.customApi`, `NekoXConfig.java:40–62,199–212` | 0 / 3 и restart policy сохранены; iOS намеренно оставляет existing/in-progress account pins. Отключение сохраняет draft. |
| `nekox.customAppId`, `NekoXConfig.java:45–50,147–184`; `ConnectionsManager.java:293` | Positive Int32, supplied BuildConfig для built-in; actual `NetworkInitializationArguments` → `MTApiEnvironment.apiId`. General backup bypass — CA-02. |
| `nekox.customAppHash`, `NekoXConfig.java:47,53–62,177–184`; `PasskeysController.java:190–193`, `LoginActivity.java:3249–3250,8573–8574` | Fresh Keychain read и opaque native tuple; 32 hex строже Android length-only. Hash отсутствует в Cloud/Tools public payload; draft и pins имеют разные обязанности. |

Дополнительно прочитаны `OpenExteraCloudActivity.java` (actions/confirmations/state),
`CloudStorageHelper.java` целиком, `app/exteraless/ai/AiConfig.java`,
`app/exteraless/ai/data/Service.java`, enum tables в
`tw/nekomimi/nekogram/translate/Translator.kt` и `llm/preset/PresetRegistry.kt`,
соответствующие declarations в `src/main/kotlin/xyz/nextalone/nagram/NaConfig.kt`.

- Protocol действительно тот же account-owned `bots.invokeWebViewCustomMethod`:
  четыре original custom methods, bot identity проверяется по ID/bot flag.
  Android `neko_settings[_N]` читается отдельно; native revisions имеют другой
  namespace. Gzip/Base64 не названы payload encryption; UI сообщает отсутствие E2E.
- `CloudLegacyCatalog` — source-name index, `CloudLegacyRules` — отдельное
  разрешение на запись. Typed suffix/enum conversion, Java legacy service hash,
  selected-ID → hash → first precedence сопоставлены с original code. Legacy
  services являются JSON **string**; публичный выход закрыт native service schema.
- Legacy apply — overlay только supplied mapped fields. Native v2 использует
  `clientStoredKeys`: absence восстанавливается reset к текущему default,
  explicit default остаётся override. `ai.services` заменяется как единое поле,
  не объединяется с unrelated service array; это соответствует original
  SharedPreferences string replacement. Existing credential items остаются add-only.
- Index/rule counts и dispositions не доказывают перенос всех Android preferences.
  Stock `mainconfig`/`userconfing`, unsupported numeric/resource/per-account fields
  реально остаются skipped. Для full migration parity необходимы их отдельные
  native adapters; шесть Cloud/API inventory records нельзя объявить full port
  только по наличию большого mapping catalog.

## Проверенные защитные механизмы и границы доказательства

- `CloudAICredentialBridge.swift:7–45` использует настоящие
  `AICredentialDestination` / `AICredentialBinding`: setting identity,
  scheme/host/effective port/base path/protocol. Export возвращает **всю** строку
  `exteraless.ai-credential.v1\n…`, не извлечённый key. Restore сохраняет её
  посредством `SecItemAdd`; другой/current local item не заменяется. Public URL
  не ребиндит старый credential; Android inline key связывается только с metadata
  своего preview. Raw native legacy value остаётся unbound.
- `AISettings.swift:200–228` в прочитанном срезе уже использует reset для empty
  imported key и сохраняет prior presence при rollback. Это устраняет прежнюю
  причину пустого Keychain item, блокировавшего add-only Cloud insert.
- Include=false в `CloudCredentials.export` возвращает до любого secure read.
  Cloud credential enum не допускает Telegram App hash/auth/session/passcode/
  arbitrary Keychain services. Secret phase не попадает в Tools public journal.
- Cloud bounds: payload 1 MiB, reply 256 KiB, 256 chunks, 1024 keys, 128 revisions,
  до 8 merge parents; chunks 3000 chars, batches до 50 (legacy plain — 16).
  JSON preflight ограничивает nesting/separators до Foundation decode. Native
  `MTGzip.m:43–73` проверяет output ceiling до append очередных 16 KiB. Это
  gzip и JSON/Base64 Tools envelope, не ZIP extraction. `getStorageKeys` не имеет
  pagination protocol; его полный ответ ограничен, остальные reads пакетные.
- Legacy double chunk read + metadata bookends и fingerprint обоих компонентов
  обнаруживают mixed generation и same-timestamp payload change. Публичные
  timestamps не используются как ETag или право присвоить backup другому account.
- `CloudRemoteStore.publish:55–94` не удаляет предыдущие revisions при failed
  chunk/readback/conflict; новые immutable records сохраняют concurrent forks.
  `CloudSyncSession:85–102` не принимает новые heads автоматически после failure.
  RPC failure, включая code 409, идёт в native `.network` без retry loop и до
  state-success write. Это source trace, **не выполненный 409 test**. Original
  service не предоставляет server CAS; final-read race сохраняет обе revisions.
  CA-03 — отдельное destructive repair исключение из сохранности истории.
- Cloud host получает реальный общий Tools lease, затем `admission.beginCommit`,
  journalled public transaction и add-only key phase. Partial key failure не
  сообщает полный restore success. Finish outcomes — committed / rolledBack /
  needsRecovery; Cloud не создаёт другой Host или plugin journal. Plugin payload
  запрещён при Cloud inspection; schema/location getters используются data-only.
  Защита набора публичных writes ограничена CA-01.
- `ClientAPILaunchResolver:28–57` сначала использует durable pin/marker; missing
  бывший pin — error, не built-in fallback. Atomic `SecItemAdd` возвращает winner.
  Production/test и record ID входят в namespace. Уже admitted in-memory tuple
  переживает недоступность Keychain. Нет замены identity по public URL или новому
  global draft у уже созданного account network.

## C1–C6 / native gates

Во время ревью интеграция изменилась: ниже **уже найденный source**, а не список
якобы отсутствующих hunks. Итоговый интеграционный gate остаётся открытым до
frozen handoff app-integrator, исправления findings и native проверки.

| Hunk | Реально прочитанный consumer |
|---|---|
| C1 | `ExteralessClientRuntime.swift`: Cloud/API definitions, retained Cloud integration, clear на context identity replacement; один `toolsBackupBindings(context:)` передаётся Tools и Cloud. `AppDelegate.swift:1590–1597` вызывает bind после обоих runtime updates. |
| C2 | Main async preparation стоит перед `clientSettingsReady` / account factory (`AppDelegate.swift:1291–1313,1984–2018`). Main, Share, NotificationService, NotificationContent и Siri берут pin access group из `PasscodeEnvironment.shared.sharedAccessGroup()` и supplied BuildConfig. Settings-secret reader соответствует existing `ClientSettings` system backend. |
| C3 | `Account.swift:469–530,2000–2040`: environment из actual Authorized/Unauthorized state; все три initial networks и standalone используют resolved arguments. Catch не вызывает initializedNetwork с другой парой. DC change использует `self.networkArguments` (`:369–388`). |
| C4 | `AppDelegate.swift:1560` передаёт UnauthorizedApplicationContext `account.networkArguments`; `AuthTransfer.swift:24` также использует account tuple. |
| C5 | Оба Network builders и оба TL transform gates исключают identity methods. Все шесть `api_hash` methods текущего `swift_scheme.tl` есть в policy. CA-04 касается нижележащего error logging. |
| C6 | Generic settings скрывает `clientAPI.*`; SDK single и batch setters запрещают API fields и `cloud.includeApiKeys`. CA-02 показывает конфликт с отдельным backup writer. |

**Оставшееся доказательство:** actual entitled shared Keychain round-trip между
app/share/notifications, locked/missing pin failure без fallback network,
production/test separation, actual native factory/lease/action-boundary fixtures.
Source одинакового group selector не является проверкой подписанного entitlement.
В финальной сверке `CloudLegacyTransportTests.swift` уже добавлен в native BUILD;
исполнение этих tests этим не установлено.

**Поздняя dirty delta:** `CloudArchive.swift:114–129` добавил
`readLatestSnapshot` с cancellable full `ClientSettings.reload`; sync и оба новых
preview теперь вызывают его. `CloudAutoSync.swift:68–70` отсекает error-only
invalidation, чтобы failed reload сам не создавал retry polling. Изменённый
`CloudLegacyImportTests` проверяет новый preview после external presence edits;
подтверждённый старый plan не переснимает свой expected image. Нулевые Keychain
reads выше установлены для `CloudCredentials.export(includeApiKeys: false)`;
полный новый session preparation включает reload secure backend.

Tools добавил `ToolsPluginSchemaEvidence` / `ToolsPluginSchemaValidity` и проверки
current source/settings/schema evidence при непустом plugin file set. Cloud
использует пустой plugin payload; переинспекция client payload по всем definitions
и отсутствие managed-key exclusion сохранились. Эти изменения **не устраняют
CA-01…06**. Их полный Host/native execution остаётся отдельным gate.

Последняя Account delta добавила retention bootstrap/readiness prerequisite
перед account publication/standalone network. API resolution и fail-closed catch
перечитаны на новых строках C3: pinned arguments сохранены. Обеспечение этого
нового prerequisite во всех процессах относится к ещё активной Root/retention
стыковке, не к отдельному Cloud/API finding.

**Visual gate:** recorded frames по AGENTS для Cloud/API screens, light/dark,
large text/RTL, secure empty hash editor, keyboard, busy/cancel/error, account
replacement при confirmation и нескольких revisions. Ожидаются читаемые counts,
стабильные rows, отсутствие late confirmation/action старого context и корректная
дата после failure. Кадров нет; визуальных defects/pass этот отчёт не утверждает.

## Source fingerprints

Aggregate = SHA-256 от UTF-8 concatenation
`relative-posix-path + NUL + lowercase-SHA256(file-bytes) + LF`, sorted по path.

| Группа | SHA-256 |
|---|---|
| Core sources: `Cloud*.swift`, `ClientAPI*.swift`, `CoreCloudFeatures.swift` (20) | `2f6ff30a02989bdbdb9a3884bd4ebbbdbc33d8bc9d4f9dc14103ef0bca57eb50` |
| Core tests/support: `Cloud*.swift`, `ClientAPI*.swift` (6) | `28ce72bcec1cc8c35e8738a2bd8edf5778c01635a0855b02ed761feaeae0f4a9` |
| `TelegramCore/Sources/ExteralessCloud` + `ExteralessClientAPI` (4) | `b0b9adfb3cdf9887c169c3a04fc7cfc056ed019ed53e0b3de5156e66b3653b8e` |
| `TelegramUI/Sources/ExteralessClient/Cloud` (5) | `aad71dc0be49b86242b3b4456451e328730433223b5ff3bd36341a0c4bc7da65` |
| Native `CloudTransportTests`, `CloudLegacyTransportTests`, `ClientAPIRequestMetadataTests` (3) | `091975391b4d87e51dc95b765be542554b0cefca65a32cec94d09defef12fb9d` |

Значимые shared dependencies, individual SHA-256:

| Файл | SHA-256 |
|---|---|
| `swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupArchive.swift` | `780c33fa0dd3e97b648b42a119f3b02fae79e9e8e3ae8eefb871f29f6740ffc6` |
| `swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupRestore.swift` | `1041098ebfef838ad9ef3963469496e77d011756b95b98d6983f030f47dd89a0` |
| `swift/ExteralessCore/Sources/ExteralessCore/AISettings.swift` | `4d695461bed8e8cb41d64ecbef12b9732008a18c80b9b319fbc1ff5487a2401a` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift` | `3932eb6e302b5824b3dd871b9d164ff8876d9c660b93908a756752bf78932c2e` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift` | `e0600d7492f6e9a478341235ff451147fc0e41fe2908d0925af50e9d14897717` |
| `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift` | `5cf2957f70f57117730998a038716e4204ffae9c0e0bd88bc750cd7c39314632` |
| `telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift` | `62dd8ded54d5aa6a67a25781df003a0580c8965e052e6bf7d23e5fdbc1b079c3` |
| `telegram-ios/submodules/MtProtoKit/Sources/MTRequestMessageService.m` | `bc251e5fdb4af3c9d87f334d296862ca7aa5727acd16e213f6edb7b7885550be` |
| `telegram-ios/submodules/MTProtoRustEngine/Sources/MTProtoRustEngine/RustNetworkSession.swift` | `2689e49671443713eb3aaa670010c56cfb4d6d33c3bf0f1d5d6272261fd960fc` |
