# Cloud / Client API — focused follow-up CA-01…06

Дата: 2026-11-15. **CA-01/02/03/06 закрыты по source review. CA-04/05 остаются
частично открытыми: 1 P1 и 2 P2 ниже.** Native execution и recorded frames pending.

| ID | Статус | Результат проверки контрпримера |
|---|---|---|
| CA-01 | **Source-closed** | Native host передаёт точную проекцию; Tools replay не добавляет ignored/newly registered keys и не превращает setters в resets. |
| CA-02 | **Source-closed** | Export, old-input inspection, admitted projection и canonical legacy destinations исключают `clientAPI.*` и local `cloud.includeApiKeys`. |
| CA-03 | **Source-closed** | Healthy + malformed сохраняет healthy bytes; новый revision на повторном listing отклоняет repair без расширения deletion set. |
| CA-04 | **Partial — CAF-01, P1** | Redaction и ранний Rust callback подключены, raw retry/completion semantics сохранены. Остался несовместимый тип metadata helper в трёх native builders. |
| CA-05 | **Partial — CAF-02/03, P2** | Empty-store round-trip, неизменённая existing pair и появление токена после preview обработаны. Удаление токена после preview и native restore при local opt-out обработаны неверно. |
| CA-06 | **Source-closed** | Есть проверка до operation и revocable admission непосредственно перед detached writer; retirement с тем же record ID не переиспользует identity. |

`Source-closed` означает устранение проверенного counterexample в реализации и
содержательные fixture assertions. Это не native build/run, Keychain entitlement
proof или visual acceptance. PFR startup/archive-readiness остаётся отдельной
текущей стыковкой и не использован как причина CA reopen.

## Срез и evidence

- HEAD при чтении: `93a1badcb0ef414ca5218cf938e3b8e2be47a828`.
  Прочитаны `cloud-review-remediation.md`, `tools-remediation.md` с hard admitted
  sets и `network-error-redaction-remediation.md`, затем actual source/callers.
  Правила ранее прочитанных `telegram-ios/AGENTS.md` / `CLAUDE.md` соблюдены.
- По сообщению пользователя: **595 Core / 174 Host / 30 Hooks** passed на
  `43711634580 / 9c409eb8`; `43712394860 / 93a1badc` также green, точные counts
  последнего run здесь не установлены. CI не запрашивался и не запускался.
- Scoped comparison относительно `9c409eb8` для Cloud/ClientAPI, трёх focused
  Core test files и Tools archive показал только текущую дополнительную правку
  `ToolsBackupRestore.swift`. Его CA admission/revalidate callsite перечитан;
  отдельные TBF cleanup tails этим follow-up не принимаются.
- Прочитаны **17 focused Core XCTest methods**: `CloudReviewRemediationTests` — 9,
  `CloudWriteAdmissionTests` — 4, `ToolsAdmittedProjectionTests` — 4;
  **6 native methods**: `NetworkCredentialLogTests` — 4, `RustCredentialLogTests` — 2.
  Локального Swift/ObjC/UIKit исполнения не было; реальные RPC/accounts/Keychain
  не использовались. Новых implementation/test files reviewer не создавал.
- Выполнен проверенный read-only checker:
  `python -B docs/wave-2/tests/network_error_redaction_source_fixtures.py`:
  **6 source checks OK, 0.009 s**, shell timeout 30 s. Он проверяет postimages,
  constructor IDs и frozen Rust pins; type-check и native formatter execution
  этим не подтверждаются. Остальные команды — чтение/Git/hash с timeout ≤20 s.
- Старый `docs/wave-2/reviews/cloud-api.md` read-only; его SHA-256:
  `1878ed62789a6eef275abc6326b59a0fa04864b89bd96e3844679c720f2ea354`.

## Остаточные findings

### CAF-01 — P1 / CA-04: metadata helper возвращает `Any` в protocol-typed initializer

**Места:**
`telegram-ios/submodules/TelegramCore/Sources/ExteralessClientAPI/ExteralessClientAPIRequestPolicy.swift:17–19`;
`telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift:63–69,1423–1427,1504–1508`;
`telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift:324–328`.

Фактические сигнатуры:

```swift
exteralessClientAPIRequestLogMetadata(...) -> Any
WrappedRequestMetadata.init(metadata: CustomStringConvertible, ...)
```

**Repro:** type-check любого из трёх указанных builders. Все передают результат
helper непосредственно в `metadata:`. `Any` не конвертируется неявно в
`any CustomStringConvertible`; наличие `String`/`WrappedFunctionDescription`
внутри runtime value этого не исправляет. Перегрузки initializer для `Any` нет.

**Impact:** native TelegramCore source не проходит эту границу компиляции; до
проверки исправленного request/logging pipeline на Apple target дойти нельзя.
Вывод основан на текущих сигнатурах, не на полученном здесь compiler log.

**Fix:** сохранить protocol type в результате helper — обе его ветки уже
возвращают `CustomStringConvertible`. Не менять classification/raw RPC value
ради устранения type erasure.

**Regression:** native compile всего потребителя плюс construction
`WrappedRequestMetadata` через именно этот helper для protected и ordinary
descriptors. Затем шесть native redaction fixtures. Текущие fixtures создают
metadata из sentinel/`WrappedFunctionDescription` напрямую и сигнатуру helper
не проверяют; source checker также её не сопоставляет.

### CAF-02 — P2 / CA-05: удалённый после preview токен заменяется incoming токеном для другого account

**Места:**
`swift/ExteralessCore/Sources/ExteralessCore/CloudCloudflareMetadata.swift:32–60`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudArchive.swift:167–181,187–223`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudCredentials.swift:163–171`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudLegacySettingsArchive.swift:203–244`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudArchiveHost.swift:20–27,34–41`.

**Repro (малые synthetic stores, без HTTP):**

1. Backup содержит CF pair **A/token_A**; target имеет **B/token_B**, где A ≠ B.
2. Создать preview. Из-за existing token `publicInspection` правильно исключает
   запись account ID, но incoming CF credential остаётся в envelope/plan.
3. После preview выполнить native `target.reset("ai.transcribeProviderCfApiToken")`,
   сохранив account B. Это отдельная разрешённая native операция; generic Reset
   вызывает `settings.reset(key)` в `ExteralessSettingsController.swift:361`.
4. Restore с include=true. `verifyTarget` сразу возвращает: account field в
   inspection отсутствует. Public CAS также не охватывает этот CF account.
   Key phase вызывает `insertIfAbsent` и успешно вставляет token_A.

**Source trace result:** target становится **B/token_A**, результат считает один
added credential. `AITranscription.swift:65–66,109–114` строит request к account B
с token_A. Это несогласованная destination pair; ошибка не требует узкого окна
между Keychain read и write. Native host и legacy apply имеют тот же путь.

**Fix:** зафиксировать в плане CF pair admission/add-versus-retain и проверять его
до фактического credential insertion. Изменение presence после preview требует
нового preview; incoming token не должен вставляться, если его destination pair
не была допущена. Сохранить add-only защиту независимо изменённых credentials.

**Regression:** дополнить `testCloudflareOptOutAndExistingTargetPairArePreserved`
удалением target token после inspect; actual restore не должен получить B/token_A
или сообщить successful CF insertion. Проверить native host hook и legacy path.
Существующий `testCloudflareCredentialAppearingAfterPreviewRejectsAccountWrite`
покрывает противоположное изменение presence — absent → present.

### CAF-03 — P2 / CA-05: local opt-out блокирует весь native restore CF-bearing backup

**Места:**
`swift/ExteralessCore/Sources/ExteralessCore/CloudArchive.swift:158–169,190–194`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudCloudflareMetadata.swift:39–46,57–60`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudSyncSession.swift:140–155`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudController.swift:85–92`.

**Repro:** native backup с обычным portable flag и CF pair; target без CF token,
local `cloud.includeApiKeys = false`. Сделать новый preview и Restore без изменения
настроек между ними. Inspection безусловно использует CF entry из envelope и
допускает account-ID write, даже при local opt-out. Session передаёт include=false;
`verifyTarget` бросает `.settingsChanged` до public commit.

**Impact:** нельзя восстановить обычные публичные настройки из такого backup с
выключенным импортом ключей. Экран при этом обещает, что service keys просто не
будут восстановлены. Ошибка «settings changed» возникает и у совершенно свежего
preview. Legacy inspect с include=false этот дефект не имеет.

**Fix:** согласовать CF public projection с выбранным credential intent: при
opt-out исключать CF pair из apply, сохраняя остальные admitted fields/presence и
локальное разрешение. Counts должны отражать фактически применяемую проекцию.

**Regression:** prepare(include=true) → native inspect на empty target с local
include=false → actual restore. Portable flag применён; CF account/token и local
include permission не изменены; credential I/O отсутствует в optional key phase.
Имеющийся opt-out fixture проверяет **export(include=false)**, а не этот restore.

## Почему остальные исходные сценарии закрыты по source

### CA-01 / CA-02 — hard admitted sets на обоих уровнях

- `CloudPublicRestoreProjection.swift:6–32` строит payload из
  `settings ∪ resetting`, сохраняет `clientStoredKeys = settings.keys` и проверяет
  public payload/values/presence перед native maintenance
  (`ExteralessCloudArchiveHost.swift:48–62`). Credential metadata хранится отдельно.
- `ToolsBackupInspection.admittedPayload` (`ToolsBackupArchive.swift:40–51`)
  использует подтверждённые setters/resets, не raw ignored payload.
  `revalidate:272–285` проверяет три subset-инварианта: keys, setters и resets.
  Actual restorer вызывает его на `ToolsBackupRestore.swift:143` и применяет
  только `checked` на `:255–256`. Include-plugins-off в native Tools UI тоже
  сначала делает admitted projection (`ExteralessBackupController.swift:66–82`).
- `ToolsBackupPolicy.isPortableClientKey:107–112` запрещает весь case-normalized
  API namespace и local includeKeys permission. Он применяется в export `:211`,
  new encoding `:266`, old-input inspection `:350`, admitted projection `:46–47`
  и после canonical legacy resolution `:629,646–648`. Setters и resets запрещённых
  keys не доходят до journal forward write. API Keychain в этом пути не участвует.
- `CloudReviewRemediationTests:45–68` проверяет реальный Tools restorer с excluded
  bot ID, поздней правкой и reset presence; `ToolsAdmittedProjectionTests:25–119`
  добавляет newly registered field, v1/v2 input, local ID/hash bytes, zero secure
  calls, local permission и canonical alias. Это смысловые counterexample fixtures.

### CA-03 — repair больше не получает authority на весь namespace

- `CloudRepairPlan.swift:18–65` защищает valid records и требует полный valid
  parent graph; malformed required parent/цикл/foreign/future/unknown grammar
  отклоняются. Unknown orphans не получают abandoned authority от одного listing.
  Local failed uploader отмечается только до начала manifest publication
  (`CloudRemoteStore.swift:72–78,97–98`).
- `deleteDamagedNativeData:173–187` удаляет только первоначальный `plan.keys`.
  Перед каждым batch сравнивает полный captured native key/byte snapshot с ожидаемым
  остатком; второй listing может отклонить работу, но не добавить targets.
  `CloudSyncSession.swift:235–242` сохраняет accepted heads и last-success receipt.
- Fixtures `CloudReviewRemediationTests:71–141` сохраняют byte-identical healthy
  backup, новую revision на second listing с zero removals, required parent и
  unknown orphan. Original protocol всё ещё без conditional delete/CAS: это
  captured-set conflict detection, а не server lock.

### CA-04 — redaction logic и raw semantics, кроме CAF-01 wiring

- `MTRequestLogContext.m:18–60` сопоставляет семь canonical constructors/exact names;
  known payload нельзя downgrade supplied name. Контекст immutable/interned;
  `:67–79` возвращает fixed method/category до description evaluation независимо
  от generic redaction flag.
- Context проходит `NetworkEngineRequest` (`NetworkEngine.swift:117–165`), shipping
  `mtProtoKitRequestForEngineRequest` (`MtProtoKitEngine.swift:332–339`) и
  monotonic payload replacement (`MTRequest.m:96–108`). Оба Network builders
  передают classification; TL builder merge сохраняет original/final protection
  (`TLNetworkRequest.swift:324–328`).
- MtProtoKit add/outgoing/handover используют metadataForLogging; response/error
  sink вызывает formatter до raw error branch (`MTRequestMessageService.m:88–94,
  143,660,852–854,1348`). APNs/reCAPTCHA decorator descriptions fixed-redacted
  (`:538–560`), serialized values сохраняются.
- Rust failed/retry/worker-401/auth/soft-reset используют `RustRequestLog.failure`;
  unattributed event получает redacted context. Frozen Rust действительно формирует
  freeform error trace **до** structured events (`session_runtime.rs:2232–2244`).
  Actual Swift callback `RustEngineRuntime.swift:122–135` не декодирует message:
  оба Logger sinks получают только `nativeEngineMessage(level:)`.
- Raw `rpcError` остаётся в MtProtoKit flood/auth branches и completion
  (`:869–1083`). Rust использует исходные `event.text/text2` для decisions и
  native error (`RustNetworkSession.swift:940–992`). `NetworkEngine.swift:170–203`
  меняет только telemetry copy и failure description; retry closure получает
  исходный context, completion — тот же `MTRpcError` instance. Шесть native tests
  содержат both-flags, description-counter и raw-error-identity assertions.

### CA-05 — подтверждённая часть

`CloudCredentialEntry.cloudflareAccountID` переносит source ID только с CF token;
general portable snapshot его не включает (`CloudCredentials.swift:48–60,87–100`).
`sourceMetadata` проверяет source consistency; absent-token target допускает только
empty/matching destination, existing token сохраняет account field, реальный
secure read до public commit отвергает newly added token (`CloudCloudflareMetadata.swift`).
`CloudReviewRemediationTests:144–220` строит actual transcription request без HTTP
для empty round-trip и проверяет existing/mismatched/added-token cases. CAF-02/03
покрывают отсутствующие branches, не отменяют эти исправленные сценарии.

Whole `exteraless.ai-credential.v1\n` string для assistant/custom-LLM/audio остаётся
неизменённым: `CloudAICredentialBridge.swift:7–14` возвращает raw protected value,
а не извлечённый key; `CloudCredentials.swift:167` записывает именно это значение.

### CA-06 — до operation и до writer

- `ExteralessCloudUI.swift:82–88` проверяет cancellation, actual context identity,
  availability и generation **до** `operation(admission)`.
- `runWriter:59–64` доводит token до `CloudWriteAdmission.perform:49–57`; handler
  cancellation установлен до detached Task. `withAdmittedWrite:33–46` под lock
  допускает ровно один writer. Revoke выигрывает до admission; после admission
  complete writer завершается без удержания lock/MainActor ожидания.
- Cancel/clear/deinit revoke token (`ExteralessCloudUI.swift:34,112–130`). Actual
  flag writer (`ExteralessCloudController.swift:125–129`) и API registration/save
  (`ExteralessClientAPIController.swift:56–63,114–119`) используют этот путь.
- Четыре `CloudWriteAdmissionTests` проверяют bytes/Keychain/observer zero effects,
  same-record/different-object identity, pre-cancelled task и once-only admitted
  completion. Они не исполняют UIKit controller; queue/action/frames proof pending.

## Следующая проверка

Адресные regressions для CAF-01…03, затем native compile и шесть engine formatter
tests с 30-second run bound после build; native host/writer queue fixtures и
timestamped Cloud/API frames по AGENTS. Source-closed CA не является подтверждением
полного PFR startup или остальных параллельных remediation scopes.

## Fingerprints

Основной source review set — 30 файлов. Aggregate SHA-256:
`51898b976590532396da5ad0c4bec408f4bc11900a8a0639f2c754fc082cae5a`.
Алгоритм: sorted relative POSIX paths; concatenation
`path + NUL + lowercase-SHA256(file bytes) + LF`, затем SHA-256 UTF-8 результата.

- `swift/ExteralessCore/Sources/ExteralessCore/`: `CloudArchive`,
  `CloudPublicRestoreProjection`, `CloudCloudflareMetadata`, `CloudCredentials`,
  `CloudAICredentialBridge`, `CloudLegacyModels`, `CloudLegacySettingsArchive`,
  `CloudRepairPlan`, `CloudRemoteStore`, `CloudSyncSession`, `CloudWriteAdmission`,
  `ToolsBackupArchive`, `ToolsBackupRestore` (все `.swift`).
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/`: четыре `.swift`
  под `Cloud/` — `ExteralessCloudArchiveHost`, `ExteralessCloudUI`,
  `ExteralessCloudController`, `ExteralessClientAPIController`; также
  `Tools/ExteralessBackupController.swift`.
- `telegram-ios/submodules/TelegramCore/Sources/`: `Network/Network.swift`,
  `Network/NetworkEngine.swift`, `Network/MtProtoKitEngine.swift`,
  `ExteralessRuntime/TLNetworkRequest.swift`,
  `ExteralessClientAPI/ExteralessClientAPIRequestPolicy.swift`.
- `telegram-ios/submodules/MtProtoKit/`: `PublicHeaders/MtProtoKit/MTRequestLogContext.h`,
  `Sources/MTRequestLogContext.m`, `Sources/MTRequest.m`, `Sources/MTRequestMessageService.m`.
- `telegram-ios/submodules/MTProtoRustEngine/Sources/MTProtoRustEngine/`:
  `RustRequestLog.swift`, `RustNetworkSession.swift`, `RustEngineRuntime.swift`.

Ключевые individual SHA-256:

| Файл | SHA-256 |
|---|---|
| `CloudCloudflareMetadata.swift` | `1573a8f6f517a2fa0282a7daf76671f9fde8b2a55c974f6a7d37d280dd3a5db2` |
| `CloudArchive.swift` | `174b6cfd01d8d8628d7d78be4670a42568df0984824296248de56b88069cf422` |
| `ExteralessClientAPIRequestPolicy.swift` | `b9557d885258f7b7d2829ea9d8d69cea02b25206350a6718fe4d4b0f9694d6dd` |
| `Network.swift` | `d77c9983d248b7fa97d95645bff61e9db5d4ff8f2f8f3c9a8cbe7065c1741d8a` |
| `CloudReviewRemediationTests.swift` | `3d1c44e743dede01bb1fbf495187796924461f35e4084d4cd9f47b0ff75f9a1f` |
| `CloudWriteAdmissionTests.swift` | `b7ee5c5970f543b43caeb5c000e8841a8f3a62728af9b4b2d6dbc1c772c4f512` |
| `ToolsAdmittedProjectionTests.swift` | `69530ed006ea7d3768cfde443103b4ab0fd2a954ffcadc6257110ed40b6aab62` |
| `NetworkCredentialLogTests.swift` | `6f439f02e06262259bba8f88c1e56ba683dfaeaa0297b91b39a0b13be50c5284` |
| `RustCredentialLogTests.swift` | `0152765aecb03ee50adae7107e4e1f27e9c668b239f6cba7c0eb12bb3d18135d` |
