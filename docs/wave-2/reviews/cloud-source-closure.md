# Source closure — CAF-01 / CAF-02 / CAF-03

2026-11-15. **Все три remaining findings закрыты по source review.
Остаточных P1/P2 в проверенных трёх контрпримерах не найдено.**
Native log/GUI XCTest и recorded frames остаются pending на Apple.

| Finding | Статус | Основание |
|---|---|---|
| CAF-01 | **Source-closed** | Helper возвращает `any CustomStringConvertible`; три production metadata constructions совместимы. Native fixture использует actual helper для protected и ordinary request. |
| CAF-02 | **Source-closed** | Immutable `retain` не получает право insertion после удаления токена; presence проверяется до public commit и в optional key phase. |
| CAF-03 | **Source-closed** | Opt-out фиксируется до projection: credentials пусты, CF account write/reset отсутствует, обычный public restore работает с сохранением presence и permission. |

Scope — только CAF-01…03 из `cloud-api-followup.md`. Source closure не означает
native execution, visual acceptance или завершение других integration scopes.

## Срез и evidence

- HEAD: `ffdb2833d68bbb7c0f51e684f109a494999a8e21`.
- Прочитан новый верхний раздел `docs/wave-2/cloud-review-remediation.md`, затем
  actual implementation, native callers и regression source ниже. Применяются
  ранее прочитанные `telegram-ios/AGENTS.md` / `CLAUDE.md`.
- Scoped diff относительно `43c46497` пуст для четырёх изменённых Core Cloud files,
  `CloudCloudflareAdmissionTests.swift`, `CloudArchiveTests.swift` и
  `CloudReviewRemediationTests.swift`.
- По сообщению пользователя, `43716703817 / 43c46497` прошёл
  **609 Core / 180 Host / 30 Hooks**, включая шесть новых CF regressions.
  Это атрибутированное CI evidence; здесь CI не запрашивался и не запускался.
- Локально выполнены read-only source/Git/hash checks с timeout ≤15 s.
  Дополнительный fixture run не требовался. Swift/native XCTest, HTTP, RPC,
  аккаунты и реальный Keychain здесь не исполнялись.
- Implementation и старые reports read-only. Записан только этот документ.

## CAF-01 — устранён `Any` → protocol mismatch

**Проверенный код:**
`telegram-ios/submodules/TelegramCore/Sources/ExteralessClientAPI/ExteralessClientAPIRequestPolicy.swift:17–19`;
`telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift:27–37,63–69,1425,1506`;
`telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift:325`.

Helper теперь возвращает `any CustomStringConvertible`. Его protected branch
возвращает `String`, ordinary branch — `WrappedFunctionDescription`, который
явно conform к этому protocol. Значение подходит существующему
`WrappedRequestMetadata.init(metadata: CustomStringConvertible, tag:)` во всех
трёх production callers без cast и дополнительной перегрузки. Исходная причина
compile-time несовместимости устранена.

**Regression source:**
`telegram-ios/submodules/TelegramCore/Tests/NetworkCredentialLogTests.swift:80–99`.
Существующий test теперь вызывает actual helper для generated
`auth.initPasskeyLogin`, передаёт результат в shipping metadata/engine adapter и
проверяет formatter. В том же test `help.getConfig` проходит ordinary helper
branch и реальный wrapper initializer. Обе ветки проверяются при redaction on/off.

Это подтверждение совместимости прочитанных типов/callsites. Полный native
type-check и исполнение данного XCTest на Apple не выдаются за выполненные.

## CAF-02 — удаление после preview не выдаёт новое разрешение на CF insertion

**Проверенный код:**
`swift/ExteralessCore/Sources/ExteralessCore/CloudCloudflareMetadata.swift:6–20,45–99`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudArchive.swift:75–108,167–187,193–230`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudLegacyModels.swift:52–78`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudLegacySettingsArchive.swift:203–248`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudArchiveHost.swift:17–42,60–73`.

Native и legacy plans сохраняют captured decision `excluded` / `add` / `retain`.
Для исходного сценария «incoming pair A, existing pair B, затем удалить token B»
план остаётся `retain`; отсутствие account setter больше не используется как
единственный критерий проверки credential target.

- Удаление **до public commit** обнаруживает `verifyTarget(.retain)`:
  `.settingsChanged`, incoming insertion не выполняется.
- Удаление **между public и key phase** обнаруживается повторной проверкой в
  `CloudCloudflareMetadata.restore`. Key phase возвращает
  `.restorePartiallyApplied`; уже применённые public settings остаются, incoming
  CF token не вставляется.
- Ветка `retain` вообще не вызывает `insertIfAbsent`, поэтому удаление после её
  presence check также не может превратить её в `add`.
- Независимая local replacement с сохранённой presence остаётся локальной;
  restore не заменяет её incoming значением. Ветка `add` отдельно проверяет
  отсутствие и отвергает raced duplicate, сохраняя local item.

Native host по-прежнему вызывает эти public verification/key-phase APIs для обоих
форматов. Следовательно, исправление охватывает прежнее расхождение Core apply
и двухфазного native host.

**Регрессии:**
`swift/ExteralessCore/Tests/ExteralessCoreTests/CloudCloudflareAdmissionTests.swift`:

| Строки | Проверка |
|---|---|
| 65–84 | Native token removal до Core/host public apply: unchanged file bytes, account B, nil token, zero insertions. |
| 86–102 | Removal после real Tools public phase: partial error, public flag применён, incoming insertion отсутствует. |
| 104–131 | Те же pre-public/key-phase guarantees для legacy plan. |
| 182–193 | Independent local replacement сохранена; retained=1, added=0, insertions=0. |

`publicHostPhase:58–63` использует реальный `ToolsBackupRestorer` и те же
pre-public hooks, что shipping host. Это Core fixture, не запуск UIKit host.

## CAF-03 — fresh opt-out preview сохраняет рабочий public restore

**Проверенный код:**
`swift/ExteralessCore/Sources/ExteralessCore/CloudArchive.swift:160–187,193–214`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudCloudflareMetadata.swift:18–20,45–79`;
`swift/ExteralessCore/Sources/ExteralessCore/CloudLegacySettingsArchive.swift:232–247`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudController.swift:85–89`.

Native inspect вычисляет inclusion из **локального snapshot и source envelope**
до CF projection. При local opt-out `credentials=[]`, admission=`excluded`,
`credentialCount=0`; CF account отсутствует и среди setters, и среди resets.
Остальные admitted public values/presence доходят до обычного restore.

`verifyTarget(.excluded)` возвращает без secure read. Пустая key phase выходит
до registration, reload и insertion. Последующее включение local includeKeys
не расширяет этот план: apply/key phase дополнительно требуют captured
`plan.includedApiKeys`. Native footer также использует captured preview intent.

**Регрессии:** `CloudCloudflareAdmissionTests.swift:133–164` проверяет actual Tools
public phase и optional key hook: flag применён, исходный stored count сброшен к
default с восстановленной absence, counts совпадают, CF account/token и local
permission/presence сохранены. Оба probe counters равны нулю; backing secret store
не получил read. `:166–180` дополнительно проверяет opt-out preview → local enable
→ apply: публичный flag применяется, credentials всё ещё не допускаются.

Нулевая credential I/O здесь относится к проверенным inspect/apply/key-phase
контрактам; это не утверждение о всей подготовке приложения.

## Итоговая граница приёмки

CAF-01/02/03 **source-closed** на указанном срезе. Следующее отдельное evidence —
Apple native compile/log XCTest, GUI action execution и timestamped frames по
AGENTS. Green Core и проверки типов/fixtures не заменяют эти результаты.

## Fingerprints прочитанного source

Имена ниже однозначно соответствуют полным путям, указанным выше; SHA-256 от bytes.

| Файл | SHA-256 |
|---|---|
| `CloudArchive.swift` | `99fd7b87befef0ec1cb9529e9fd5475054ac1ece0429a0b8b378964b5476376c` |
| `CloudCloudflareMetadata.swift` | `d9797a22506a71c26579f50b75b2e69acc26b251e8c5abfb089416c69cc08385` |
| `CloudLegacyModels.swift` | `750d4964aa18fd84d5ad062c83c6dff97a3b0eff6bab48b2567a2a99767c613d` |
| `CloudLegacySettingsArchive.swift` | `2e588a8d68f31585bc545270da4ad1f2824df493255faa1443741ce5bf3df035` |
| `CloudCloudflareAdmissionTests.swift` | `58519d46f77ad6ec03aeac57babdbaf5a41ceb6044147c5f6fa48163c1048db4` |
| `ExteralessClientAPIRequestPolicy.swift` | `16d54501c142ddd7817486c62d6552c944b4c51119dbabf9a7e25f4ac392fe45` |
| `Network.swift` | `d77c9983d248b7fa97d95645bff61e9db5d4ff8f2f8f3c9a8cbe7065c1741d8a` |
| `TLNetworkRequest.swift` | `468aebbb567a665ce93d54f24e4e816c88519a48f3b1f228ad7e625597c5c9ab` |
| `NetworkCredentialLogTests.swift` | `bbb79bcc6080d3b028ad4b29ea511608a4e02a727386a41712ddf95dbebbff22` |
| `ExteralessCloudArchiveHost.swift` | `4b7a0d43670f232fcdceb41aaaa2b67e357a769a3bb666281044c3ef9af46d67` |
| `ExteralessCloudController.swift` | `1e9c35cfb0c3f820c3109ad299935477f22d237cf8bd4f33660a445f02e7e875` |

Старые reports сохранены byte-for-byte:

- `cloud-api.md`: `1878ed62789a6eef275abc6326b59a0fa04864b89bd96e3844679c720f2ea354`.
- `cloud-api-followup.md`: `fb8d87d264cf9f70aa28485ca286cb1a99a4cd7a7b14bd793d01b11bf11c80bd`.
