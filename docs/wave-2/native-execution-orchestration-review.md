# Native execution orchestration — independent source review

2026-11-16. Baseline: `b06bb00064157eb2df3d21a3cf0166e8e33cd259`.

**Вывод: два подтверждённых исходниками P1 перед следующим execution gate; отдельно P2 для получения диагностических кадров при native failure.** Полный native/visual PASS этот review не устанавливает.

Read-only проверка execution orchestration, выбранных fixture entry points и recording/evidence gates. Локальный `build_plan(..., source_checkout=True)` дал **37 targets / 89 required sources / 92 classes / 434 methods**. App/Harness build/package PASS и runtime33 PASS — входные сведения координатора, не повторно выполненные здесь проверки. Cache/reclamation/current compile failure и Glass fixture — за пределами review. Production/tooling файлы не изменены, CI/network/native execution не запускались.

Ожидаемые кадры уже определены в [ui-harness.md](ui-harness.md#sdk-followup--configured-control-frame-contract-2026-11-16), [Map handoff](map-attribution-native-handoff.md#frame-expectations--established-before-recording) и [SDK followup](native-gate-sdk-followup.md). Ниже они не переопределяются.

## P1 / NEO-01 — run-only меняет build input собственного runner script

**Где:**

- `tools/runtime/run_native_integration_tests.py:344–345,385–393`: compile без test environment; каждый run-only добавляет `STARTUP_TIMEOUT_SEC=150`.
- `telegram-ios/build-system/Make/Make.py:387–404`: `--test_env` добавляется только внутри `if not build_only`; run-only одновременно получает `--check_up_to_date --nocheck_tests_up_to_date`.
- `telegram-ios/build-system/bazel-rules/rules_apple/apple/internal/testing/apple_test_rule_support.bzl:298–305,354–370`: `ctx.configuration.test_env` входит в substitutions для **`ctx.actions.expand_template`** исполняемого test wrapper.
- Там же `:148–160`; `apple/testing/default_runner/ios_test_runner.template.sh:107,170`: environment записывается в текст shell script; startup timeout уже имеет default **150**.

**Почему блокирует:** это не только runtime environment `TestRunnerAction`. Добавленный исключительно на execution фазе `--test_env=STARTUP_TIMEOUT_SEC=150` меняет генерируемый wrapper после завершённого build. Для его обновления нужен build action, который run-only намеренно запрещает. Первый класс может не дойти до XCTest даже при полностью исправных compile outputs. Repository `.bazelrc:1–29` не задаёт этот environment заранее.

Read-only вызов реального `get_test_arguments` через существующий command fixture подтвердил разницу:

```text
compile:  no --test_env
run-only: --test_env=STARTUP_TIMEOUT_SEC=150
          --check_up_to_date --nocheck_tests_up_to_date
```

Это source/command доказательство нового action input, не наблюдение сообщения Bazel с macOS.

**Минимальный предлагаемый patch:** убрать `test_environment=['STARTUP_TIMEOUT_SEC=150']` из execution invocation. Сохранить template default 150 и runner BUILD environment `NSUnbufferedIO=YES`. Это устраняет расхождение без разрешения build actions во время run-only и без изменения 30s logic cap. Если environment действительно понадобится, он должен быть одинаковым build input у preflight/build/run; простая передача `test_environment` в нынешний `build_only=True` не поможет — Make его там игнорирует.

Изменение driver участвует в source identity (`native_test_plan.py:305–306`, `client_ui_harness_inputs.py:16–29,162–167`); координатору нужен согласованный build/plan/recording snapshot с этим исправлением.

## P1 / NEO-02 — выбранный Composer host не выполняет обязательный Account bootstrap

**Где:**

- `telegram-ios/Tests/Exteraless/native-tests.json:13–21`; `Tests/ComposerHarness/BUILD:256–280`: два выбранных класса действительно запускаются в `ComposerHarness`, с точными BUILD filters.
- `Tests/Common/Main/main.m:3–6`; `Tests/ComposerHarness/Sources/AppDelegate.swift:16–49`: настоящий scene entry создаёт `HarnessRootViewController`.
- `Tests/ComposerHarness/Sources/HarnessRootViewController.swift:28–55`: `viewDidLoad` сразу подписывается на `HarnessAccount.make()`; `panelHost` создаётся только при получении account.
- `Tests/ComposerHarness/AppContext/HarnessAccount.swift:40–69,81–145`: `initializeAccountManagement()`, затем первый open пустого Postbox, запись authorized state, второй open. Process retention/API configuration здесь отсутствует. `submodules/TelegramCore/Sources/Account/AccountManager.swift:257–259` только регистрирует encodables.
- `submodules/TelegramCore/Sources/Account/Account.swift:67–82,914–934`: retention environment первоначально `.failure(.unavailable)`; неавторизованный первый open при отсутствии configuration возвращает `.complete()` без account. Следующий барьер требует настроенный API environment.
- `submodules/TelegramCore/Sources/ExteralessClientAPI/ExteralessClientAPIEnvironment.swift:8–13,36–50`: resolver первоначально `nil`; `arguments` бросает `bootstrapRequired`.
- `Tests/ComposerHarness/Tests/ComposerSelectionActionFixture.swift:7–18`: selected `setUpWithError` регистрирует/меняет только Chat settings. Обе process configurations не устанавливаются.

**Почему блокирует:** на каждой fresh installation/process глобальные environments пусты. Первый `accountWithId` завершается без `.unauthorized`, поэтому двухпроходный account producer не выдаёт `HarnessAccount`; root остаётся без `panelHost`. Наличие правильного scene-based host и ресурсов это не исправляет. Другие native классы не могут подготовить эти globals: driver запускает каждый класс отдельно.

По текущему порядку это **классы 87 и 88**: `HarnessComposerSelectionActionTests` (5 methods), `HarnessComposerPlainPasteTests` (7). `Tests/ComposerHarness/Tests/HarnessEngineTestSupport.swift:11–20` ждёт `panelHost` до **30s уже внутри XCTest**. Поскольку внешний clock начинается раньше, на suite-start, первый root-dependent method исчерпает class budget; при ещё не подключённой сцене возможен более ранний `XCTUnwrap` failure. Это конкретная невыполненная prerequisite, а не предположение о медленном simulator.

Такая подготовка уже реализована в другом app entry: `Tests/ExteralessHarness/Sources/ClientHarnessBootstrap.swift:33–68` конфигурирует isolated settings, registered retention snapshot/OS container и synthetic private API store **до** открытия Account; `ClientHarnessApplication.swift:186–208` соблюдает этот порядок. `ClientHarnessReadiness.swift:11–45` также сохраняет typed failure вместо молчаливого ожидания account.

**Минимальный предлагаемый patch:** в существующем Composer test-app bootstrap, до создания/root loading и `HarnessAccount.make()`, выполнить ту же настоящую подготовку process retention/API на собственном disposable store и правильном OS container; добавить прямой BUILD dependency для используемых Core типов. Успешное получение account должно по-прежнему проходить реальный readiness barrier. Ошибку bootstrap передать fixture как ошибку, а не оставлять `panelHost == nil` до watchdog. Сохранить оба выбранных класса, все 12 methods и внешний 30s cap.

## P2 / NEO-03 — native failure лишает независимой диагностики все recording batches

**Где:**

- `.github/workflows/client-ui-harness.yml:124–153`: успешный full app build предшествует native gate; frame tools и все recording steps имеют обычный success dependency.
- Там же `:154–279`: все 20 scenes зависят от native step; `always()` есть только у upload/status.
- `tools/runtime/record_client_ui_batch.py:28–41`: `verify_native_results` вызывается **до запуска** recorder и до создания его report.
- `tools/runtime/client_ui_harness.py:407–418,428–491`: нижний recorder не принимает native result вообще. Он проверяет IPA/staging, создаёт owned simulator, запускает реальные сцены и извлекает кадры, включая доступные partial failure recordings.

**Следствие:** даже после пригодного App/Harness build/package native compile/execution failure даёт ноль попыток записать UIKit. Это объяснимый dependency graph, но он блокирует запрошенную предварительную frame диагностику. Просто добавить `if: always()` к нынешнему wrapper недостаточно: его native admission всё равно откажет до recorder. При таком отказе отсутствие `acceptance.json` означает «не запускалось», а не пустой успешный UIKit report.

### Опциональный минимальный workflow-only diagnostic path

**Разделение collection/admission уже поддерживается существующими tools; новый harness не нужен.** Наименее затратный вариант — opt-in diagnostic fallback после неуспешного native step, в тех же recording time slots. Так кадры доступны до следующего NativePASS, без второго комплекта из девяти recording batches в одном job.

Предлагаемые изменения workflow, не применённые здесь:

1. Дать existing full-build/native/frame-tools steps `id`; добавить boolean dispatch input `diagnostic_recordings`.
2. Разрешить frame-tools и каждый из девяти recording batches по явному условию: job не cancelled, full-build успешен, и либо native успешен, либо включён diagnostic input и native failed. Перед переходом от failed native execution требуется подтверждённый cleanup его owned simulator; одновременный запуск native и recording исключён.
3. При native success использовать нынешний `record_client_ui_batch.py`. При native failure вызвать **существующий `client_ui_harness.py`** с той же retained IPA, staging path и точным списком scenarios этого batch, через тот же `client_ui_harness_workspace.py exec` и прежний hard envelope.
4. В diagnostic branch выполнить до и после recorder существующий `require_build_identity(build, build_plan(...)[0], harness_inputs(...), load_staging_manifest(...), ipa)`. Post-check выполнить и после nonzero recorder return. Сохранить отдельный diagnostic source-identity receipt и исходный exit status. Этот guard нужен сверх собственного `verify_ipa`: именно он связывает текущий harness/driver с compiled acceptance snapshot.
5. Использовать свежие `diagnostic-recordings/<batch>/` directories; добавить их к existing always-upload. Не создавать для них `batch-identity.json` с утверждением native PASS. Explicit conditions остальных diagnostic batches позволяют им собраться после failure соседнего batch; внутри одного batch recorder сохраняет свой fail-fast и partial evidence.
6. Финальные `verify_client_ui_batches.py` / `verify_client_ui_supplements.py` допускаются лишь после реального native PASS и полного обычного recording path. Native step остаётся failed при failure: `continue-on-error` для его «озеленения» не требуется.

Это сохраняет обязательный финальный порядок **434 native methods → 20 fresh scene processes / 9 serial fresh simulators → frame review**. Diagnostic output не удовлетворяет финальному gate. Если нужна запись буквально *до первого native invocation*, дополнительный pre-native diagnostic pass потребует отдельного budget; повторять все batches дополнительно под текущим cap без пересчёта не следует: их текущие hard envelopes уже составляют **2760s** (3×600 + 3×180 + 120 + 150 + 150).

## Проверенные execution contracts и границы выводов

### Actual pinned Apple runner, filters и stdout

Прочитан локальный архив `build/wave-2-dependencies/xctestrunner-4c6f493.tar.gz`, SHA-256 `4567932c7309b29092ec45c5a0deac75d68af987a3b1112cfdd790b4cffaded4`, совпавший с `xctestrunner-serial-proof.json`. Выбранная version/patch: `telegram-ios/MODULE.bazel:221–228`. Следующие ссылки `xctestrunner/...` обозначают файлы внутри этого архива, не другую/latest версию.

| Проверка | Вывод по фактическому producer/consumer |
| --- | --- |
| Exact class selection | `ios_test_runner.template.sh:181–229` объединяет BUILD filter и `TESTBRIDGE_TEST_ONLY` в union. `run_native_integration_tests.py:385–390` корректно не добавляет CLI filter к трём уже отфильтрованным targets; остальные получают один class name. `native_test_plan.py:244–268` запрещает list/wildcard BUILD filters. |
| Runner read gate | `xctestrunner/test_runner/xctest_session.py:163–175` передаёт `tests_to_run`; `xctestrun.py:122–142` записывает `OnlyTestIdentifiers`/`SkipTestIdentifiers`. Формат — `Class[/method]`. Признаков обязательного module prefix или потери текущего filter нет. |
| Owned destination | Template `:37–41,257–269` преобразует `--destination=platform=ios_simulator,id=<udid>` в `test --platform=ios_simulator --id=<udid>`; `ios_test_runner.py:140–175` принимает именно это. Serial patch добавляет `-parallel-testing-enabled NO` в `xctestrun.py:176–179`. Выбранные 37 rules не задают `env`, `env_inherit` или `args` с конкурирующим simulator selection. |
| Environment names | `STARTUP_TIMEOUT_SEC` потребляет shell template `:170`; `NSUnbufferedIO` задан runner BUILD `Tests/Exteraless/BUILD:13–18` и передаётся в XCTest environment. Родительский `PYTHONUNBUFFERED` сам по себе не доказывает наследование Bazel test action, но actual executor явно делает `print(..., flush=True, end='')`. |
| Streamed XCTest | `xctestrunner/test_runner/xcodebuild_test_executor.py:167–200` читает объединённый xcodebuild stdout/stderr построчно и немедленно flush'ит. `Make.py:391` выбирает `--test_output=streamed`. Источниковая цепочка совместима с `LogicClock`; реальная задержка доставки на Xcode 27 не измерялась. |
| First suite clock | `run_native_integration_tests.py:70–106` начинает 30s на **первом** native suite-start, включая `All tests` / `Selected tests`, до class setup. In-memory grammar checks обоих имён прошли; выбор класса дополнительно проверяется по всем started/passed methods. Перенос старта после setup необоснованно ослабил бы текущий контракт. |
| Retries | Bazel attempts/runs равны 1. Actual executor `:150–164,202–224,245–282` всё ещё допускает до трёх **pre-suite startup attempts**. После `Test Suite` он возвращает результат без такого retry. Это не доказательство повторного выполнения XCTest methods; startup retries надо учитывать в preparation measurements. |
| Cancellation | `run_native_integration_tests.py:158–185,122–134` проверяет phase/global deadline, прерывает owned Bazel client group и вызывает shutdown owned guest перед ожиданием Bazel. `:192–215,402–407` проверяет UUID/name/type/runtime и удаляет guest. Это fail-closed protocol, не измеренное доказательство мгновенного прекращения guest logic точно на 30.000s: ownership query/shutdown — отдельные bounded commands. |
| Native resource prerequisite | `native_test_resources.py:12–38` требует обе реальные host IPA, bundle IDs, fonts/Monet и nonempty strings/assets перед execution. Оба host BUILD resources включают `TelegramUIResources`, а `submodules/TelegramUI/BUILD:10–16` включает `ExteralessMonetNotices`. Источникового missing-resource blocker здесь не найдено; фактические compiled native-host IPA этим review не проверены. |

### 900s / 2000s: тесный envelope, но не доказанная невозможность

- Driver `:260,319,361–393,428–432`; workflow `:133–143`: compile/analysis ≤900s, execution loop ≤900s, внутренний общий deadline 2000s, внешний owned command 2100s. Boot предшествует execution deadline; cleanup reserve сокращает его по `min(now + execution_seconds, overall_deadline - 150)`.
- **900 / 92 = 9.783s на класс в среднем** для полного serial цикла, не только методов. Есть 92 Bazel test invocations, 92 uninstall/get-container pairs, 184 per-class single-simulator checks; template `:55–90` заново готовит test/host bundles. Один simulator boot на cohort, не 92 boot.
- Если compile phase использует 900s, а `boot` + `bootstatus` свои 30+150s, на class loop остаётся **не более 770s** до точки `overall_deadline - 150`, ещё до вычитания остальных pre/post-compile и device setup расходов: максимум 8.370s/class. Длительности aquery/compile не измерены здесь.
- Per-class 180 preparation / 30 logic / 60 finalization — потолки, **не обязательные затраты**. Сумма `92 × 270` не доказывает, что run не укладывается. Pinned runner не содержит обязательного фиксированного install delay на здоровом пути; его 2s stuck-thread polling (`xcodebuild_test_executor.py:72–88`) и conditional retry sleeps нельзя складывать как 92 неизбежные задержки.
- Для поздних Composer classes explicit requested settles составляют **1.05s** у selection (5 arrangements и 6-region loops) и **1.71s** у paste (включая два legacy arrangements по 0.6s). У пяти paste operations дополнительно есть readiness polling ≤1s каждое. Это суммы заданных ожиданий в `HarnessComposerSelectionActionTests.swift:58–67,118–253`, `HarnessComposerPlainPasteTests.swift:26–30,41–150`, `HarnessLegacyTestSupport.swift:20–30`, не native duration. До устранения NEO-02 их account readiness wait не завершается.

**Inconclusive:** нет распределения setup/install/xcodebuild/finalization durations для 92 compiled classes; объявлять общий 900s deadline заведомо невыполнимым нельзя. Для решения об envelope нужны per-class monotonic measurements этих фаз при сохранённом 30s logic cap. `logic_seconds` и preparation уже записываются (`run_native_integration_tests.py:117–119`); uninstall/setup и finalization пока не выделены в class receipt.

### Exact runtime availability

`select_runtime` (`run_native_integration_tests.py:47–60,278–280`) требует ровно один доступный generic **iOS 27.0** runtime и exact `iPhone 17` type с подходящим `supportedDeviceTypes`. Xcode 27.1 / SDK major 27 не доказывают наличие именно этого runtime. Текущий app preflight (`client_ui_harness_build.py:175–193`) проверяет Xcode, не этот `simctl` contract.

**Inconclusive:** актуального device/runtime inventory runner здесь нет; CI не опрашивался. Нельзя утверждать ни availability, ни missing-runtime blocker. Минимальная подготовка следующего gate — выполнить существующий exact selection как cheap preflight до дорогого full build; fallback на другой OS/type не нужен.

## Actual iOS FD prerequisites в существующем Harness CPython path

Проверены actual Swift→Python source assembly и consumer, а не Mac receipt:

- `ClientHarnessRuntime.swift:35–42,90–113` использует `PythonRuntimeConfiguration.standard(bundle: .main)`, затем реальные `Bundle.main.resourceURL/python`, `/sdk`, `/vendor` и собственный plugin directory. `swift/PluginHost/Sources/PluginHost/PythonRuntime.swift:70–92,100–136` формирует bootstrap с runtime paths; `PluginRuntimeProtocol.swift:6–14` JSON-quotes строки с сохранёнными `/`.
- `python/exteraless_runtime/__init__.py:34–40,61–94` находит SDK по загруженному `__file__`, создаёт dependency provider до loader install. `_dependencies.py:153–213` находит vendor относительно **фактически загруженного runtime package**, проверяет полный approved manifest/.dist-info и восстанавливает его после SDK (`:48–67`). `prepare_telegram_runtime.py:329–335` стадирует sealed vendor в actual resources. Hard-coded build-host vendor root в этой цепочке не найден.
- Поэтому при отличающемся import/template layout необходимо совпадение трёх фактических anchors: bundle configuration paths, runtime package `__file__` и соседний sealed `vendor`/`sdk`. Один `sys.path` entry на чужой vendor недостаточен. Если рядом с импортированным runtime нет `vendor`, `create_provider` возвращает пустой provider (`_dependencies.py:157–160`); у fixture `__requirements__=[]` (`client_ui_fixture.plugin:6`) это само по себе не доказывает полноценный dependency import test. Буквальный producer/symbol `TemplateImports` в просмотренной текущей source цепочке не найден; отдельный такой layout без точного input здесь не верифицируется.
- `PluginHost.swift:1174–1183,1234–1243,1735–1758` даёт один metadata inspector и два source-plugin owners на enable/re-enable; дополнительная staged metadata reinspection в install относится к archive branch. `PluginRuntimeScript.call("load_json", ...)` действительно начинается с prefix, который наблюдает `ClientHarnessNativeObservation.swift:44–87`.
- Observer вызывает byte-identical bundled helper после successful real load на том же worker, сверяет actual `sys.platform == "ios"`, ID/thread/owner и читает helper hash. Python string из Swift был отдельно **скомпилирован в памяти только на syntax**, без исполнения. `ClientHarnessScenarios.swift:183–212` требует второй owner и завершённый cleanup.
- Helper `Fixtures/native_plugin_probe.py:151–198` должен реально выполнить `_Extraction`, allowed asset-FD write, denied code-FD/dir_fd writes, F_GETPATH/samefile и descendant-symlink rejection, затем выйти через cleanup. Runtime iOS branches — `python/exteraless_runtime/_audit_paths.py:163–193,307–337`. Флаги не заменяются Mac значениями.
- `tools/runtime/native_fd_evidence.py:22–44` требует **две** observations, четыре separately counted helper script calls, distinct created/destroyed interpreter references, оба owner tokens, actual iOS/builtin bridge/current helper hash, initialize/finalize 1/1. `client_ui_harness.py:226–239` применяет это к `sdk-ui`; empty/missing FD report не принимается.
- Initial Python/bootstrap/первый FD witness входят в ожидание `ready` **≤10s с запуска** (`client_ui_harness.py:312–323`; `ClientHarnessApplication.swift:263–278`), а оба witnesses вместе с UI/reload/cleanup — в **30s process cap**. Native `Main/main.m:5–16` ставит `alarm(30)` независимо от main loop. Сколько это занимает на текущем simulator, source review не устанавливает.

**Итог FD scope:** необходимые wiring/identity checks присутствуют; подтверждённого baked-vendor-path blocker в текущем Harness path не найдено. Actual iOS FD outcomes для обоих owners остаются невыполненной здесь проверкой. Standalone Mac/Darwin checks, compilation и screenshot source этого результата не дают.

## Финальный evidence admission

`native_test_plan.py:96–124` требует все source-derived classes/methods в точном порядке, identity и phase budgets. `verify_client_ui_batches.py:22–45,48–98` требует native PASS и полные 3+3+2 recordings; `verify_client_ui_supplements.py:16–56,65–72` добавляет десять Reset, trust и Map, всего **20 scenes / 9 разных simulator IDs**.

Recorder использует `simctl recordVideo`, реальные H.264 frames, `ffprobe` timestamps и `animation_sheet.py` (`client_ui_harness.py:324–345,369–404`). `recorded_frame_index` (`client_ui_harness_visuals.py:231–277`) связывает probes с PTS brackets, не с `index/fps`. Возвращаемый статус намеренно **`recorded-awaiting-visual-review`**, не visual PASS. `last-screen.png`, native hierarchy PNG или исходники ожидаемых сцен не заменяют покадровую acceptance по уже заданному контракту. Этот workflow также не выпускает финальную device unsigned IPA: его build configuration и retained archive — `debug_sim_arm64` (`client_ui_harness_build.py:240,281–296`).

Review artifact: только этот документ. Остальные текущие working-tree изменения принадлежат параллельным владельцам.
