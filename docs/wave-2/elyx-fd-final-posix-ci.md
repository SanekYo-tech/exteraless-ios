# Sealed Elyx FD startup and ingress — bounded POSIX CI

**2026-11-16: actual CI FAILURE at native Host compilation.** The sealed snapshot passed all 184 source-pin checks, then Swift 6.4.2 reported an ambiguous `S_IFREG` in `PluginElyxDeveloperDescriptor.swift:522:65`. **Host tests executed: 0/47 intended; ingress tests executed: 0/7 intended.** No new native runtime acceptance is claimed.

## Immutable run identity

- Branch: `ci/elyx-fd-final-posix-20261116-86dc4a19`.
- Commit: `ecaa9d851174dcb02862bc347a4dbc85e474897e`.
- Direct parent: `0ad00c3ef8e856d3a95cd33d43a059c4bc0c648f`.
- Tree: `0bbc64565150141a99a49b26f5655494f67575ed`.
- [Manual run 43779077310](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43779077310), event `workflow_dispatch`, actual conclusion **`failure`**.
- Single job: [133011942581](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43779077310/job/133011942581), `Sealed Elyx Host 47 + Foundation ingress 7 (POSIX)`.
- Run created `2026-11-16T00:13:23Z`, completed `2026-11-16T00:14:13Z`; job elapsed 47 seconds.
- Owner seal: `docs/wave-2/native-elyx-developer-final-inputs.json`, SHA-256 `15082e16ba5fd4d4edcd285ff685d3b7a1b9910a4b71405f47d91e8ae4b290a2`.
- [Complete verification pin manifest](https://github.com/SanekYo-tech/exteraless-ios/blob/ecaa9d851174dcb02862bc347a4dbc85e474897e/docs/wave-2/elyx-posix-source-pins.json), SHA-256 `c60fff83a6882348fe052ae1950f29934f16ced9d5e80a002ff8f645c136ed25`.
- Branch-only workflow SHA-256: `3f4493a07795fb64c8c8b081994aa5ec51a62726e164eda311f8f06d5da86a17`.

## Observed compiler blocker

`swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperDescriptor.swift:522:65`:

```text
error: ambiguous use of 'S_IFREG'
CoreFoundation.S_IFREG: public var S_IFREG: Int32 { get }
Glibc.S_IFREG:          public var S_IFREG: mode_t { get }
```

The exact frozen guard excerpt is:

```swift
              fstat(entry.backing.descriptor, &original) == 0, copied.st_dev == original.st_dev, copied.st_ino == original.st_ino,
              copied.st_size == original.st_size, copied.st_size == claims.byteCount,
              UInt32(copied.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { throw PluginElyxDeveloperError.stale("native read fd custody changed") }
```

The diagnostic explicitly names both imported candidates, CoreFoundation and Glibc. It is a source/compiler ambiguity in the sealed descriptor file, not a missing external dependency or a test assertion. The compiler log retains the full frontend invocation and diagnostic candidates. No production source, test expectation or compiler mode was changed to bypass it.

## Actual execution and bounds

| Phase | Intended scope | Actual outcome |
|---|---|---|
| Source verification | All 184 pinned inputs | **184/184 OK** |
| Toolchain identity | Cached Swift 6.4.2, Linux x86_64 | **Verified**, same frontend hash as prior gate |
| Host compile | Full Host source/test target, 180-second bound | **Failed after 7 seconds** (`00:14:03Z`–`00:14:10Z`) |
| Host XCTest | Files 29 + Activation 6 + Transaction/Host 12, 30-second bound | **Not executed** after compile failure |
| Foundation ingress | Supplied Linux driver, compile 120 seconds / execution 30 seconds | **Not executed** because its shared Host dependency failed compilation |
| Evidence collection | Logs, JSON, pins and checksums, always-run | **Uploaded/downloaded successfully** |

The job's outer bound was 25 minutes. It used `swift build --build-tests --jobs 2`, followed by the intended filter `PluginElyxDeveloper(ActivationTests|FilesTests|Tests)`. The sealed definition inventory is exactly 47 Host cases; the old 21-case inventory was not used. No filters were lowered and no skip was added. There are no XCTest-level pass/failure/skip counts or JUnit results because neither test process started; skipped workflow steps are not test skips.

Swift version: **6.4.2**, target **`x86_64-unknown-linux-gnu`**. The workflow actively verified frontend SHA-256 `76db9f3dd8487a14ae39374509620e33af02f10da5dc42247406657832e4e9da` before compilation.

### Ingress capability and exact dependencies

The supplied `tools/compat/tests/test_native_elyx_ingress.py` explicitly admits Darwin and Linux. Its copied production sources import Foundation/CoreFoundation and PluginHost, with no UIKit, account or listener startup dependency. Its `run_bounded` helper is imported from the sealed `test_sdk_developer_native.py`; only that portable subprocess helper is called, not the helper module's Darwin-only listener test.

Two explicit driver dependencies absent from the owner's seal were inherited from committed parent `0ad00c3e` and independently pinned:

| Read-only parent helper | SHA-256 |
|---|---|
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIModel.swift` | `934e219922091da4b78aba3cc5a13f0e6ee09a9fdea60afa845baf9b4e357606` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIStyleModel.swift` | `7c0d4e24b3230943b193d56bab5dd844a89ae706f47fb82a01c84009962a336e` |

The current-main `PluginUIModel.swift` had an unrelated, unsealed settings-target/snapshot delta; that delta was not captured. The source dependencies named by the ingress driver were inspected explicitly. Ingress remains **Linux-capable but blocked by the shared Host compile error**, not classified as an Apple-only or successfully executed probe.

The workflow's ingress logging hook observes the supplied helper's actual return values and process metadata, preserving its commands and 120/30-second process-group bounds. It would retain compiler/test logs, input-copy hashes and the generated package. It was not entered in this failed run.

## Frozen-byte custody

33 exact paths were selected from the seal's Host changes, required read-only inputs, readiness Python files and ingress dependencies. Every selected current-worktree hash matched the seal before copying and again after private indexing. Raw and Git-canonical SHA-256 are identical for all 33. The seal itself was copied for provenance, and the two parent-only model helpers were pinned separately; the complete verification inventory contains 184 files.

The resulting commit has 25 changed paths relative to `0ad00c3e`, all inside the explicit selection plus the owned workflow/pin manifests. SDK, C bridge, Core, the first dispatcher compiler fix, Host package configuration and the two fifth-child tooling files remain inherited from the parent. `python/bridge/_exteraless_bridge.c` retains SHA-256 `2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2`; `_archives.py` uses the sealed NFD-02 `72380885…` input. No current-main fifth-child tooling postimages or other unsealed app/Root changes were refreshed.

<details>
<summary>33 selected sealed input SHA-256 values (raw = canonical)</summary>

| Path | SHA-256 |
|---|---|
|docs/wave-2/elyx-nfd02-inputs.json|3d81fa189e30fa98d90c7abc9551b2709e2af8d6a5da8bf2c20b9cea47d342fe|
|docs/wave-2/elyx-source-descriptor-v1.json|7c1d62d040f75b900bdd0ece50335797fd0596fde5ddb38f8e77b449c3e3c83c|
|python/bridge/_exteraless_bridge.c|2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2|
|python/exteraless_runtime/__init__.py|dc63398bc3a00ded23c94dbde615aa6cb45c528094b5c54b8b95670f299fe87a|
|python/exteraless_runtime/_archives.py|7238088539f31c414307e1f9e8b986940a87d4525ce6b31e5020b09871b555da|
|python/exteraless_runtime/_audit_paths.py|da7fcc6c4c5ea4cef9fbb7576f26f858eb63276961569a7fe1d8f6aef0b8b40e|
|python/exteraless_runtime/_developer.py|22611badcf6c3be224e68c3f9acdefeae7edff937e1aa5a278b68b0eed27ff2d|
|python/exteraless_runtime/_elyx_developer.py|a2b999fb1113249c557a5c9fb90e57476b06bac05b597b9bbebb3e688e926690|
|python/exteraless_runtime/_elyx_helpers.py|f9a9cd73cbaf0d7ab987a1158e090935ec4fdd936f837e1801b04a2d4f0abaee|
|python/exteraless_runtime/_elyx_readiness.py|0e13c61acd071e765eb267d0feaea1bf397314d31d7b37ca5f0b114400ac6d20|
|python/exteraless_runtime/_platform.py|2b6050b372f8923bb7efb965bb0b79af73e29dad551e0ff85270359ad4d16932|
|python/runtime/include/EXLPythonBridge.h|6ecab9d92438e62bd3f0d7218f9646b78f9e3f764cc5d4e9f9e5a78b85b6166d|
|python/virtualjava/proxy.py|025acce2920244788ec5f69874228b5db459fc3a3c5b5555edeb85f10d32de92|
|swift/PluginHost/Sources/PluginHost/BridgeServices.swift|73ba9424868df41d20a861fb57e5ffc0362dd7568ce7401d77b7d57a43414694|
|swift/PluginHost/Sources/PluginHost/PluginArchiveStorage.swift|ecde8c195dfd7fbc5ec6aaa66705b4be4e74324e9d8de3306bae6b046d7625dc|
|swift/PluginHost/Sources/PluginHost/PluginElyxArchiveCandidate.swift|adebf1552551bbc7faa826821596dfec50fbcded9ed59cc369da6613e8029e21|
|swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperDescriptor.swift|42c3dbadc270cb37347325aebcccfe4ef64cc54047ada1569106ca3c6d1f7bf4|
|swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperFiles.swift|56903232ceb9bd6c003fd4bb3b7328e5af363a4a095960969cbc697b56a6338f|
|swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperReadiness.swift|903c323a091c3596b9f3f9bce7a5914fecd2091eabecabb892e73f9a539267e1|
|swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperRequest.swift|50aeafa90bfabe8924156bb001623b82d9709addd9902abfa436c740e46ed150|
|swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperService.swift|10a6ee936bcb5d65fc9a046f6ec66865e9322346787069ff969d9320644cee26|
|swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperTransaction.swift|739eb78e179d5130e1f2698e7627ee403f6aae646700758cd224391f2791e652|
|swift/PluginHost/Sources/PluginHost/PluginHost.swift|6e3f9692792795761cb882ba040b7f065430a2918669ecdea56aed1d19758fc9|
|swift/PluginHost/Tests/PluginHostTests/HostLifecycleTestSupport.swift|04169c2cdd57e4c41ae4f30c400ac574242a44e0366121b300b3d6a564991cda|
|swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperActivationTests.swift|e96d851e86c12fab2ecf632fb2fdfd82b968c78ada7cbda18a276d74e897fc85|
|swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift|12dddc14329807020d93278d7301ec42113fbd7d51d5ecf307c10666c0fb58b8|
|swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperTests.swift|9c7bf8f9e7fda67d7af92a780b5436c5dfae8a9b62a436b4b069d77275f73927|
|telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginDeveloperProtocol.swift|86d91a889d5a5ce2ef06e259b574a3db2cb95d0f6237203ed5aadd22ff04e482|
|telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginElyxDeveloperIngress.swift|240832ce4b6b93e2f684e37938c5553de071e8d3394cc60c1d2f1e00b871db36|
|telegram-ios/submodules/TelegramUI/Tests/PluginElyxDeveloperProtocolTests.swift|89dc526819e5b4f6185fcafb45f612ed3fee61454ad46a3a7aff1b642948a640|
|tools/compat/tests/test_ios_elyx_source_authority.py|d0a4b5a51ad04c9e582c0c74453a8b924d7629b449574e9f5679f674c022ba23|
|tools/compat/tests/test_native_elyx_ingress.py|6d7955a9009afd8e65610bcca4b99f38b4a1c54d98f6c9e20ce48f47eea39110|
|tools/compat/tests/test_sdk_developer_native.py|eb57013f9f68a3e6bc1e43946d9e975601fae90f49e29f5d318a04bf3379ed93|

</details>

## Retained artifacts and context

Artifact **`elyx-fd-final-posix-43779077310`** uploaded and downloaded successfully: **16 evidence files**, retention 14 days. The always-run recorder retained separate Host/ingress JSON errors and expected counts, rather than inventing empty successful JUnit suites.

| Evidence | SHA-256 |
|---|---|
| `host/build.log` — full compiler diagnostic/invocation | `5f242bbd3b9c0ce34392839b66400ec1ca5ac40a6c48db193918b53f0c44afb8` |
| `host/counts.json` — no execution, expected 47 | `ef7476a91e0c0ab3ca03e930620a9d4925a4159a0a0daacd4de257404005526e` |
| `ingress/counts.json` — no execution, expected 7 | `2ebef9483fc7ad9428c604d7a0ddb7ea337b95740e93790a605e4a45d6bc3563` |
| `summary.json` | `90d0f96758dcef4360163117db94c7fa10984081999148bc0caa9d4b763fd84c` |
| `source-check.log` — 184 OK entries | `fa19869da0d855a5147369314aab7db54c8b2f8fc826ea66e061466e32f0f6a7` |
| `sources.sha256` | `4493857505295a7a5a36ab30c7449c7be944d872ab8d4866000259ca3e151541` |
| `cohort-sha.txt` | `cc3271264fa6c0decfe18052830ebea24e1919f944bf49bbe5fc10c8965b6ea5` |
| `elyx-posix-source-pins.json` | `c60fff83a6882348fe052ae1950f29934f16ced9d5e80a002ff8f645c136ed25` |

Frozen sources, the source seal, exact expected native case IDs, sanitized push/watch logs, actual GitHub metadata, failed-job logs and downloaded artifacts are retained under `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-fd-final-posix-20261116-86dc4a19`.

## Coverage boundary and caller custody

The intended Files 29 suite exercises the real native provider/registry, POSIX descriptors, publication/exchange/rollback, namespace custody, cleanup barriers and CAP-v1 dispatch, with its **fixture JSON inspector** explicitly standing in for full ZIP/SDK inspection. Activation 6 uses **recorded Python execution** while exercising actual Host workers/TLS/native bridge observation. Transaction/Host 12 and ingress 7 retain their stated authority/invocation recorders while checking typed publication outcomes, error envelopes and `source_changed` propagation. None executed in this run, so no assertion about those runtime behaviors is promoted from compilation or source review.

**Actual C/CPython fifth-child integration, private app Root startup, live listener/account/UI, and Darwin-specific rename/kqueue behavior remain separate pending native gates.** The ingress driver's declared Linux support and Foundation-only dependencies were inspected; native ingress execution remains blocked. No Python 50-case or prior Host 53-case suite was rerun.

Only a private `GIT_INDEX_FILE` and new verification branch were used. No main checkout/reset, main-index staging, source edit, main commit or main push was performed by this agent. Before/after preparation and CI observations recorded caller HEAD `54b2f7e8586b42ca5537333133d2427c2cccfae2` and index SHA-256 `ef0e9f13c754d3e676ecfa3d11d25589a1df3a0541f0e889e759e3298344fe53`; caller changes were treated as independent observations. This new receipt is the only authored caller-worktree file for the task.

A later read-only receipt validation observed caller HEAD `6de4ac36fefb54890a3dd043044e5a021a3d0e76` and index SHA-256 `dec54bf89631091bf4472e1056606e20431f873c3d3beb5bb8bff20f978d83c8`. That independent caller progression was not restored or incorporated into the executed snapshot.

The previous aborted provider-capture receipt and all previous successful/failed gate receipts were preserved. No unrelated app CI run was queried or cancelled. Local actionlint, helper/embedded Python syntax, exact sealed-hash/copy/index checks and `git diff --check` passed. A single run-scoped foreground watcher ran in a background shell with a 30-minute bound and at most three discovery/API attempts.
