# Elyx Mode ABA — sealed Linux native execution

**2026-11-16: PASS — [manual Linux run 43783735908](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43783735908), four native `NativeElyxModeABATests` passed, zero failures/errors/skips.** Build: **16.130 s / 120 s**; test process: **0.492 s / 30 s**; native XCTest suite: **0.031 s**. All source/span pins matched before and after execution.

## Immutable execution identity

- Branch: `ci/elyx-mode-aba-20261116-0b0bd7c67b`.
- Commit: `11b87846a487b62f0594fd0d28b83ce00c9929e4`.
- Direct parent: `a707e85bcf4ce8bce39029829acf7577b5d8950c`.
- Tree: `409172b749496b58000829a9513160dad80922cc`.
- Workflow: branch-only `.github/workflows/compat-tests.yml`, `workflow_dispatch` only; one Ubuntu 24.04 job, 15-minute outer bound.
- Toolchain: verified Swift 6.4.2, `x86_64-unknown-linux-gnu`, existing cache hit; `swift-frontend` SHA-256 `76db9f3dd8487a14ae39374509620e33af02f10da5dc42247406657832e4e9da`.
- Python 3.12; `pytest==8.3.5` supplies the bounded helper's import dependency.

The supplied `tools/compat/tests/test_native_elyx_mode_aba.py` CLI receives a fresh output directory. Its two native commands are preserved:

```sh
swift build --package-path "$PACKAGE" --scratch-path "$PACKAGE/build" --jobs 2 --build-tests
swift test --package-path "$PACKAGE" --scratch-path "$PACKAGE/build" --jobs 2 --skip-build --filter NativeElyxModeABATests
```

`run_bounded` enforces separate **120-second compile** and **30-second test** process-group deadlines. A branch-only Python profile observer records actual subprocess return values and drained output, including timeout output. Inherited `stdbuf -oL -eL` settings flush native console lines. The driver, helper, extracted Root code, commands and timeouts retain their sealed bytes/values.

## Sealed sources and spans

[Input seal](https://github.com/SanekYo-tech/exteraless-ios/blob/11b87846a487b62f0594fd0d28b83ce00c9929e4/docs/wave-2/native-elyx-mode-aba-inputs.json) SHA-256: `f26bf2af05449bffc832f33f9da7ee615fe86693aaf68db837fe61f75bcbec45`.

[CI source pins](https://github.com/SanekYo-tech/exteraless-ios/blob/11b87846a487b62f0594fd0d28b83ce00c9929e4/docs/wave-2/elyx-mode-aba-ci-pins.json) SHA-256: `e4bde4067a794071c32c37db59826b4f32d57a8273095f2e96d746e325660d56`.

The private snapshot includes all **64 fixture inputs**, the six sealed changed paths (overlapping the fixture inputs), the pinned native helper, and the seal itself: **67 caller files**. Workflow and observer pins bring the scoped before/after checks to **69 files**. The generator additionally verifies **13 byte-exact production spans** and **eight byte-identical UI/store copies**. Full per-file hashes, byte counts and Git blob identities are in the CI pins.

| Input | SHA-256 |
|---|---|
| `ExteralessPluginRuntime.swift` | `cd8829a64228253082717598b45e551e9b91c92e74684bef3734bd89678efbd7` |
| `PluginManagerPreferences.swift` | `3adb13b77a4fa351b9bfea3f0e21b9c7cf0f83b707795d095575d90797d3f962` |
| `ExteraConfigCompatibility.swift` | `35eee798ab988f79f6a2d77e512b8fedda06c1d2f3f41f4cc65e345b8e4ffefe` |
| `fixtures/native_elyx_mode/ModeABATests.swift` | `6ff47c162c7cd274f5361c3bed382b3f71daae004f201e08e19a4a1cf629506b` |
| `fixtures/native_elyx_mode/RootFixture.swift` | `39e5586750867ced1ced2d9347791515f7bd4cb4efbe708b0a96abb715702241` |
| `test_native_elyx_mode_aba.py` | `016b79f1b6135587567e8a20bdbddfc5e6785fcf52219b330119ce8339faa2b3` |
| `test_sdk_developer_native.py` | `eb57013f9f68a3e6bc1e43946d9e975601fae90f49e29f5d318a04bf3379ed93` |

The **64-input corpus SHA-256** is `76cbf37dc58dbebc3b55ae65e91b571ba2dffa7e41b491b78325c0a1db8ed104`; the **13-span corpus SHA-256** is `38566a2c315c574ae7fa1695da9584decec09f03bf8c3ae50391be9c53b0057d`. Each corpus hashes sorted UTF-8 `name + NUL + SHA-256 hex + LF` records for its own map.

| Exact production span | SHA-256 |
|---|---|
| `core.ExteraConfigCommandError` | `e7023721fe0ac4e0b2865a443305ac0bde24653d0c987ca6a560ff5fc5effe31` |
| `core.ExteraConfigCommandQueue` | `6389ed506300a1524edeb928442e0b805e190b219821c550135e1c6d3271ad18` |
| `core.ExteraConfigManagerMutation` | `0fb1940eb311109d1cc10f1a9eae25c5591b36fbd46e645e89149b733d478213` |
| `root.applyGlobalPluginConfig` | `928c27753688c316d7824e5c8a4139a7d97f8ab84f3edea3f577fb2873a06e3f` |
| `root.elyxActivationScope` | `2402cf0b5db800a8e4dc770fd27e17c2d8a10e32519f98b9937ff74da2103833` |
| `root.init.developer` | `9d42c5e65f82c145a0389434f6771ef78fdba716ca5dac9ff19b675cc9c74ffb` |
| `root.init.pluginConfig` | `548072b4772b2474ea146c49ef28672ce42aad71d5844cd3f73bbe36df91247e` |
| `root.pluginExecutionRequested` | `08d2b1b705fc5e4a9b03543b549ffc1aa25c35c86e3d72b79df0aced488e5b96` |
| `root.requirePluginExecution` | `275a43050d020f289e1358f0b32a17465a0659f7240d3aaf07385c69c072fec3` |
| `root.retireElyxDeveloperService` | `10f062e3e81169aafbb9ee1a80727dd609809e8e0567a64ec1c83beab9464da3` |
| `root.stopDeveloperServices` | `744335b4265b99683045ae228249f738892bc61055800157c15698b32222841a` |
| `root.updateDeveloperServer` | `5bb0a1e3b751c5f642e83528252645c7afbbea080916ed04406ebda836d685d0` |
| `root.updateManagerPreference` | `b59f3a84cb2b3a5607ec944b89c7ee63574e3bec1e7fa600b3dcd8ca619f14d4` |

The known post-seal `PluginElyxDeveloperFilesTests.swift` cancellable-waiter change is outside `fixture_input_sha256`. Its old test refresh was excluded; the base Host test tree is inherited. The fixture uses the explicitly pinned `HostLifecycleTestSupport.swift`. Local snapshot checks confirmed identical base/current-private-tree `python`, C shim and Host-test trees.

## Native results and retained evidence

The actual GitHub run conclusion is **`success`**, event **`workflow_dispatch`**, head SHA **`11b87846a487b62f0594fd0d28b83ce00c9929e4`**. Exactly one job ran: [133026605083](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43783735908/job/133026605083), **success**, `2026-11-16T01:01:02Z`–`01:02:39Z` (97 seconds). The run was created at `01:00:58Z`.

| Actual native test case | Result | Seconds |
|---|---|---:|
| `testAlreadyOffAndCoalescedOnControlsPreserveCurrentAuthority` | PASS | 0.010 |
| `testFailedOffWritePropagatesErrorAndRestartUsesFreshAuthority` | PASS | 0.007 |
| `testRejectedPermissionAuthorityAndContextCannotRetireCurrentDeveloperService` | PASS | 0.006 |
| `testTwoRealNativeQueuesCommitOffOnBeforeEitherActorContinuation` | PASS | 0.008 |

Both native subprocesses returned **0**. The supplied driver wrote `native-results.json` with **`native_execution: true`** and these four source-defined names. The original console stream contains exactly four starts, four passing finishes, and the completed `Selected tests` summary: **4 tests, 0 failures, 0 unexpected, 0.031 seconds**. Reporter errors and native compiler/test diagnostics: **none**.

Before/after verification independently matched all **69 scoped file pins**, **64 fixture inputs**, **13 exact spans** and **eight exact UI/store copies**. The two source/span JSON records are byte-identical. The caller's sealed files also remained hash-identical after artifact download.

Artifact: [**`elyx-mode-aba-posix-43783735908`**](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43783735908/artifacts/14189860664), ID **14189860664**, retention **14 days**, uploaded with `always()`. **36 files** were uploaded and downloaded; all **35 checksummed evidence files** matched `artifact-sha256.json`. GitHub's uploaded ZIP digest is `401173bb85ee7f18d0eac94defb39869ce12b15ae65bb3f83e09e764b7f3f6dd` (75,389 bytes).

| Downloaded evidence | SHA-256 |
|---|---|
| `inputs.json` | `6243e2eb05ad51bdd19ec58eafbc0012487cb18238e798a59f5eb4317b743f35` |
| `native-results.json` — supplied driver result | `1a378016e34586eb36b2a0eb8c9770703b8c8e08754ef3d8ee11bb8b6af1ff83` |
| `build.stdout.log` | `0bade1c03925122f24ffda38ba1a1f2a55138fab4c01dfa7a036376b006a6422` |
| `test.stdout.log` — original native events | `3a84d4b9ca4cd83839d6767de8ca1b90b50e67f3162d0d2e11eb2d6bb615bad5` |
| `native-xctest.xml` | `448d0089a764d1788004bf746f7dfb87acd909e1b58dfd30cf41b8ec0b3588eb` |
| `counts.json` | `ce9d0b57c6eaa197aef30f684637a2d5b54bd486d6c78a44c3a438cc8059146f` |
| `commands.json` | `3af562a81bfa308e9a210b0237f44fe408add83babbfd4ef966331be1d8267fc` |
| `source-span-before.json` / `source-span-after.json` | `a1fb6cf02a0d4599cb2418d02b58c5dbf8cbf009138faecdcaf0663621aaa040` |
| Generated `Sources/NativeElyxModeRoot/RootFixture.swift` | `96511ca13ae79fab5c5161e94206472966d4b207960c301a108872b7d21b01b2` |
| Generated `Sources/ExteralessCore/ExteraConfigCommands.swift` | `61f581dc057967ce856b6b9f1f44a4ace932c87a79e247afc60b498b5bb69957` |

JUnit projects actual XCTest console events and retains the original console-log hash and cohort SHA. Its four test identities, results and counts agree with the sealed Swift source, supplied driver receipt and completed native suite summary. Generated source/test files and full input manifests are retained alongside the logs.

## Execution boundaries and caller custody

The fixture executes **real filesystem preference persistence, native provider queues, exact Root methods/initializers, Host activation, permissions and descriptor registry behavior**. Owned read-only file descriptors exercise capability retirement. UI/context/transport and Python execution are **labeled recorders**. This establishes the Mode ABA fixture's native behavior, not Apple/UIKit app integration or a linked CPython execution result. Test filesystem writes are confined to owned temporary fixtures; no account, listener, plugin HTTP request or external plugin execution is involved.

Only the four Mode cases are selected. The earlier 53-case Host, 50-case Python, 47-case FD/Host and seven-case ingress gates are not rerun or included in these counts.

The snapshot/publication worker reads caller inputs through a hash-checked `FilePins` allowlist, uses a unique temporary `GIT_INDEX_FILE` with `read-tree` on the authorized parent, validates `hash-object --path` canonical bytes and indexed postimages, and creates the branch atomically through `commit-tree`/`update-ref`. All captured bytes matched their seal before and after indexing. Caller HEAD/index observations before capture, after indexing, at publication and after completion all recorded main `6de4ac36fefb54890a3dd043044e5a021a3d0e76` and index SHA-256 `dec54bf89631091bf4472e1056606e20431f873c3d3beb5bb8bff20f978d83c8`; these are observations, never restore targets.

Only this receipt is authored in the caller worktree. Workflow, observer, private index, frozen inputs, sanitized publication/watch logs and downloaded evidence reside on the temporary CI branch or under:

`C:\Users\sasha\AppData\Local\Temp\opencode\elyx-mode-aba-20261116-0b0bd7c67b`

No main commit/push was performed. The single bounded watcher queried only this unique branch/run. Local checks passed Python syntax, generated source/span/copy identity, exact private-tree path scope, `git diff --check`, actionlint 1.7.12 and downloaded native evidence identity/checksums.
