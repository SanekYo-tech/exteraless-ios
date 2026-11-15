# MCA-F01 / MCA-F02 — ordering source closure

2026-11-16. **Оба контрпримера CLOSED-SOURCE. Остаточных P1/P2 в этих двух ordering-сценариях не найдено.**

Проверены actual applied sources и follow-up
`docs/wave-2/sdk-manager-custom-alias-remediation.md:261–560`. Граница review —
MCA-F01/MCA-F02 из `manager-custom-alias-source-closure.md`; старый отчёт сохраняет
свой checkpoint. Native C/Swift/SDK integration, XCTest и rendering здесь не
исполнялись. Результат ниже — source closure с отдельно указанным Python evidence.

Пути: `P/` = `python/exteraless_runtime/`; `H/` =
`swift/PluginHost/Sources/PluginHost/`; `U/` =
`telegram-ios/submodules/TelegramUI/Sources/`; `UI/` =
`U/ExteralessClient/PluginUI/`.

## MCA-F01 — S1 сохраняется до ACK actual native commit

### Причина исходного контрпримера устранена

`P/_ui.py:613–728` вводит `_SettingsPresentation`. `_stage`, `:686–708`, сохраняет
один candidate S2 и уникальный completion wrapper, но после `uiUpdate` admission
оставляет `self.page/model/revision` от S1. Следующий candidate отвергается до нового
factory build. Переключение происходит только в `_settle`, `:710–728`, после
проверки presentation id, update id, previous/candidate snapshot ids, strict Bool
`committed` и ожидаемого native revision.

`_event_page`, `:647–654`, выбирает только текущий committed SDK snapshot по
`_uiSettingsSnapshot` и `_uiRevision`; поиска callback в следующей странице по
совпавшему key/CBID больше нет. `show_settings`, `:931–950`, передаёт
`settingsSnapshotId` из созданного page UUID.

Actual bridge принимает typed третий аргумент `uiUpdate`
(`UI/PluginUIBridgeExtension.swift:199–235`). `PluginUISettingsUpdate.swift:14–35`
валидирует snapshot pair/completion и фиксирует native `baseRevision`.
`PluginUILifecycle.swift:340–358` резервирует единственный update на текущем
presentation owner/scope и уникальный completion handle. Main commit
(`PluginUIBridgeExtension.swift:744–774`) вызывает `store.update(settingsUpdateId:)`;
под store lock проверяются reserved id, snapshot pair, base revision и original
permission predicate (`PluginUILifecycle.swift:393–429`). Model/revision/committed
flag публикуются вместе. Defer завершает именно этот update через retirement queue.

### Проверенный порядок

| Фаза | Native | SDK / события |
| --- | --- | --- |
| S2 только admitted | S1 model/revision; update `committed == nil` | Python всё ещё S1. Захваченный S1 event вызывает callback **version 1**. |
| S2 committed, ACK ещё не admitted | Native S2/revision+1; `committed == true` | Python ещё S1. `canAct` и store `action` блокируют новые S2 UI events. Old S1 revision уже не проходит native gate. |
| ACK admission возвращает false | Retirement, completion handle и update slot удерживаются | Cursor не продвигается; release не вызывается; retry повторяет admission. S2 остаётся закрыт для UI actions. |
| ACK admitted, release admission ещё false | Slot всё ещё удерживается | Retry начинает с release, а не вызывает ACK повторно. SDK может уже принять ACK, но S2 UI events ещё закрыты. |
| ACK и release admitted | `completeRetirement` освобождает update slot/handle ownership | Оба control jobs уже стоят в том же captured-owner FIFO. Любые вновь разрешённые S2 UI events идут за ACK и release. |
| ACK исполнен на owner | Python переключается на S2, закрывает S1 | S2 callback — version 2. Old S1 stamp отвергается также SDK-проверкой даже при обходе recorder native gate. |

Native блокировки: `PluginUIBridgeExtension.swift:776–794` и
`PluginUILifecycle.swift:434–442`. Старый stamp проверяется в `permitsCallback`,
`:295–310`; ordinary delivery проставляет `_uiSettingsSnapshot` из actual model,
перезаписывая одноимённое поле payload (`:543–554`).

### ACK, control FIFO и future permission

Actual ACK (`PluginUILifecycle.swift:365–389`) содержит:

- `event = settingsUpdate`, `id = presentation UUID`, `updateId = reserved update UUID`;
- `previousSnapshotId`, `snapshotId`, strict `committed`, текущий `_uiRevision`;
- исходные `_uiPlugin`, `_uiScope`, `_uiLease` из presentation state;
- `_uiTerminal = true`, optional bounded error при отказе.

ACK использует отдельные `previousSnapshotId`/`snapshotId`; обычный
`_uiSettingsSnapshot` stamp добавляется в **ordinary event delivery**. ACK не
маскируется под `event = closed`.

`Delivery.permissionIsCurrent` берётся из **того же** `entry.permissionIsCurrent`
(`:384–385`), immutable поля исходного Entry (`:62–69`). `finishSettingsUpdate`
не захватывает новый permission capability. Bridge передаёт этот closure в `ControlledCallback`
(`PluginUIBridgeExtension.swift:66–81`); actual Runtime добавляет его к
`uiGate.permits` и сохраняет terminal control classification
(`U/Exteraless/ExteralessPluginRuntime.swift:219–223`). Поэтому stale permission
не оживает от последующего regrant.

`PluginUIReleaseQueue.swift:49–80` продвигает `nextDelivery` только после true,
затем отдельно принимает release и лишь после него вызывает completed. При false
сохраняет оставшуюся batch и планирует retry через 100 ms. Повторный release retry
не повторяет уже admitted ACK.

Это действительно один downstream FIFO: `H/PluginCallbackDispatcher.swift:121–173`
append-ит callbacks и releases в одну очередь по **CallbackOwner**; `drain`,
`:194–213`, ожидает каждый Host operation перед следующим. Control capacity
ограничена, включает executing work, а ACK имеет limit 16 KiB. Actual release
проверяет expected owner/interpreter/token и вызывает `release_handles_json`
(`H/PluginHost.swift:1565–1580`). Таким образом, «ACK+release admitted» не выдаётся
за уже завершённое C execution; именно FIFO обеспечивает требуемый последующий
порядок исполнения.

### Refusal, retirement и exactly-once cleanup

- Synchronous refusal закрывает только новый completion lease/candidate
  (`P/_ui.py:693–707`). Unknown target/build failure закрывает candidate до native
  admission (`:939–949`). Rejected/cancelled main commit сохраняет S1 model/revision;
  negative ACK закрывает S2 (`:726–727`).
- `finishSettingsUpdate` возвращает retirement только для matching outstanding id
  и при отсутствии уже переданного retirement (`PluginUILifecycle.swift:367–368`).
  `committed = false` также завершает ticket: повторный commit не проходит
  `PluginUISettingsUpdate.check`. После completed update удалён из Entry
  (`PluginUILifecycle.swift:493–503`), поэтому повторное finish не создаёт ACK снова.
- Если page закрыт **до передачи update в ACK retirement**, parent retirement
  включает pending completion handle. Если ACK retirement уже существует, parent
  его не включает (`:571–609`, особенно `:581–584`). Handle освобождается одним
  владельцем даже при гонке двух retirement paths.
- Scope clear/unload проходят `PluginUIBridgeExtension.clearContext/releaseInstances`
  (`:101–123`); permission loss использует `permissionsChanged`, `:489–495`.
  Они снимают stored presentation, а поздний `applyUpdate`/finish не выбирает новую
  страницу по plugin id. Runtime terminate вызывает `pluginUI.clearContext`
  (`ExteralessPluginRuntime.swift:621`).
- При подавленном ACK native release всё равно закрывает SDK completion lease;
  его identity-checked `discarded` удаляет только свой candidate.
  `_close_pages` (`P/_ui.py:639–645`) и existing
  `_callbacks.py:50–64,94–106,130–142` дают idempotent cleanup snapshots/handles.
  Отставший release не удаляет следующий `_pending`. Retired owner не заменяется
  новым interpreter при release.

**Итог MCA-F01:** прежний S1-visible → S2-callback промежуток устранён. Backpressure
не открывает S2 раньше принятого ACK/release FIFO и не создаёт повторный ACK.

## MCA-F02 — root Custom action входит в FIFO до Task/perform

`U/Exteraless/PluginSettingsController.swift:435–443` направляет Custom tap и
long-click с `orderedCustom: true`. `click`, `:499–520`, **синхронно в обработчике
tap**, до `perform` и его Task, вызывает `events.root(...)`. Внутри последующей
mutation ждёт уже созданный receipt; прямого `actions.click` для этого Custom пути
больше нет. Обычный Text сохраняет отдельный прежний контракт.

`UI/PluginUIManagerWidgetEvents.swift:19–55` объединяет inline `send` и root в
одном `PluginUIManagerEventFIFO`. Root с callback кодирует `kind=click` с исходным
CBID; root без callback создаёт navigation barrier без Python callback. Обе формы
несут прежние owner/account/page invocation через TaskLocal; authority после
ожидания не захватывается заново.

Actual FIFO (`PluginUIManagerEventFIFO.swift:66–99`) сначала append-ит work, затем
единственный worker снимает первый элемент и **await-ит его operation**. Для
старого witness E1=`a` held → E2=`ab` accepted → root R очередь содержит
`E1, E2, R`; R не может оказаться в Host mailbox до E2. Root navigation также ждёт
barrier, поэтому смена страницы не отбрасывает обогнанный inline edit.

Cancellation и limits сохраняют ownership:

- `isCurrent` проверяется при enqueue, перед operation и после await;
- cancellation receipt отзывает **захваченную** invocation, не создаёт новую
  (`PluginUIManagerEventReceipt`, `:13–45`);
- `retainedCount` включает pending + running, bytes включают in-flight JSON;
  пределы — **128 entries / 512 KiB** (`:59–76`);
- close запрещает новые записи, отменяет pending/root и running invocation,
  возвращает только pending credit; running credit остаётся до unwind его await
  (`:89–114`);
- inline error завершает свой receipt и сохраняет порядок следующего work;
  preceding SDK value write не выдаётся за rollback.

Prepared native witness `ManagerCustomAliasNativeTests.swift:154–181` использует
**shipping FIFO** с held operation и требует `E1 → E2 → R:ab`; соседние cases
`:184–247` проверяют close, retained credit, обе квоты и error ordering.
Эти native tests здесь не исполнялись. Связь actual Controller → WidgetEvents →
FIFO подтверждена source, а original root Widget/zero-arg/Text argument contracts
проверены отдельно выполненным Python case.

**Итог MCA-F02:** прежний обход pending inline queue устранён; root и navigation
barrier имеют тот же порядок, что принятые edits.

## Проверка и execution boundary

Независимо подтверждены **17/17 уникальных applied postimage hunks** из handoff:
Model 2, Lifecycle 8, Bridge 6, BUILD 1. Scoped postimage hashes совпали с handoff;
вне этих regions не требовалось совпадение whole-file hash.

Выполнено на CPython **3.14.8**, command cap 30 seconds:

```text
python -B -m pytest -p no:cacheprovider -q tools/compat/tests/test_sdk_manager_custom_alias.py -k "deferred_refresh or root_callback_arguments" --basetemp <fresh approved opencode temp>
5 passed, 8 deselected in 4.31s
```

Все пять cases используют owned fixture и fresh `-I -S -B` children с 20-second
timeout. `deferred_refresh_commit` воспроизводит прежний reviewer witness:
после admission callback имеет **version 1**, после commit до ACK новый UI event
отклоняется, после ACK работает version 2, old stamp отклоняется. Остальные cases
проверяют rejected/disposed/overlapping update и root callback arguments.

Wire recorder исполняет actual SDK/Python, а native admission/commit моделирует
явно; он не является C/Swift/UIKit execution. **15 Python passes автора — отдельный
provided receipt.** Подтверждено наличие 12 native XCTest methods (5 прежних + 7
новых) и неизменённых 4 Host page-lease tests; native tests здесь не запускались.
Предыдущие pipeline/UI green и будущий fresh native CShim gate не включены в этот
результат. Физический native/recorded-frame acceptance остаётся отдельной границей.

## Read-time source pins

Для shared code — SHA-256 UTF-8/LF scoped text, включая leading indentation и
blank lines до следующего указанного marker. Runtime callback pin охватывает только
balanced closure до её `}` плюс LF, исключая соседний `classifyShareFile` argument.
Line spans относятся к этому чтению.

| Region | Lines | SHA-256 |
| --- | --- | --- |
| `UI/PluginUIBridgeExtension.swift`, uiUpdate case → uiState case | 199–235 | `4a747efcb114540b1fc92cdb672708d2f3071d29ed42c17879205e3121c60187` |
| `UI/PluginUIBridgeExtension.swift`, applyUpdate + canAct → handleEvent | 744–783 | `4ecfa4c48d8e2f8e3a88084fb99c119a0b67e9a704ca6681f06d705948cea751` |
| `UI/PluginUIBridgeExtension.swift`, deliveryCallback construction → hasPermission assignment | 66–81 | `09a117973c0add64df2023541b8eb4c3701f33ff8c37c25c64e2b4cdf87efec9` |
| `UI/PluginUILifecycle.swift`, reserveSettingsUpdate through action → Programmatic/native cancellation comment | 340–463 | `bfbe1e6b0233d92d09b330f6d4c2ce52da12b662fee14f8aafd4adf8def8169a` |
| `UI/PluginUILifecycle.swift`, completeRetirement → refresh | 493–506 | `e4b0965cf0feb3b124a6c03f486269d0a4f12c123c5ebfae7c3b5c617511638a` |
| `UI/PluginUILifecycle.swift`, delivery → valueCost | 543–556 | `a263dcdff61faeb9d09ef70787303e621fcac5d123cd7e4cfc00b01ad702d867` |
| `UI/PluginUILifecycle.swift`, retireLocked → outer closing brace | 571–610 | `1e54f17b4dd6b05c5082520a4045cd04749668160c87bb73111b16b7b46c7d69` |
| `UI/PluginUILifecycle.swift`, permitsCallback → beginPresentation | 295–312 | `811ef932e95df8956ad82c6ec69aedc935d787693e5750213f2896919a0bb127` |
| `UI/PluginUIModel.swift`, settingsSnapshotId validation | 512–516 | `3fe55c96f068a3492c34ee721b988f435b9bdd54018a4051ddf0b13c75d7279d` |
| `U/Exteraless/ExteralessPluginRuntime.swift`, только controlledCallback closure | 219–223 | `7fc33c21b09e21e84068c09d334c595eae45d3fcaf11c8980c7329e319b2fbde` |
| `H/PluginHost.swift`, performCallbackRelease → updatePluginFlags | 1565–1582 | `6e9c740f037ac1fb8237aed265143f335dd2415bbe51651637368e1cb2cca3e5` |

Raw-file pins текущих рассмотренных inputs и сохранённого старого review:

```text
301b669e23eeb7388810d699a27f91f16189f6d181070c7851480a417f1f4398  python/exteraless_runtime/_ui.py
70497a280c5ebc081e662fc72c656bb907df721981c19e2929f7c815e638c481  python/exteraless_runtime/_callbacks.py
38f236d16848b029246f5334ff782b3430a2e5bbf0df88ad85e933866b4ffec7  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUISettingsUpdate.swift
7279df92aa04a5c2770f0f604a7ea4db9ee89795e63094bbe1a82e7f8b7292ac  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerEventFIFO.swift
5ee852a44c138f80f11e3c5c9827aae20f93596bd204c68a8092b75c439b7c02  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerWidgetEvents.swift
bee70056fb61c58a40474631688be00ccccc96b4aca640e5c5b2e54533ead45e  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIReleaseQueue.swift
907f1c8f5efe3b167040c73d10c619b8bbe48cd7dd8fc5477b2cc1b4f441f76a  swift/PluginHost/Sources/PluginHost/PluginCallbackDispatcher.swift
3fb7c4c8051f9c2d1e322394199db080984722c7696d7f0057ba23ab2a71d708  telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsController.swift
e057f866789b0fe964d1f4ec54142ab315b0055a382fcd628b1f44b1aea45d2a  tools/compat/tests/test_sdk_manager_custom_alias.py
6ad9c7f24f20a3a2768c5b9b51ce65e4e27c7ff88728e92af904f11f6784c188  tools/compat/tests/fixtures/ios_runtime/manager_custom_alias.plugin
1213e394f6323c32b8f8d55bd532e2bd551658efe6baefa3be5e0da9948de45e  telegram-ios/Tests/ManagerCustomAlias/ManagerCustomAliasNativeTests.swift
083f795b3e8f246b7d517ef82e57eb09a8cce8f409c0ba0e133b11ac1b853269  swift/PluginHost/Tests/PluginHostTests/PluginSettingsPageLeaseTests.swift
395aecb4dd4e9ad9542e016cf7e6b97c656872ee943c0cbbd97d83fbae4536f3  docs/wave-2/reviews/manager-custom-alias-source-closure.md
```

**Заключение: MCA-F01 и MCA-F02 — CLOSED-SOURCE; точных оставшихся P1/P2 root causes
в проверенных двух schedules не выявлено.**
