# Elyx bounded Linux/POSIX CI receipt

**2026-11-16: Python POSIX PASS (42 passed, 0 skipped); overall two-job gate FAILURE because Swift compilation failed. No Host test pass is claimed.**

## Immutable execution identity

- Branch: `ci/elyx-posix-20261116-61d829ab`.
- Commit: `ff9134924cdc1c41aeecb2af1f4cf194a1963550`.
- Parent / caller `main` HEAD: `4bcf80a0d7160264accbb6b415facde82cf87928`.
- Tree: `4bcccca3c12efb166d2079aa1793acc66919bb97`.
- [Manual workflow run 43768124344](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43768124344), actual conclusion `failure`.
- Dispatch UTC: `2026-11-15T22:13:53Z`; both jobs completed by `2026-11-15T22:15:03Z`.
- Frozen capture UTC: `2026-11-15T22:12:03.631929+00:00`.
- Exact dispatch: `gh workflow run compat-tests.yml --ref ci/elyx-posix-20261116-61d829ab --repo SanekYo-tech/exteraless-ios`.

The existing workflow path `.github/workflows/compat-tests.yml` was replaced **only on the verification branch** with a `workflow_dispatch`-only, two-job workflow. Its SHA-256 is `3c5c3dfaf4ec66ec92c0acf0f8151b7d67fb090f0f8af77fae7e385415700add`. No PR or automatic push job was created.

## Actual results

| Executed cohort | Passed | Failed / errors | Skipped | Evidence |
|---|---:|---:|---:|---|
| `test_ios_elyx_archives.py` | 13 | 0 | 0 | Linux JUnit |
| `test_ios_elyx_p1.py` | 9 | 0 | 0 | Linux JUnit |
| `test_ios_elyx_source_authority.py` | 7 | 0 | 0 | Linux JUnit |
| `test_ios_runtime.py` | 13 | 0 | 0 | Linux JUnit |
| **Python total** | **42** | **0** | **0** | **20.270 seconds** |

- Python: Ubuntu 24.04 x86_64, CPython **3.12.16**, pytest **8.3.5**; job `132977719177` succeeded in 36 seconds.
- Fresh C extension: `setup.py build_ext --inplace --force` succeeded with GCC, using the frozen `_exteraless_bridge.c`. Binary SHA-256: `d4c3ddfa5d1b9db4162de5a002ce31a3d539cdf4dfa9f9e9d30b9f99034880f9`.
- Pure dependency bundle was produced by the committed BASE `tools/runtime/vendor_dependencies.py`, with BASE lock SHA-256 `222da84eea828044f5af0e8d034945662fd74aae6414bc91f67d6311f14ef924`. Bundle SHA-256: `d7fe1f9be22ef7bf3bff75b5d462ebe756039c86226c56948007bed06aef8990`. The fixture parent found the pinned **PyYAML 6.0.3 pure-Python** implementation through `python/vendor`.
- **All 17 formerly Windows-skipped cases executed successfully:** ten archive cases (`literal_lifecycle`, `yaml_lifecycle`, `source_signature`, `reload_wheels`, `providers`, `ids`, `owner_cleanup`, `symlink_cache`, `failure_cleanup`, `bytecode_owner`), five P1 cases (`fd_extract_swap`, `fd_cleanup_swap`, `fd_replacements`, `raw_os_paths`, `two_owners`), and two source-authority cases (`namespace_replace`, `verified_sdk`). The tests exercised real Linux directory descriptors, rename/symlink replacement and extraction/cleanup operations.
- Swift: Ubuntu 24.04 x86_64, **Swift 6.4.2**, target `x86_64-unknown-linux-gnu`; existing toolchain cache restored. Job `132977718952` failed during compilation, after seven seconds of its compile step. **0 Swift tests executed; 53 were intended by the filter.** The test step was skipped after compilation failed; there is no Swift JUnit and no test-level skip count. The always-run count recorder correctly reported missing JUnit.

### Coordinator blocker: observed Swift compiler error

`swift/PluginHost/Sources/PluginHost/PluginCallbackDispatcher.swift:80:77`:

```text
error: failed to produce diagnostic for expression; please submit a bug report
```

The frozen expression is inside `permissionPredicate(...) -> @Sendable () -> Bool`:

```swift
host?.permissions.futurePredicate(pluginId, requiring: permissions) ?? { false }
```

The compiler invocation contains all 43 ready Host Swift source files, including `PluginModel.swift` with `futurePredicate` at line 425, the ready Request/Transaction/Candidate definitions, permission storage and archive storage. This is an observed compilation blocker in the supplied source/toolchain combination. No production source fix, provider stub, alternate compile mode or repeat run was applied.

## Bounds and coverage boundary

- Python job: 10 minutes; pytest outer hard limit 120 seconds; existing isolated `-I -S -B` children 20 seconds each (the two-owner peer also has its existing 10-second bound). `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1` and UTF-8 were enabled. Only the four named owned modules ran.
- Swift job: 25 minutes; `swift build --build-tests --jobs 2` hard limit 180 seconds; intended `swift test --skip-build --jobs 2 --filter '(PluginArchive|PluginTrust|PluginSettingsPage|PluginResourcePath|PluginSendHook|PluginElyxDeveloper)' --xunit-output ...` hard limit 30 seconds. The test command was not reached.
- The Python SDK and archive implementation executed real owned inputs. Native-service fixtures remain explicit strict doubles. Source-authority tests use a real FD-backed **contract recorder**, not the production native authorization registry. The fresh C gate was **compiled**, not linked to or exercised through that production registry by these four unit modules.
- Native `PluginElyxDeveloperFiles`, `PluginElyxDeveloperDescriptor`/Registry and their unfinished provider tests were excluded. The ready Host Request/Transaction interfaces and public native Elyx/coordinator hooks were included, but Swift compilation prevented their execution in this run.
- **Production native FD-provider/registry acceptance, linked native CPython capability authorization, Apple/UIKit and full-app behavior are not covered.** No corpus clone/import, downloaded foreign plugin execution, Apple SDK build or release artifact was part of this gate. The unrelated full-app UI run was not queried or cancelled.
- Committed BASE SDK tree `6928955ed0162a63489b132467c7f9fac8af23f7` and Core712 tree `637a8dde7485c78ef5cfdaa2559651c216d8d09e` were inherited unchanged. `PluginHost/Package.swift` is standalone; Core tests were not executed here.

## Frozen-byte custody and artifacts

122 existing working-tree files were frozen. A separate temporary `GIT_INDEX_FILE` was populated from BASE, canonical blobs were written with `git hash-object --path`, and `write-tree` / `commit-tree -p BASE` / a new-branch `update-ref` created the verification commit without checkout or staging in the caller index. Hashes were checked before copying, after copying, after private indexing and against the resulting tree. **Raw and Git-canonical SHA-256 values are identical for all 122 copied files.** Both Linux jobs independently verified all **166** source pins, including inherited SDK/build inputs and the owned workflow.

- [Complete immutable source-pin JSON, including Git blob IDs and byte sizes](https://github.com/SanekYo-tech/exteraless-ios/blob/ff9134924cdc1c41aeecb2af1f4cf194a1963550/docs/wave-2/elyx-posix-source-pins.json).
- Source-pin JSON SHA-256: `e906b30c7f56528ba4ac034284bbf927e54824dc07d49096b61bafe59fc00ff3`.
- Input handoff `docs/wave-2/elyx-archive-p1-inputs.json` SHA-256: `7c9474064d6afede795502b022f8a4e20ecde27fe44d92cd27d88b299fd927d5`.
- Artifacts: `elyx-posix-python-43768124344` and `elyx-posix-swift-43768124344`, retention 14 days; both uploaded and downloaded successfully. Both downloaded pin receipts and cohort SHA files were checked against the immutable commit.
- Local frozen sources, sanitized push/watch logs, actual conclusion, failed-job logs and downloaded artifacts: `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-posix-ci-20261116-61d829ab`.
- Main HEAD and main index remained at their initial values through completion; index SHA-256 `c70fe55b5430333ef3b2ee4e1247dd82e83a9a0a26aaa062faf4d94700096d4f`. Selected working-source hashes still matched the frozen bytes at receipt preparation. The only authored caller-worktree file is this new receipt.
- Local checks: dispatch-only/two-job workflow passed actionlint 1.7.12; all six embedded Python programs parsed; 36 frozen Python modules parsed; commit diff passed `git diff --check`.

| Downloaded evidence | SHA-256 |
|---|---|
| Python `archive.xml` | `3cca73f59a6d0db4c0ac3da2e3f102e8b7806a57291cf5da4000d74628e36a86` |
| Python `pytest.log` | `f0936edcbabffecdf478ecace56194516c97d867bb1f42d1e1051e82131e0a1a` |
| Python `c-build.log` | `b17fef5bc3a2c71f59a512c1c34064ca4d616952f937f4ebdad01bfa6dd9e05c` |
| Python `counts.json` | `e63e6d4c81bb10936273c7276981133d8643363e90b4be225afd68e82d655a72` |
| Swift `swift-build.log` | `fbf795c1aad4e224447c8c58fad7e823eeabd51cc41cb6db1cf5aef2baf8032e` |
| Swift `counts.json` (missing-JUnit error) | `e4a666034172532a2a8128774c64014eca0262d68714d9c9a87da86fe0016ece` |

## Exact copied source hashes

These SHA-256 values identify the tested frozen bytes for a later cohort join. BASE-inherited source pins and the verification workflow pin are additionally recorded in the immutable JSON above.

<details>
<summary>122 copied files; raw SHA-256 equals canonical CI SHA-256</summary>

| Path | SHA-256 |
|---|---|
|python/bridge/_exteraless_bridge.c|2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2|
|python/exteraless_runtime/__init__.py|dc63398bc3a00ded23c94dbde615aa6cb45c528094b5c54b8b95670f299fe87a|
|python/exteraless_runtime/_archives.py|04a0403b7df7977b22714156394430a7760559252745a16d7d7bbcc3e5c9f824|
|python/exteraless_runtime/_audit_paths.py|3e0d7444eb0dd7a035f55e92d438e1dcf54c62f79b7a83b1a68f4ccf87921e03|
|python/exteraless_runtime/_callbacks.py|70497a280c5ebc081e662fc72c656bb907df721981c19e2929f7c815e638c481|
|python/exteraless_runtime/_codec.py|a9c6b19357d0a637dd6f6c641198cd37552f317ac1202722291fde3a313fe6fb|
|python/exteraless_runtime/_config.py|e842c58b0e28355e01c69cb3c744978170331bffeef90251c5874b15a9159799|
|python/exteraless_runtime/_config_manifest.py|3e0b56a5a75a634b383b04c579c08ac982dee9012e24daa11d0320c0144b699c|
|python/exteraless_runtime/_controllers.py|f43b87693bc51f87b2cf824ea3dc535d9346d45558a8b501f705b33f8a5881a3|
|python/exteraless_runtime/_dependencies.py|30669ce63a2d5707a0ef34b89a0b93a7e96517f103cb40a31a6d1f5acfa61a16|
|python/exteraless_runtime/_developer.py|22611badcf6c3be224e68c3f9acdefeae7edff937e1aa5a278b68b0eed27ff2d|
|python/exteraless_runtime/_elyx_developer.py|a2b999fb1113249c557a5c9fb90e57476b06bac05b597b9bbebb3e688e926690|
|python/exteraless_runtime/_elyx_helpers.py|f9a9cd73cbaf0d7ab987a1158e090935ec4fdd936f837e1801b04a2d4f0abaee|
|python/exteraless_runtime/_facades.py|c9a5b7c0861d07441746d3967e119fb0fe6efe38d4b560714970b6fa4d3f12bf|
|python/exteraless_runtime/_hook_registrations.py|888affeff0b233b41fda8f12f91c828fd206e61ea93146a95db7e2e981ee654f|
|python/exteraless_runtime/_java_types.py|30a1ed6fd51fef50587029ca692c1005067cad7ceba54a212163f50b4c314f56|
|python/exteraless_runtime/_logging.py|8eca0d23f56a85ea87da14a22b0b8cdfb641adfc56fb5cb241e22a91ea1719cd|
|python/exteraless_runtime/_notifications.py|50157ca3fa158c99b1687b35e97bc4ae13614dc897526c0061f096b1225f1ca7|
|python/exteraless_runtime/_pill_types.py|25a73a00c6841d0d0e28027951c20d069f46782dc2bf8120b51b95623e3ee190|
|python/exteraless_runtime/_pills.py|fc2ac5e18723de8f3779624ddac3a7523aee4047b843c2364cf64b10b9bdb999|
|python/exteraless_runtime/_platform.py|2b6050b372f8923bb7efb965bb0b79af73e29dad551e0ff85270359ad4d16932|
|python/exteraless_runtime/_reflection.py|8f5a3e9cdd064f2d593852005b36dfff387ac6915848e430554357c7aac7ed6f|
|python/exteraless_runtime/_registrations.py|e15f5fa6d292f383031139aa1b03f1d095d29aa557233f697897ba99c7ac122c|
|python/exteraless_runtime/_scheduling.py|53428ff5b9a207405377d86939e582748d45e4e3a016d75f0d34552bcd92a293|
|python/exteraless_runtime/_settings.py|9421584fbc940ffb54f191d6b9726de36b53d6c037b6a71278ea49bfa20077a2|
|python/exteraless_runtime/_tl.py|00b016b315a43fcd7015ee4d37debf69fcc1c347b6e380ade92d06775eb03d9f|
|python/exteraless_runtime/_ui.py|301b669e23eeb7388810d699a27f91f16189f6d181070c7851480a417f1f4398|
|python/virtualjava/__init__.py|918fbafd5a7338ef16f63d930aa87ec51d8cf78da8269220bb6fd6ddd185e221|
|python/virtualjava/arrays.py|09088cce9b5d587eaecd57bdc9ddbed082ada60fa23308244577740510ab0c11|
|python/virtualjava/backend.py|765bfe3f9c8bb5f2031d28d5b3cb47d69ef46b7d6fbbaf59c4d255c09e8fb71d|
|python/virtualjava/finder.py|d1bc47eecc730b6b6ac9e724c3f957ffd9cb6b72a481c5f0cb0410704bb98e71|
|python/virtualjava/proxy.py|025acce2920244788ec5f69874228b5db459fc3a3c5b5555edeb85f10d32de92|
|python/virtualjava/registry.py|7ad5d5125e4dd231b07fe3145402e1113aab639fa57af2e22d10e5aa033e69b8|
|swift/PluginHost/Package.swift|fbc50ee84590add303641563b765c189fd1de71d47d8d4939bba42146734766c|
|swift/PluginHost/Sources/CPluginHostShims/include/ph_atomic.h|7423467c23cd56374aef83f704b93d0396d2ff5e7d30e07cadbada6049485bd8|
|swift/PluginHost/Sources/CPluginHostShims/ph_atomic.c|4bfed21b108e9a6443befa41f3211247dbea767e2562e30b88ecb4d06073234d|
|swift/PluginHost/Sources/PluginHost/BridgeServices.swift|2b9d428135e67213a47e64f780d595f3ca92ebdbb300e6c042e915d581d0957e|
|swift/PluginHost/Sources/PluginHost/CPythonXCFrameworkEngine.swift|b6d6f6a295340292f6f6598beecbc5c892623472aae2f93f28a8856a3627f30d|
|swift/PluginHost/Sources/PluginHost/ExtensionPoints.swift|a7f5ce2b5fd5495a505a548504a40c9cf8f83fbbfcbd95d22d727da5360dec5b|
|swift/PluginHost/Sources/PluginHost/NativeBridgeBinding.swift|27f65038bf5c316494bcdbecbf4f1c0f83a567d01e3d471120c1a6d3b00d7246|
|swift/PluginHost/Sources/PluginHost/NativeServiceCallback.swift|dbe387306469785d9ed62e37dff967cd9e6fc99cab8c32a3b2253c83b2b4cd69|
|swift/PluginHost/Sources/PluginHost/NativeServiceCleanup.swift|1b820dc298fe2442a456d6d6b483510dfe51ad6a27649b9d1a234952b0d10f39|
|swift/PluginHost/Sources/PluginHost/NativeServiceEventDelivery.swift|bdc197482f170d09687f78545d8aa6b35e1ff05ee9d3f358cd979f9cc5e502a7|
|swift/PluginHost/Sources/PluginHost/NativeServiceInterceptionModels.swift|05ed1af2ac1d6418b4f80f3b9efc8054f07c3687daa2f101f30413a1d09d81fb|
|swift/PluginHost/Sources/PluginHost/NativeServiceLogEvent.swift|83049e070f36d267d0c9f724681d419b5c443f8971aa197e5fdcd5fd37b17b40|
|swift/PluginHost/Sources/PluginHost/NativeServiceOpenBarrier.swift|f97529c4feb219f34a9167eb8f867bd040b5f96479bbce42ad623ef82e9e54e9|
|swift/PluginHost/Sources/PluginHost/NativeServiceOperations.swift|689d7b7c0eb58eac53ed98fcca8dada2baf1060b217354765a2d98213d028169|
|swift/PluginHost/Sources/PluginHost/NativeServicePlayback.swift|e710f7979e1d5606168ea5f5f9815f1c6876a51fd32646b5f9f152191f1c465b|
|swift/PluginHost/Sources/PluginHost/NativeServiceReleaseQueue.swift|91b6e32299632e4960c581ddab40f02d15b13c4ac42e7fb26d899af43253f525|
|swift/PluginHost/Sources/PluginHost/NativeServiceScheduler.swift|c64fda685439f416513b94c23b05bf64883cc986ba99d1dceddaa02e016ee83f|
|swift/PluginHost/Sources/PluginHost/NativeServiceSnapshots.swift|4dd80e363c8dd5579a35620d354e65578c9273cedccc262b26b1ec49c06012f5|
|swift/PluginHost/Sources/PluginHost/NativeServiceWire.swift|e465bb340c8ac3c936677833881bba21011183c05530677e6807ce914d676a26|
|swift/PluginHost/Sources/PluginHost/PluginArchiveStorage.swift|ecde8c195dfd7fbc5ec6aaa66705b4be4e74324e9d8de3306bae6b046d7625dc|
|swift/PluginHost/Sources/PluginHost/PluginBridgeExtension.swift|09c7f5dd4234e96c4f8aeaad07de316743d2ff1672a74a53961bd514539cf47f|
|swift/PluginHost/Sources/PluginHost/PluginCallbackDispatcher.swift|907f1c8f5efe3b167040c73d10c619b8bbe48cd7dd8fc5477b2cc1b4f441f76a|
|swift/PluginHost/Sources/PluginHost/PluginElyxArchiveCandidate.swift|adebf1552551bbc7faa826821596dfec50fbcded9ed59cc369da6613e8029e21|
|swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperRequest.swift|82f9655ccd392d4b76cd6df46e547d8d9e1b494a03e5256994f05be7b5e85eca|
|swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperTransaction.swift|ed22be0fe9deb8abb60d5614dc29ad96c1a40f4f4b59425654a6fd5d26b650d4|
|swift/PluginHost/Sources/PluginHost/PluginEventExecution.swift|882de607740cfd3eca62cd11d564519c987498bcd8fd862194dc21f1b6e73707|
|swift/PluginHost/Sources/PluginHost/PluginEventQueue.swift|dc797e3ae31aab59e86e2d31ea2aa0afa44e78643c1fe4587abe6e2bde678f34|
|swift/PluginHost/Sources/PluginHost/PluginHost.swift|5c256b20fc4ecce58c6e460aa1989836450abf499d9f3c7deb135fd5c2421de6|
|swift/PluginHost/Sources/PluginHost/PluginHostLifecycle.swift|dfa7484596853add073a7d6e66ef4c38d6cf3cd680f7a44865281cd6cd4872da|
|swift/PluginHost/Sources/PluginHost/PluginModel.swift|10a00a89ddd35dc08eeb21014aab74f77284d6064ff90e297d9eba56985383e0|
|swift/PluginHost/Sources/PluginHost/PluginNativeEffectBudget.swift|6dc6a7014d64cf28d33066d5dab475158210aa6bc094d656a61af38c860c97d5|
|swift/PluginHost/Sources/PluginHost/PluginPermissionStorage.swift|0748986b22f43478cd5547a193f67af7f366d4f65aa49395af2e3408bb2701de|
|swift/PluginHost/Sources/PluginHost/PluginResourcePath.swift|fd68d73978d46702f7a1a9e3e08f65e2d20189c0280c6a12b32b92436a6b0e45|
|swift/PluginHost/Sources/PluginHost/PluginRuntimeProtocol.swift|1926e6aad7bd145cb0438ea56080e812e3e0fb962c963f1c7640a13b632f8c8e|
|swift/PluginHost/Sources/PluginHost/PluginRuntimeStartupContinuation.swift|0e70f0c9d728eedff50d4e0d0553672842f0a7cc57699bd287aaa4f444a35c60|
|swift/PluginHost/Sources/PluginHost/PluginServiceModels.swift|d5cf1997b54359323a38db2dbe39002a59a59642514b8fc27db66dc7184c3815|
|swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift|827ce0d50604b56694fbfa83fa7112b7943cf9c33b102de20c57ac9e4ea603d2|
|swift/PluginHost/Sources/PluginHost/PluginSettingsPageLease.swift|d607bf036b27d3af74de54a0fce1f1614f7bdd73ab940d443feb074df0d5e19c|
|swift/PluginHost/Sources/PluginHost/PluginTLHostPayload.swift|e3935c527f2ed969ebd1898bdf85b817454563b504532216e508953498b96d76|
|swift/PluginHost/Sources/PluginHost/PluginTLInvocationOrigin.swift|328d6f819ae6141529d334cb4ab9eb94536aad29617541ef2d9c92de18e12383|
|swift/PluginHost/Sources/PluginHost/PluginTrustLevel.swift|5880f3e6d9a3c00fb6793de3fa286b571350fbb81f4db7287ef8a6f498ea9ca8|
|swift/PluginHost/Sources/PluginHost/PluginTrustSelection.swift|17fad5a79bf6648481b29ee1cfdf85030e0e073f140f9b176c4424cb859335a4|
|swift/PluginHost/Sources/PluginHost/PluginWatchdog.swift|4efb7cda74992219acde62f3de5b5fb72d0ff5c8d602a6bf2904c10c0ff3850c|
|swift/PluginHost/Sources/PluginHost/PythonRuntime.swift|1e9235e65f1fb860da218317a033d12e2b37f545b2b2dbdad33de29fce6544f1|
|swift/PluginHost/Sources/PluginHost/SecurityGates.swift|2467c87171c86cb7e9f1960afbd57f087000b2fcf5e33e6a98854d60fd7a7bba|
|swift/PluginHost/Sources/PluginHost/SubinterpreterManager.swift|2f01f17fd5e12d1d561339097a25270f4277766cda58f38c36b0f0005dd43c60|
|swift/PluginHost/Tests/PluginHostTests/BridgeAccountArgumentTests.swift|0f5045cc63473beb72af308bf955861aa156c2f08591e95827587be4ae503f36|
|swift/PluginHost/Tests/PluginHostTests/BridgeServiceConformanceTests.swift|d9077faeb3ed8e1d03ce61d4ffefa7ce28e5b9ef1e5ed3baaf363ef98034b346|
|swift/PluginHost/Tests/PluginHostTests/HostLifecycleTestSupport.swift|04169c2cdd57e4c41ae4f30c400ac574242a44e0366121b300b3d6a564991cda|
|swift/PluginHost/Tests/PluginHostTests/NativeServiceCleanupTests.swift|354f95687ba25c7c7350f9c0e18ecfdc6958a178282a048584432ca23509856c|
|swift/PluginHost/Tests/PluginHostTests/NativeServiceDispatcherTests.swift|2d15f3c14f4cd0a6d659c923468ae55d6eace033734983863b32a23501df7c08|
|swift/PluginHost/Tests/PluginHostTests/NativeServicePhase2Tests.swift|25122c99d1f4d5490f0dd036df727c7ffdd441ec1c16e2fdac6a2ead85b5e919|
|swift/PluginHost/Tests/PluginHostTests/NativeServiceRemediationTests.swift|1401bc04c702f34f8f5eacc1b4f43304ef615127b1cc80e46d0bf250e1c63983|
|swift/PluginHost/Tests/PluginHostTests/NativeServiceTests.swift|ce8a562db625e7666bd704106229713e0dac0f2fbf5f4a92297d9f6557690a3e|
|swift/PluginHost/Tests/PluginHostTests/PluginArchiveDescriptorTests.swift|2925286baf7e3707f1e51b8c8f835a4450f5db7b5d623dd17e68576a0c5cf8fd|
|swift/PluginHost/Tests/PluginHostTests/PluginArchiveHostTests.swift|0a1a4d02683f4908b80b86b20761975cd96e82f827b394b74ff546f69835692d|
|swift/PluginHost/Tests/PluginHostTests/PluginBatchOwnershipTests.swift|cecba474eb8e0bde1c7a173c8bab96c47288686e8c978366099acde315ef5b62|
|swift/PluginHost/Tests/PluginHostTests/PluginBoundedStopTests.swift|5d654183b3f14c08efccd4ae31169fe93b927c68d07990f5a073c38e449c940d|
|swift/PluginHost/Tests/PluginHostTests/PluginBridgeExtensionTests.swift|fb73d17ecc3e3c48fa8242d9a1b06137a713f2ab250b9a4e2e76a58c050a7d1d|
|swift/PluginHost/Tests/PluginHostTests/PluginCallbackGateTests.swift|2fc1750de803d4bf9087ef8a853c2be946e038cf78904f4c33c0bed5caf84b64|
|swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperTests.swift|3de3e85b1d06b6edb22c817b5f84e4545ae02a4396ab259288dd131201526c7a|
|swift/PluginHost/Tests/PluginHostTests/PluginEventIngressTests.swift|3c0657693271fcf779ecdd3f5d932f0f74798e0d74729e970f5932675482b215|
|swift/PluginHost/Tests/PluginHostTests/PluginHostMaintenanceTests.swift|58d371bbd5cdabe621b62b58ddca6accec2d424dfe4c459f7bacd3781117229b|
|swift/PluginHost/Tests/PluginHostTests/PluginHostOwnershipTests.swift|2b7d8ab6b834b314d2d263a43b1e9b9f7bffd16b8af4756e529a693597b4916c|
|swift/PluginHost/Tests/PluginHostTests/PluginHostTests.swift|d4af3169ed7a96710f891e001c10062b1426df40c453649708a99bf184e79ad7|
|swift/PluginHost/Tests/PluginHostTests/PluginNativeEffectTests.swift|cb3da62bd502896f0ada3657034ec119914c49d2fb880d4b698801254056d5d4|
|swift/PluginHost/Tests/PluginHostTests/PluginResourcePathTests.swift|9762c3cff2bb68ff37daa6c629402db42337dd4afe05e1a3da6eeb24535df4ee|
|swift/PluginHost/Tests/PluginHostTests/PluginRuntimeProtocolTests.swift|8489915df42e6d64438eb2fadb4b20ef1d48eef85e7f7957088654e0ddb2244b|
|swift/PluginHost/Tests/PluginHostTests/PluginRuntimeStartupContinuationTests.swift|1709bcc71e7bfef8f485c39692784e7dc664742a87d34c435ecc9cefc5471cbd|
|swift/PluginHost/Tests/PluginHostTests/PluginSendHookPriorityTests.swift|e2ade96c9387c42cf26213caead612271615f8a5a1688a88ca02f0275bf0cced|
|swift/PluginHost/Tests/PluginHostTests/PluginServiceStorageTests.swift|4eb5a5041478fb45a12ca641dba05d63dca6684fa007b2b6cb1b1682cef16512|
|swift/PluginHost/Tests/PluginHostTests/PluginSettingsExecutionTests.swift|e4953865d1193d80a86eee650adbd779d6ce8350196b9b9a7ee8aa1c53c1850a|
|swift/PluginHost/Tests/PluginHostTests/PluginSettingsPageLeaseTests.swift|083f795b3e8f246b7d517ef82e57eb09a8cce8f409c0ba0e133b11ac1b853269|
|swift/PluginHost/Tests/PluginHostTests/PluginSettingsReadExecutionTests.swift|23cf8c1edb34f31bb577cd6d318da088bec29499c79f06b43eadf76a345bb101|
|swift/PluginHost/Tests/PluginHostTests/PluginTLHostTests.swift|13196a69dfe76a04fa22e61c8cb544e26528805c119834987facc6442e43a945|
|swift/PluginHost/Tests/PluginHostTests/PluginTextOriginTests.swift|7ada43a02bb0075e9fd87be5a1a5c1d7aa6d384f9dcc2865350b76814b12b281|
|swift/PluginHost/Tests/PluginHostTests/PluginTrustHostTests.swift|8fe3e3765cadad192238eaff09936f3872686c835f554c97febd20f90d70d04d|
|swift/PluginHost/Tests/PluginHostTests/PluginTrustLevelTests.swift|b33ef9ac1416ed54137e1a5093885e5fc1889057ba8c9797fb9ca11734d69e1c|
|swift/PluginHost/Tests/PluginHostTests/PluginWatchdogMarkerTests.swift|3e9ba8cf624b7c47c0d9601a5db22460f53c4f46e433d6ea54d75ae43e3a9dfb|
|swift/PluginHost/Tests/PluginHostTests/PythonRuntimeConfigurationTests.swift|1f92e3acd306de81942532b8f0a8636ded4d2daa5650cd18bd7cfb06ad03020d|
|swift/PluginHost/Tests/PluginHostTests/SubinterpreterLifecycleTests.swift|9f9f5626c332bb37c4fa504bc90e5a1209ac0ba5c6d993bac616ab8b77d63b0d|
|tools/compat/tests/fixtures/ios_runtime/audit_import.plugin|066f8ed3f4a2d1809c948d75a0a862b874eaf9bd2cab164f07637849c4f3ac81|
|tools/compat/tests/fixtures/ios_runtime/failure.plugin|cf55e5abf0036495a15b2b4dd0f76af686156351f6245daeca08c303463db068|
|tools/compat/tests/fixtures/ios_runtime/lifecycle.plugin|eb17871f2790cb387bb381917f6999014f4299ac744e61675c4d0cc7ee5820b8|
|tools/compat/tests/fixtures/ios_runtime/metadata.plugin|a455c8ec49e4b290093a9ed50f75b8d4e9713c888163f91296665a77dddf3920|
|tools/compat/tests/test_ios_elyx_archives.py|a235d6a114fef36ae3ed08cb0adac3a967d99d6d4f7301ed5f96308843d1a29e|
|tools/compat/tests/test_ios_elyx_p1.py|46ff2ceccd6483fb2c3e7983e40db4ea05f8a578bcead8de0122d2abb535a295|
|tools/compat/tests/test_ios_elyx_source_authority.py|cd6d8ad16cb9504b58bff7bc46be3fac8b71893c863135c58714eeb8bb20b6e9|
|tools/compat/tests/test_ios_runtime.py|1936648c55f336a4bac0c9abcedfbb804c424a17dc81eb38eb7a0c95ee1a32c2|

</details>
