# HNS-F01–F04 — final source closure

**Итог: 4/4 исходных counterexamples закрыты на уровне source. Остаточных P1/P2 в этих четырёх сценариях не обнаружено.**

Проверено текущее рабочее дерево при HEAD `0ceafb7bc7c12774f40fcb9f4947e593c05aab0b`, с учётом `plugin-ui-remediation.md`, `tl-review-remediation.md` и `sdk-adapters-final.md`. Это ограниченная closure предыдущего follow-up, не повторное полное ревью инфраструктуры.

## F01 — поздние UI/TL effects после revocation родительского batch: CLOSED-SOURCE

- **UI:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIRetainedEffect.swift:11–21` создаёт общий `PluginNativeCallLease` на исходном worker и сохраняет его рядом с budget ticket. Production provider захватывает execution до main/readback hop (`PluginUIBridgeExtension.swift:127–136`), объединяет его с owner/account/permission (`:396–402`) и повторяет проверку перед clipboard sink и deferred URL continuation (`:284–314`). При A completed → B timeout/cancel старый эффект A теперь получает revoked guard, хотя owner A остаётся loaded. Credit удерживается до завершения/освобождения реально retained work.
- **TL:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift:212–258` захватывает parent guard на C worker, сохраняет его в ticket и включает в `nativeCancellation`. `startText` передаёт именно этот predicate (`:294–301`) до Core commit permit (`telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLRequestOrigin.swift:231–251`). Проверки после bot authorization и перед transaction writes остаются подключены. Revocation не снимает ownership credit раньше control-release admission (`PluginTLBridgeExtension.swift:425–439,447–479,515–520`).
- **Callback / Network стыки:** Runtime действительно передаёт пятый TL predicate как `shouldExecute: $4` (`telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:167–175`). Обе cold fast paths проверяют descriptor execution (`telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift:1409–1418,1490–1499`); ordered final admission проверяет original **и** final description до privacy admission (`telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift:281–301`). Исходный потерянный guard не заменён whole-hook bypass.
- **Fixtures:** прочитаны actual UI consumer cases `PluginUIRemediationFixture.swift:477–582` и четыре `telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift:165–214`: timeout/cancel, deferred guard, cleanup pressure и successful-parent control. Это подготовленные consumer/Host fixtures; их native выполнение здесь не заявляется.

## F02 — queued `create_settings` retargets replacement owner: CLOSED-SOURCE

- `swift/PluginHost/Sources/PluginHost/PluginHost.swift:1067–1092` фиксирует owner до queue hop. `CreateSettingsPayload` несёт native-only owner/guard; EventBus объединяет guards и проверяет captured owner (`swift/PluginHost/Sources/PluginHost/ExtensionPoints.swift:189–213,412–433`). Dispatch выбирает только captured interpreter и передаёт predicate на actual worker (`PluginHost.swift:1383–1395`). Старый queued read не разрешается заново в P2.
- UI захватывает отдельный read invocation до `perform`/Task и переносит его через typed TaskLocal (`telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsController.swift:23–25,45–50,191–200`; `ExteralessClient/PluginUI/PluginUISettingsReadInvocation.swift:25–45`). Runtime читает token до `operationHost()`, передаёт exact owner/index/guard и сохраняет postcheck (`ExteralessPluginRuntime.swift:404–426`). Harness делает то же (`telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessRuntime.swift:143–149`).
- Пять `PluginSettingsReadExecutionTests` проверяют reload за другим plugin event, account expiry без смены interpreter, actual mailbox predicate, cancellation и невозможность заменить captured authority. Проверка отсутствия engine entry сохранена вместе с fresh-read positive control. Их green execution предоставлено координатором; reviewer прочитал код, но не запускал тесты.

## F03 — Set передавался в array API native probe: CLOSED-SOURCE

`python/runtime/smoke/swift_sdk_hns_probe.swift:82–83,155–156,195`: `grants` теперь `[PluginPermission]`, все три callsites передают массив с прежними ui/messages.read/network/files. Исходный type mismatch устранён. Это source closure конкретной ошибки, не утверждение, что весь native probe уже скомпилирован/выполнен.

## F04 — probe ожидал successful cleanup уничтоженного owner: CLOSED-SOURCE

`python/runtime/smoke/swift_sdk_hns_probe.swift:131–136,211–243` требует typed `SecurityError` на Host boundary для destroyed/replacement-stale token и проверяет неизменные provider cleanup/release counts и replacement resources. Общий Host validator сохранён (`swift/PluginHost/Sources/PluginHost/PluginHost.swift:598–601`).

Duplicate revoke перенесён в разрешённый retiring unload (`python/runtime/smoke/swift_sdk_hns_fixture.swift:81–109`): повторяются та же immutable identity и production NativeServices cleanup route; UI часть остаётся явно обозначенным stored-lease DTO recorder. Проверки SDK unload и единственного release не заменены успешным stale admission.

## Граница evidence

- Предоставленная coordinator receipt: `b5223dc0` / `43714325169`, **174 Host tests + 6 TBF continuation**, green; отдельно сообщён green `43c46497`. CI в этой проверке не читался. Итоговое количество Core tests здесь не подтверждается и оценка 609 не выдаётся за проверенный результат.
- **23 UI remediation scenarios, native TL consumer execution, real CPython children и production UIKit/recorded frames остаются отдельным pending gate.** Foundation/manual-main/DTO recorders и canned `CPythonEngine` не являются production UIKit или real-CPython execution.
- Новых runtime-прогонов reviewer не делал. Closure подтверждает соединение source-путей для четырёх исходных counterexamples.

## Source pins

Raw SHA-256 прочитанных ключевых inputs фиксирует рабочую версию; это не test receipt.

| Файл | SHA-256 |
|---|---|
| `swift/PluginHost/Sources/PluginHost/PluginHost.swift` | `db6dad816dcf11ccd82400f753c42dc46d20acfb4ec11fed33db541fb1435837` |
| `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift` | `6998d97a25376dcdc8f9b965ef5fcc4f1a3309b309b30fd74e9c90ed13f019ee` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIRetainedEffect.swift` | `96ace8e25fa0c32d304ce2828c7cfa3354b1bbb017fa17c00c773310e2a03e88` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift` | `60b9129f9424ada9d4a626336e01e69af2ce2044e04652b43fb07546de3a613c` |
| `python/runtime/smoke/swift_sdk_hns_probe.swift` | `e7afb3eb02dcea293eb5d3122dfa1db6c3dafffaffffabc8ace4adbc66f95afa` |
