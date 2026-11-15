# AF-01–06 — независимый focused follow-up

2026-11-15. Проверен рабочий tree при HEAD `6f718b1108b9f90b5d498e07ee324325842bbe5d`, включая native additions и фактически применённый History hunk.

## Вердикт

**AF-01/02/04/05/06 — Closed/source. AF-03 — Partial/open: остаётся один P2, AIAF-01 ниже.** В этих шести finding новых/оставшихся P1 не установлено.

`Closed/source` означает независимую проверку исправленного call graph и содержания regression fixtures. Native typecheck/link, XCTest execution, UIKit/account integration и visual/vendor acceptance остаются pending.

| Finding | Статус | Проверенный результат |
|---|---|---|
| AF-01 | **Closed/source** | Оба private-chat flags учитываются при acquisition, revalidation, наблюдении и guarded commit всех рассмотренных message/context scopes с external/Copy permission. |
| AF-02 | **Closed/source** | После source edit сохраняется свежий incoming `fromLang`, старые summary/translated payloads удаляются. |
| AF-03 | **Partial/open — AIAF-01, P2** | Complete-source selection, actual download completion guard и основной shown-page Copy исправлены. Same-preview remote edit всё ещё сохраняет устаревший full source/cache. |
| AF-04 | **Closed/source** | Реальная round-video button использует selected-provider hook; Cancel отзывает lease до queued Postbox mutation. |
| AF-05 | **Closed/source** | History, Copy/AI/Speak и Hide используют одинаковый effective target, включая nil target и язык приложения. |
| AF-06 | **Closed/source** | Retry переносит только подтверждённую own-commit version; настоящий последующий edit не авторизуется этим receipt. |

CMC Format/Selection/Media-export findings остаются в отдельном review/owner scope; здесь они не заведены повторно. Этот вердикт не меняет статусы старых отчётов задним числом.

## AIAF-01 — P2 / остаток AF-03: edit за пределами preview сохраняет старый full source и перевод

**Основные места:**

- `telegram-ios/submodules/TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift:224–231` — source equality не учитывает server edit revision; отсутствующий incoming full page не сравнивается с прежним.
- `telegram-ios/submodules/TelegramCore/Sources/State/ServerMessageMerge.swift:22–29` — при таком equality переносится старый translation.
- `telegram-ios/submodules/TelegramCore/Sources/SyncCore/SyncCore_StandaloneAccountTransaction.swift:175–181` — Seed merge восстанавливает прежний rich attribute вместе с `fullInstantPage`, если partial preview равен.

**Минимальный сценарий и фактический путь:**

1. В Postbox хранится rich message: `text=""`, preview `A` с `isComplete=false`, загруженная full page `A + OLD_B`, complete перевод этой страницы. Автор меняет только часть за пределами preview на `NEW_C`.
2. Приходит partial server snapshot с тем же preview `A`, новым `editDate` и без полного payload. Такой snapshot прямо поддержан parser: `SyncCore_RichTextMessageAttribute.swift:56–59` преобразует `isPartial` в incomplete `instantPage` и всегда задаёт `fullInstantPage=nil`; `StoreMessage_Telegram.swift:1362–1363,1406–1407` отдельно сохраняет edit revision и rich payload.
3. Это живой путь `.EditMessage` → `mergedServerMessageUpdate` (`State/AccountStateManagementUtils.swift:4712–4725`); тот же merge выполняется при refresh уже сохранённого feed post (`TelegramEngine/Feed/FeedPageStorage.swift:20–26`). Equality возвращает true: plain text/entities и preview равны, `if let new.fullInstantPage` не выполняется. Старый translation остаётся.
4. Следующий настоящий Postbox merge (`Postbox/Sources/MessageHistoryTable.swift:1613–1614`) вызывает Seed closure, которая возвращает старый `fullInstantPage= A + OLD_B`. Новая message version сама по себе этот cache не очищает.
5. `ExteralessAIIntegration.swift:299–307` видит complete `wholePage` и **не вызывает** новый guarded download. `ChatMessageRichDataBubbleContentNode.swift:2576–2583` также использует cached full без запроса. `ExteralessAIRichSource.swift:18–21` принимает complete старый translation. Новое открытие AI action или Show more поэтому использует OLD_B при уже принятой новой server revision.

**Impact:** устаревший перевод остаётся результатом отредактированного сообщения; новый summary/AI request может обрабатывать старый скрытый хвост. Исправленный Copy честно получает applied page, но сама эта страница устарела. Это source/cache invalidation defect, не утверждение о просмотренных кадрах или live response.

**Исправление:** для partial snapshots учитывать смену server source revision и инвалидировать как derived translation, так и cached full page. Не позволять следующему Seed merge вернуть full page предыдущей revision; свежую summary eligibility сохранить. Решение должно отличать server edit от own derived-attribute commit, чтобы не сломать AF-06.

**Regression:** маленький real Postbox case с `EditedMessageAttribute(date: 100)` + preview A/full A+B/complete translation → incoming `date: 101`, тот же partial A, `fullInstantPage=nil`, свежий `fromLang`. Провести его через actual `mergedServerMessageUpdate` и Seed merge; проверить отсутствие прежнего full/translation, сохранение eligibility и необходимость full download. После его completion A+C provider input содержит C, не B. Отдельный own-translation commit не должен выглядеть как server source edit.

**Почему новые tests не закрывают случай:** `ExteralessAINativeTests.swift:41–64` меняет сам preview (`old` → `new`). Его `:67–109` и UI follow-up `:120–143` прямо вызывают full-completion helper. В описанном сценарии production до этого helper не доходит. Проверка его корректности не проверяет admission после same-preview edit.

## Сверка исправлений по actual call graph

Пути в этом разделе, начинающиеся с имени модуля, относительны `telegram-ios/submodules/`.

### AF-01 — effective private protection

`TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift:136–151` читает effective peer и **`.copyProtectionEnabled || .myCopyProtectionEnabled`**, как настоящий Chat reader (`TelegramUI/Sources/ChatControllerContentData.swift:983–987`). Native toggle действительно пишет второй flag (`TelegramCore/Sources/TelegramEngine/Peers/CopyProtection.swift:35–46`).

Acquisition source/reply/explicit-context paths (`ExteralessAIScope.swift:161–206`) и validation каждой участвующей message version (`:209–219`) достигают этого predicate. Live observer подписан на messages и cached peer data (`:119–131`); `Postbox/Sources/PeerView.swift:52–75,160–166` использует effective cached-data identity и сообщает её изменение без message-version bump.

Consumer chain проверен до scoped HTTP admission (`TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:597–612`), guarded summary/translation/transcription commits (`ExteralessAIMessageOperations.swift:136–186`) и stock Copy validator (`AccountContext/Sources/ExteralessAIHooks.swift:79–90`). ResultAccess invalidation доходит до real screen callback и отключения Copy (`ExteralessAIIntegration.swift:699–704`; `ExteralessAIResultController.swift:80,138–147,278–281`). Native Telegram audio route передаёт обе export/copy permissions false и сохраняет version/resource/lease guard (`ExteralessAINativeAdapter.swift:209–215`).

Fixtures: Core `testAF01MyCopyProtectionRevokesScopeWithoutMessageVersionChange` (`:11–39`) меняет настоящий CachedUserData и отклоняет fresh scope/queued write; UI `testAF01ActualResultAccessObserverRevokesCopyAndFurtherExports` (`:15–52`) использует настоящий ResultAccess observer, result text view и scoped transport. После revoke copy callback не вызывается и второй body-bearing request не достигает injected transport. Это больше, чем отдельный Bool-helper test; полного AccountContext/controller fixture здесь нет.

### AF-02 — fresh summary eligibility

`ServerMessageMerge.swift:30–33` вызывает `ExteralessAIMessageOperations.swift:94–104` на **incoming** attributes. Translation удаляется, incoming `SummarizationMessageAttribute` заменяется на `fromLang`-only. Seed merge не восстанавливает старую summary (`SyncCore_StandaloneAccountTransaction.swift:122–190`). Реальный summary-button consumer по-прежнему проверяет наличие attribute (`TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift:1932–1934`).

`ExteralessAINativeTests.testAF02SourceEditKeepsFreshSummaryEligibilityOnly` (`:41–64`) проходит actual server merge + Postbox для plain и rich-only edit: новый `es` остаётся, старые summary/translated/translation отсутствуют. Исходная потеря свежей eligibility устранена; AIAF-01 относится к отдельному same-preview reuse branch.

### AF-03 — исправленные full-content и shown-page пути

- `ExteralessAINativeAdapter.swift:97–104,158–176,232–237` получает complete source до summary/translation; generic whole-message actions используют `ExteralessAIIntegration.swift:355–378`. `ExteralessAIRichTextTranslator.swift:11–21` выбирает `fullInstantPage ?? instantPage` и отказывает incomplete whole source до provider request.
- Actual `TelegramEngineMessages.swift:1966–1967` делегирует `_internal_requestExteralessFullRichText`, а не прежнему отдельному writer. `ExteralessAIRichSource.swift:38–78` фиксирует native version перед request, повторно проверяет её и scope в completion transaction. Scoped cancel сериализован через `lease.withActive`; `:83–109` отклоняет incomplete/stale/cancelled response, очищает derived payloads и обновляет receipt фактически прочитанной Postbox version.
- Основной context-menu Copy читает `appliedInstantPage` через message ID/version gate (`ChatMessageRichDataBubbleContentNode.swift:159–164`; записи `:490–491,563–564`). Этот accessor реально вызывается из `ExteralessAIChatActions.swift:20–27,211–218` и `ChatInterfaceStateContextMenus.swift:1321–1329,1355–1360`. Collapsed/expanded original pages различены, incomplete cached translation при complete source отбрасывается. Show more допускается для incomplete translated preview (`ChatMessageRichDataBubbleContentNode.swift:1129–1145`).
- Sheet entrance также загружает full source и валидирует scope до/после async factory (`TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatTranslation.swift:35–60`).

Core `testAF03FullRichCompletionInvalidatesPreviewResultsAndUsesActualVersion` проверяет actual completion writer, stale version, cancelled lease и замену full page. UI `testAF03FullRichSourceFeedsCopySummaryAndRealTranslationClient` (`:87–153`) вызывает настоящий rich translator/AITranslationClient и ловит SENTINEL_B в provider queries. Его Copy assertion — **проекция с переданной page**, не создание/раскрытие настоящего rich bubble; accessor и clipboard wiring проверены чтением production callsites. Download API parsing, UI expansion и recorded-frame acceptance остаются непроверенными исполнением. Остаточная production ветка — AIAF-01.

### AF-04 — actual round-video button и Cancel

Production layout использует selected-provider availability и активный disposable для progress/Cancel (`ChatMessageInteractiveInstantVideoNode.swift:829–878`). Его реальный `AudioTranscriptionButtonComponent` подключён к `transcribe()` (`:1841–1842`); UIView `.touchUpInside` вызывает component callback (`AudioTranscriptionButtonComponent.swift:91–99`). Native input factory вызывает **`ExteralessAIHooks.transcribe`** (`:1845–1851`), прямого stock-only request в этой action больше нет.

`transcribe()` сначала отменяет существующий disposable, независимо от cached `.locked` state (`:1905–1923`). `ExteralessAIHooks.swift:43–61,74–75` доставляет disposal в adapter; `ExteralessAINativeAdapter.swift:196–228,305–313` использует общий executable route и `exteralessAINativeRequest`. Его disposal синхронно отменяет lease/task (`ExteralessAINativeRequest.swift:17–38`), а не только callback. Native response **вместе с trial mutation** проходит `exteralessAICommitNativeAudio` (`TelegramCore/Sources/TelegramEngine/Messages/Transcription.swift:49–103`); external transcript проходит resource/version/account guard в `ExteralessAIMessageOperations.swift:136–186`.

Два UI follow-up tests (`:155–291`) действительно создают **round node + его button component**, посылают `.touchUpInside` и вызывают production state machine. 5 providers × Premium/non-Premium проходят shared executable routing и настоящий Speech/client plumbing с injected decode/recognition/transport. Cancel fixture ставит реальную Postbox transaction за queue barrier, нажимает ту же кнопку второй раз и проверяет отказ обеих storage веток, unchanged version/transcript/trial state. Account input и I/O заменены; native RPC response body синтетический, внутри реального commit wrapper. Fixtures не строят весь AccountContext или layout pass, но не подменяют round-button action отдельным policy helper.

### AF-05 — nil auto target

`swift/ExteralessCore/Sources/ExteralessCore/AINativePolicy.swift:117–126` объединяет enabled/availability/peer-auto/default-language/normalization (`nb → no`). **Coordinator History hunk применён:** `TelegramUI/Sources/ChatHistoryListNode.swift:2337–2339` вызывает именно этот resolver.

Actions вызывают его через `ExteralessAIChatActions.swift:15–18,199–218`; основной Copy/Translate/Speak берёт эту проекцию (`ChatInterfaceStateContextMenus.swift:1321,1385,1463,1472–1474`). Hide label и действие используют `canHideManual` (`ExteralessAIChatActions.swift:64–71`; `ExteralessAIIntegration.swift:476–483`). Наличие incoming auto target запрещает ложный Hide (`AINativePolicy.swift:97–112`). Legacy optional из gesture caller (`ExteralessMessageGestures.swift:56–59`) пересчитывается при входе с настоящим ChatController (`ExteralessChatTranslation.swift:17–19`; `ExteralessAIIntegration.swift:450–452`), поэтому не возвращает старый nil-target bypass.

Policy test `testAF05DefaultAutoTargetUsesTheSameAvailabilityAndNormalization` (`AINativePolicyTests.swift:6–20`) и real Postbox/display test `testAF05NilAutoTargetUsesEnglishForNativeDisplayAndCannotHideAuto` (`ExteralessAINativeTests.swift:112–145`) покрывают nil/en, en-raw/nb, availability, manual-over-auto и disabled auto. UI paths подтверждены source tracing, не screenshot claim.

### AF-06 — own-commit Retry против настоящего edit

`ExteralessAIScope.didCommit` принимает только source ID с прежней ожидаемой version и сохраняет фактически прочитанный updated message (`ExteralessAIScope.swift:68–83`). `committedRetryCapability` не создаётся из UI completion. `renewed` атомарно копирует source/versions/receipt (`:86–91`).

Actual Retry: `ExteralessAIResultController.swift:195–198,308` → `ExteralessAIResultAccess.begin()` (`ExteralessAIIntegration.swift:676–688`). Сначала отменяется предыдущая lease, затем читается её уже выигравший commit receipt, после чего создаётся новая lease. Reacquisition проверяет expectedStableVersion в Postbox (`ExteralessAIScope.swift:164–167`); resolve/observer callbacks привязаны к generation (`ExteralessAIIntegration.swift:689–711`). `finish()` once-only (`:715–718`) употреблён реальным screen completion (`ExteralessAIResultController.swift:219–228`).

`ExteralessAIFollowupNativeTests.testAF06RealResultAccessSuccessRetryAndExternalEdit` (`:54–85`) использует сам ResultAccess и production translation commit: V → фактическая V′ → begin/resolve допускается; последующая внешняя text mutation → Retry отвергается. Capability V′ не создаётся в тесте вручную. Repeated/failed completion не может выдать новый receipt. Второй rich test проверяет Retry после двух собственных commits (full-source + translation). Фактический result-controller button в этих tests не создаётся; его wiring проверен выше.

## Regression / execution ledger

Прочитаны все методы следующих файлов, число объявлений независимо пересчитано:

| Файл | Методов | Статус здесь |
|---|---:|---|
| `swift/ExteralessCore/Tests/ExteralessCoreTests/AINativePolicyTests.swift` | 7 | Source review |
| `telegram-ios/submodules/TelegramCore/Tests/ExteralessAINativeTests.swift` | 15 | Source review |
| `telegram-ios/submodules/TelegramUI/Tests/AI/ExteralessAINativeUITests.swift` | 8 | Source review |
| `telegram-ios/submodules/TelegramUI/Tests/AI/ExteralessAIFollowupNativeTests.swift` | 5 | Source review |
| `telegram-ios/submodules/InstantPageUI/Tests/InstantPageAIVisibilityTests.swift` | 1 | Отдельная visibility fixture, source review |

Итого **35 native-owner methods + 1 InstantPage fixture**, из них десять новых AF methods. Ни один XCTest здесь не запускался. InstantPage fixture проверяет реальные projection objects/ordinals, не отображённые кадры, и не заменяет AF regression coverage.

Координатор сообщил последний green run **`43708260304`: 545 Core / 169 Host / 30 Hooks** и green прежнего 75-AI cohort. CI не запрашивался; точный commit этого run независимо не привязан. Эти сведения не дают execution pass новым 7 AINativePolicy methods на `6f718b11` или UIKit/TelegramCore cohort. Current Core AI file set содержит прежние 75 + 7 policy methods.

Известный build join остаётся: два dependency hunk из `docs/wave-2/ai-followup-shared.patch` на snapshot ещё отсутствуют в `TelegramUI/BUILD` (production rich-node edge и шесть direct test dependencies; текущий test block `:687–698`). Они переданы build owner по сообщению координатора. Targets существуют: `TelegramCore/BUILD:134–175`, `TelegramUI/BUILD:687–708`, `InstantPageUI/BUILD:55–97`; наличие target не доказывает compile/link pass.

## Source fingerprints

Manifest = SHA-256 от UTF-8 concatenation `relative POSIX path + NUL + SHA256(raw file bytes) + LF`, sorted unique paths. Это pins рабочего tree, включая untracked files. Группы пересекаются.

| Группа | Файлов | Manifest SHA-256 |
|---|---:|---|
| Frozen native Core: `AINativePolicy*.swift` + `AINativePolicyTests.swift` | 3 | `c17e6a68591e3e23fd3052cfcefc4a8dc0eba697b78178f4a88398b795769cfa` |
| Core `Sources/ExteralessCore/AI*.swift` + `Tests/ExteralessCoreTests/AI*.swift` | 31 | `7db48311692fa5f835387a87a6de8fdbec1cf21e5a07b2efc9bdc837785688f9` |
| Native-owned membership ниже | 21 | `268bc2f3b6ec938fc02b63014c8f7954d1c9ffbcf86fabb27a1db21aea3c9f44` |
| Applied-shared membership ниже | 8 | `2eb3ed946b0ed027949f70621385158d750cb0f9f5cebf72b03aebdaf7ab9202` |
| Supporting membership ниже, включая actual History и BUILD | 20 | `4a672b355e5d793601f4cc901860aecede346d38e0304232cc1edb4b6b4720b4` |

Native-owned: три native Core файла; `TelegramCore/Sources/ExteralessAI/*.swift` (6) + `Tests/ExteralessAINativeTests.swift`; UI `Sources/ExteralessClient/AI/ExteralessAI{Integration,NativeAdapter,ChatActions,ResultController,RichTextTranslator,ChatPolicyObserver,NativeRequest}.swift`; оба `Sources/ExteralessClient/Speech/*.swift`; оба `Tests/AI/*.swift`.

Applied-shared, относительно `telegram-ios/submodules/`:

```text
AccountContext/Sources/ExteralessAIHooks.swift
TelegramCore/Sources/State/ServerMessageMerge.swift
TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift
TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatTranslation.swift
TelegramUI/Sources/ChatInterfaceStateContextMenus.swift
TelegramUI/Sources/Chat/ChatControllerOpenMessageContextMenu.swift
TelegramUI/Components/Chat/ChatMessageInteractiveInstantVideoNode/Sources/ChatMessageInteractiveInstantVideoNode.swift
TelegramUI/Components/Chat/ChatMessageRichDataBubbleContentNode/Sources/ChatMessageRichDataBubbleContentNode.swift
```

Supporting, относительно `telegram-ios/submodules/`:

```text
Postbox/Sources/PeerView.swift
Postbox/Sources/MessageHistoryTable.swift
TelegramCore/Sources/ApiUtils/StoreMessage_Telegram.swift
TelegramCore/Sources/State/AccountStateManagementUtils.swift
TelegramCore/Sources/TelegramEngine/Feed/FeedPageStorage.swift
TelegramCore/Sources/SyncCore/SyncCore_EditedMessageAttribute.swift
TelegramCore/Sources/SyncCore/SyncCore_InstantPage.swift
TelegramCore/Sources/SyncCore/SyncCore_RichTextMessageAttribute.swift
TelegramCore/Sources/SyncCore/SyncCore_StandaloneAccountTransaction.swift
TelegramCore/Sources/TelegramEngine/Messages/Transcription.swift
TelegramCore/Sources/TelegramEngine/Peers/CopyProtection.swift
TelegramUI/Sources/ChatHistoryListNode.swift
TelegramUI/Sources/ChatControllerContentData.swift
TelegramUI/Sources/ExteralessClient/Chats/ExteralessMessageGestures.swift
TelegramUI/Components/AudioTranscriptionButtonComponent/Sources/AudioTranscriptionButtonComponent.swift
TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift
TelegramUI/BUILD
TelegramCore/BUILD
InstantPageUI/Tests/InstantPageAIVisibilityTests.swift
InstantPageUI/BUILD
```

Ключевые raw-file pins:

| Файл | SHA-256 |
|---|---|
| `ExteralessAIScope.swift` | `123d1a93ff9a7f4a80905d5ae0e183c1223bdcd3cd29851c4d06753572e03203` |
| `ExteralessAIRichSource.swift` | `857cbb41efed56051e2288978e78355c1726cd1893550d8812115feffc10838b` |
| `ServerMessageMerge.swift` | `861740753c6f8072b57e0d558a03badbe83eb30b03a88319beba09f6cbb768a8` |
| `SyncCore_StandaloneAccountTransaction.swift` | `acc8b85b6bbe24a41b5bf5e5872f0db3dfe81f1a563bcc4ba681a75504977597` |
| `ChatHistoryListNode.swift` | `f14dd23f146d6c1c77e29993206ff704ca692ee8b1d61247d97494e7b5a071e0` |
| `ExteralessAIFollowupNativeTests.swift` | `3ad6579a1892ab25432eddea9c24b92e19301873cbfbc625166785394e257e84` |

Readonly report pins:

- `reviews/ai.md`: `fb5eec0b918538065937e753811613a244e05e3bdfa6d32e9263c6d5f0b12b84`.
- `reviews/ai-core-followup.md`: `e34fec7d3b64ccf766756fda74c0c489f9ceb9362bc36135609508ebe071ebbe`.
- `reviews/ai-final-followup.md`: `ca5e10041632661c2c95288f5c06f22587272a818004ae935463ee6bc300c550`.

После записи отчёта повторно проверены все пять manifests, шесть key-file pins и SHA-256 трёх старых отчётов: совпали; HEAD остался `6f718b1108b9f90b5d498e07ee324325842bbe5d`.

Проверки reviewer: source reads/grep, локальные Git reads и bounded Python stdlib SHA-256/counting (`-B`, timeout ≤20 s). Implementation, старые reports и git history не изменялись; единственная запись — этот файл. CI, live HTTP, account/plugin execution, native tests и recordings не выполнялись. Доказательство AIAF-01 — прослеженный production branch на указанном допустимом snapshot, без simulation/pass claim.
