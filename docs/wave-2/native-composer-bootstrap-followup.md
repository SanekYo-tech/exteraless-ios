# NEO-02 — Composer process bootstrap handoff

2026-11-16; source baseline `b06bb00064157eb2df3d21a3cf0166e8e33cd259`.

**Ready for the coordinator's Apple build/execution gate.** Реализованы process bootstrap до Composer root, реальные retention/API configurations на disposable inputs и явная передача startup failure в выбранные fixtures. Проверки ниже — **source/tooling**, не NativePASS или visual PASS. Локальная среда Windows; `swiftc`, `swift`, `xcrun` отсутствуют в PATH. CI/commit/push не выполнялись.

## Причина и исправление

[Исходный review, NEO-02](native-execution-orchestration-review.md#p1--neo-02--выбранный-composer-host-не-выполняет-обязательный-account-bootstrap) зафиксировал: `HarnessAccount.make()` открывает пустой Postbox до регистрации process retention/API environment. `Account.swift:914–934` в таком случае завершает первый open без Account; `panelHost` остаётся nil, а fixture ждёт внутри 30s class clock.

Теперь `Tests/ComposerHarness/Sources/AppDelegate.swift:44–53` выполняет `HarnessBootstrap.shared.prepare()` **перед** созданием `HarnessRootViewController`. Даже при ошибке сцена получает настоящий root с typed startup failure; он не открывает Account и показывает фиксированный stage в существующем readout. Это позволяет XCTest сообщить явную ошибку вместо ожидания nil root/panel.

### Новый `Sources/HarnessBootstrap.swift`

- Один `@MainActor` singleton хранит process-lifetime preparation result, UUID directory, private secret store и `ClientAPIConfigurationStore`. Результат подготовки, включая failure, повторно используется. Reentrant consumer видит `bootstrap-required`, пока подготовка не завершилась.
- Bundle identity: существующий `org.telegram.ComposerHarness`. Settings file: `FileManager.default.temporaryDirectory/composer-harness-bootstrap-<UUID>/native-client-settings.json`; новая директория создаётся с mode0700. **Durability root — настоящий `NSHomeDirectory()`**, не только новый temp leaf.
- `ClientSettings.shared.configure` получает этот file/private store/container; затем реально регистрируются `RetentionFeatures.definitions + ChatFeatures.definitions`. Retention получает полный текущий registered snapshot, роль `.mainApplication` и тот же OS container.
- Три Composer values совпадают с approved `ClientHarnessBootstrap`: `chats.showTextCreateDate=true`, `chats.stripTrackingOnPaste=true`, `chats.disableMarkdown=false`; запись идёт через настоящий `applyPublic(..., expected: readSnapshot())`.
- API environment настраивается настоящими `ClientAPIConfigurationStore` / `ClientAPIVault` / `ExteralessClientAPIEnvironment.configure`. Synthetic tuple побайтно совпадает с существующим ClientHarness counterpart; в runtime diagnostics она не выводится. Secret reads/writes и atomic insert-if-absent этой конфигурации используют один process-private dictionary под `NSLock`.
- `@unchecked Sendable` ограничен только этим lock-protected private store, реализующим оба Sendable storage protocols. Новые mutable singleton fields изолированы `@MainActor`; blanket unsafe global annotations нет.
- `composerHarnessAccountWithReadiness()` подписывается на настоящие `ExteralessAccountRecoveryCenter.pending` и API error signal **до** вызова `HarnessAccount.make()`. Проверяется current retention configuration. Retention failure/API rejection и завершение factory без value становятся typed failures. Успешное значение поступает только из реального двухпроходного factory после его собственного native readiness/transfer barrier.
- Все три subscriptions закрываются при terminal result/disposal. Существующий `HarnessAccount.make()` продолжает создавать и удерживать Account/AccountManager/Logger, выключать log sinks и устанавливать closed loopback proxy до первого account open. Его queue-affine retention/disposal код не переписывался.

### Передача ошибки

`HarnessStartupFailure` содержит только фиксированные stage-коды и предоставляет `LocalizedError`. Исходные exceptions, paths и credentials не форматируются. `HarnessRootViewController.swift:45–78` проверяет preparation перед account subscription, сохраняет первую typed failure и выдаёт `COMPOSER_HARNESS_STARTUP_FAILED <fixed stage>`; `refreshReadout` сохраняет это сообщение.

`Tests/HarnessEngineTestSupport.swift:11–23` бросает сохранённую ошибку до загрузки view, на каждом проходе ожидания и после него. Существующие deadline30s, RunLoop interval20ms и `settle` не изменены. Process alarm в Composer host не добавлялся: native execution clock остаётся у coordinator driver.

## Paths и source identity

| Изменённый путь | Назначение |
| --- | --- |
| `telegram-ios/Tests/ComposerHarness/Sources/HarnessBootstrap.swift` | Новый process bootstrap, private store, sanitized errors, typed account readiness adapter |
| `telegram-ios/Tests/ComposerHarness/Sources/AppDelegate.swift` | Bootstrap до root construction; error передаётся в root |
| `telegram-ios/Tests/ComposerHarness/Sources/HarnessRootViewController.swift` | Preparation guard, error-aware account subscription/readout |
| `telegram-ios/Tests/ComposerHarness/Tests/HarnessEngineTestSupport.swift` | Startup failure немедленно выходит из fixture wait |
| `telegram-ios/Tests/ComposerHarness/BUILD` | Один прямой `ExteralessCore` dependency у `ComposerHarnessLib` |
| `tools/ci/tests/test_native_composer_cohorts.py` | Три source regression checks плюс проверка discovery нового input |

`ComposerHarnessLib.srcs = glob(["Sources/**/*.swift"])` автоматически компилирует новый файл. `native_test_plan.host_inputs` захватывает тот же glob. Проверенный plan содержит **370 inputs**, включая `Tests/ComposerHarness/Sources/HarnessBootstrap.swift` с точным ready hash ниже. Правки `required_sources`/агрегатного BUILD suite не нужны.

Карта после изменения: **37 targets / 89 required XCTest sources / 92 classes / 434 methods**. Два Composer класса содержат прежние **5+7 methods**; оба fixture файла целиком byte-identical, то есть их method IDs, bodies и schedules сохранены. Recording selection по текущим scenario constants — **20 scenes**. Полный acceptance fingerprint координатор пересчитывает после объединения параллельных handoffs.

## Bounded проверки

Все локальные команды имели внешний timeout **30s**.

1. `python -B -m unittest tools.ci.tests.test_native_composer_cohorts -v`
   - До реализации: **4 failures / 8 checks**, включая отсутствие bootstrap до root и нового host input (0.561s).
   - После реализации: **8/8 PASS**, 0.525s.
   - Новые проверки используют существующий Swift comment/string scanner и проверяют порядок живых calls: owned seed → configurations → account open; real snapshot/container/private stores; readiness failure → throwing fixture guard. Это проверки source wiring, не замена Swift compiler/runtime.
2. Read-only `build_plan(..., source_checkout=True)`: 37/92/434, новый source input/hash, обе byte-identical selected fixtures и 20 scene constants подтверждены (0.544s).
3. Оба AppContext outputs воспроизведены **в памяти/stdout** существующим `generate_harness_stubs.py` с аргументами из их headers: **34 AccountContext +243 SharedAccountContext stubs**, точное совпадение text после нормализации LF (0.196s). `makeShareScreen` остаётся именованным trapping stub. Generated files не перезаписаны.
4. Scoped `git diff --check` и проверка UTF-8/LF/trailing whitespace всех шести source/checker files прошли. Imports нового Swift файла соответствуют существующим direct edges плюс добавленный `ExteralessCore`.

Apple compilation, действительное открытие двух Postbox passes и выполнение всех 12 выбранных UIKit methods остаются задачей coordinator execution gate. Здесь не создавались Account doubles, fake successful readiness/configuration responses или дополнительные XCTest methods.

## Exact ready SHA-256

Хеши **сырых файловых bytes** (UTF-8/LF), а не нормализованных Git blobs:

```text
2de2f31429717a9ba3e52451b3a46b3dddfb1e9ed48f2d53776405fd9e5b4f46  telegram-ios/Tests/ComposerHarness/BUILD
907c10d0e1f789ab6c95b1de1f05200ef90d310be199905e516acc128562ec47  telegram-ios/Tests/ComposerHarness/Sources/AppDelegate.swift
60e96f83c0296584cf1b11fbf45793a282e8a7311f3c53a2af4295733ed05a02  telegram-ios/Tests/ComposerHarness/Sources/HarnessBootstrap.swift
0f18c4e980b93867f9c905faa412e43924a3f7c30562ee8d745fee52deafa09a  telegram-ios/Tests/ComposerHarness/Sources/HarnessRootViewController.swift
2b84a6c958f7d4173c4f6001e768481c67b56afc7db7a059b3847dbc0a06a656  telegram-ios/Tests/ComposerHarness/Tests/HarnessEngineTestSupport.swift
a8cb86e3ced40dc90d28dbd63bf646585105ca91420aefe065116b72cd054dc0  tools/ci/tests/test_native_composer_cohorts.py
```

Source packet SHA-256: **`bca90363f793a80e9c6308cba48298f3b882a9dd80ff882c2832b975f26be527`**. Вычислен по отсортированным выше repo paths: конкатенация `sha256 + "  " + path + "\n"`, UTF-8. Этот checksum охватывает шесть source/checker files, не является полным cohort/native execution receipt.

### Подтверждённые сохранённые inputs

```text
4a97c08c94b341bb473e983393ff80d18b8dbe6d5a9083a160b788a3366cbe75  telegram-ios/Tests/ComposerHarness/Tests/HarnessComposerSelectionActionTests.swift
45dedcc1e94238bd8a89b48babc5a599a6982f0d950837b3dc532efaf9103252  telegram-ios/Tests/ComposerHarness/Tests/HarnessComposerPlainPasteTests.swift
c609bdbef7c4671bf9dda0cf22f4b51ce364dbb31539430d0de8864e0a0ba47c  telegram-ios/Tests/ComposerHarness/AppContext/HarnessAccount.swift
66e09640edc91333ccfa3e61c32d27dcde3332cc6ca0677d0b1cca50b356704e  telegram-ios/Tests/ComposerHarness/AppContext/HarnessProcessRetainer.swift
eb3cae8166d82748900450ab28e352d2f37ed782280a114780e7ea882e49b405  telegram-ios/Tests/ComposerHarness/AppContext/HarnessAccountContext+Generated.swift
324c8f69c2670e608fdc9cecddea0d0c067e4b8cdebf35616212f7fe6f5a630d  telegram-ios/Tests/ComposerHarness/AppContext/HarnessSharedAccountContext+Generated.swift
7a47432da72b63afdd12a2850b5e336ee7504e614fadfd1bfb692d69a673b72a  docs/wave-2/native-execution-orchestration-review.md
```

NEO-01/cache, NEO-03/workflow и Glass handoffs принадлежат другим владельцам; их working-tree изменения не входят в этот source packet.
