# SDK developer/proxy remediation — 2026-11-15

**Three narrow adapter corrections are implemented; common installation/native
registration is supplied as a coordinator handoff, not applied here.** Five
bounded Python regressions passed, including actual C handles and an OWN_GIL
interpreter which was successfully destroyed. Native app execution is pending.

## Status and exact source

| Finding | Correction | Executed evidence / integration status |
|---|---|---|
| `ELYX-P2-01` | `python/virtualjava/proxy.py:102–114` gives the generic dynamic-proxy base a zero-argument initializer. `DynamicProxyMeta.__call__:80–89` already assigns `_fqcn/_backend`; `JavaInstance.__init__:146–148` remains the required two-argument native-value constructor. | Original `facade.gen/gen2`, all four lazy Utilities callbacks, local Runnable/OnClickListener and multi-method callbacks passed. This fix takes effect directly. |
| `ELYX-P2-02` | New `python/exteraless_runtime/_elyx_helpers.py:4–19` passes `request["@"]` and a separate parameter mapping to the original `elyx_runtime.handle_dev_command`. Framing/auth fields are excluded from params. `_developer.install` replaces only the runtime seam `dev_server._cmd_elyx`. | Original `dev_server.dispatch` authenticated ping, empty list and one real `ElyxPluginState` list passed; unknown command preserves the original failure. Installation hunk is pending coordinator application. |
| `utilities-P2-001` | New `_developer.py:27–110` replaces `dev_server.start/stop` and the loader's once wrapper with native readiness/admission calls. | Retry, pending, bind-failure status, permissions, malformed replies, missing provider, revocation-shaped failure and no Python listener/thread passed against a strict native-service recorder. Native provider/registration are handoff-only. |

Original witnesses remain at:

- `python/sdk/elyx_runtime/facade.py:126–181,195–202`: `gen/gen2` call
  `base.__init__(self)`; Utilities Callback/Callback2/Callback3 are void and
  CallbackReturn returns its implementation's value. Original Java declarations:
  `third_party/exteraless-android/TMessagesProj/src/main/java/org/telegram/messenger/Utilities.java:515–545`.
- `python/sdk/dev_server.py:230–241,257–284`: the original dict-shaped handoff
  conflicts with `python/sdk/elyx_runtime/dev_commands.py:236–247`.
- `python/sdk/dev_server.py:324–356` and
  `python/sdk/extera_utils/plugin_loader.py:3635–3650`: daemon listener and early
  once latch. The policy is `SubinterpreterManager.swift:21–38` →
  `python/runtime/engine.c:265–272`, with OWN_GIL and daemon/fork/exec disabled.

Before editing, actual original helpers reproduced both missing-constructor-args
`TypeError`s and the dictionary-string “unknown Elyx command” response. No SDK
helper was reconstructed in a test. The generic initializer repair is deliberately
at the dynamic-proxy base, where a Java interface has no native constructor;
it does not implement JVM class generation, Java super dispatch or MVEL.

**36/36 `python/sdk/**/*.py` files still match their Original counterparts
byte-for-byte.** Archive P1 work in `_archives.py`, `__init__.py` and Host files
belongs to the parallel archive owner. This receipt does not adjudicate its
moving working-tree changes or update the earlier symbol inventory flags.

## Native controls and readiness contract

The existing application provider is real:

- `TelegramUI/Sources/ExteralessClient/PluginUI/PluginDeveloperServer.swift:33–99`
  starts NWListener on `127.0.0.1:42690`, bounds connections at four, and publishes
  a non-null native token **only on `.ready`**. Failed startup clears the session
  for retry. `stop:43–49` revokes synchronously; `stopOnQueue:101–110` cancels
  sockets/tasks and removes the token file.
- `PluginDeveloperProtocol.swift:36–49` authenticates before handler dispatch.
  `Exteraless/ExteralessPluginRuntime.swift:891–897,912–969` owns GUI developer
  mode, account/runtime/maintenance gates and the actual native manager commands.

`NativeDeveloperServer.start()` always samples native state, including after a
previous success. It returns True and sets `_dev_server_started` only for a strict
`ready=True` response. Disabled, starting, waiting, failed and malformed states
return False with a diagnostic; the once flag remains false. A retry is requested
only while native developer mode is already enabled. The main-actor application
gate checks it again, so a queued retry cannot turn GUI developer mode back on.
Admission alone is never reported as readiness. There is no polling/wait loop on
the Python/C owner worker.

`plugin_loader.start_dev_server()` retains its `None` return and guarded wrapper,
but refreshes readiness instead of trusting the old once latch. `stop()` retains
its `None` return after **native admission**, clears the Python latch and requests
developer-mode off through the existing durable manager preference control.
It does not claim that asynchronous listener cancellation has already completed.
Denied/malformed stop admission raises its precise error. Post-admission native
failures are logged by the native provider; later start calls remain retryable.

### Exact metadata descriptor / coordinator patch

Apply/review [`sdk-developer-proxy-native.patch`](sdk-developer-proxy-native.patch)
as one integration handoff. `git apply --check` passed locally. It contains:

1. The two-line `_platform.py` install seam, after the concrete providers.
   Installation is inert: it never calls start or queries a developer service.
2. New `PluginDeveloperBridgeExtension.swift`, using the existing bounded
   `ExteraConfigCommandQueue` (128 total / 32 per owner), current immutable C
   owner epoch and the existing **settings** permission.
3. Composition registration alongside `PluginConfigBridgeExtension` in
   `ExteralessPluginRuntime.swift`. Retry uses `updateDeveloperServer()` under
   its actual main-actor gates; stop uses `updateManagerPreference(.developer(false),
   authority:)`. No pipeline/bootstrap auto-start is added.

The **required discovery descriptor** is `PluginBridgeExtension.exportedMethods`:

```text
exteraless.ios.Runtime
  getDeveloperServerState()     -> {ready: Bool, enabled: Bool, status: String}
  requestDeveloperServerStart() -> {accepted: true, operationId: nonempty String}
  requestDeveloperServerStop()  -> {accepted: true, operationId: nonempty String}
```

All three are zero-argument static `call` methods. `member_kind` must return
`"method"`; descriptor lookup has no effect. There is no separate
`metadataDescriptor` API in the current protocol: the actual route is
`PluginBridgeExtension.swift:5–46` → `BridgeServices.swift:215–235` and
`_platform.py:323–325`'s `register_native_metadata`. Adding a callable name only to
Python or the compatibility inventory would not install this provider.
Without the handoff provider, the adapter returns False with the exact missing
`Runtime.getDeveloperServerState` diagnostic instead of starting Python TCP.
TelegramUI's existing `Sources/**/*.swift` glob includes the new Swift file;
the isolated contract-source list is a different target.

### Authority and remaining routes

- The native `.devserver_token`/auth token never crosses these bridge methods.
  The provider exports only readiness/status and opaque operation admission IDs.
  C injects plugin ID/owner epoch; native checks and queued-current checks remain
  authoritative. Python fields cannot select another owner or elevate a grant.
- Original `dev_server.dispatch` still performs its own token comparison before
  the Elyx action. That token is interpreter-local and is never populated from
  the native token. Its manager commands now fail explicitly rather than gaining
  host-wide command forwarding through the shim. Native authenticated management
  stays in `PluginDeveloperServer` → `handleDeveloperRequest`.
- Direct SDK debugger commands return the exact unsupported OWN_GIL policy:
  `allow_fork=false, allow_exec=false, allow_daemon_threads=false`; no debugpy
  import/listen or successful-looking debugger session is manufactured. The
  existing native handler also has an explicit debugpy failure at lines 966–967.
- **Native socket Elyx live-sync is still a separate missing route.** The current
  Swift handler's default rejects `elyx_*`/`get_elyx_plugins`; this handoff adds
  listener controls, not a host-wide worker-command API. The repaired original
  Python dispatcher handles the interpreter's actual Elyx `_states`. Routing a
  native authenticated session to the correct worker, archive compare/change
  semantics and Host reload are not proved by the local ping/list fixture.

## Local validation and exact limits

`tools/compat/tests/test_sdk_developer_proxy.py`: **5 passed in 4.51 s**, Windows
CPython **3.14.8**, `-I -S -B` children, **20 s maximum per child**. Fixture roots
are under `C:\Users\sasha\AppData\Local\Temp\opencode`.

The combined focused regression run (these tests, `test_virtualjava.py`, the
existing `test_sdk_wave2[registry]`, and the native fixture's platform gate)
finished **16 passed, 1 skipped in 5.85 s**. The only skip was the Darwin listener
fixture; this was not an attempted native compile.

- Generic proxies use the actual facade functions and declared interface names;
  callback arguments, extras, void/results, exception fallback, cache/identity,
  ordinary JavaInstance arity and stale handles are exercised through
  `exteraless_runtime.invoke_handle_json`.
- The C case uses the existing `.pyd`'s real `BridgeBackend` and handle functions.
  It resolved and released the actual objects, with zero handles after unload.
  **That local binary lacks `xt_set_plugin_id`, `xt_set_owner_token` and exported
  native dispatcher/buffer ABI.** Its C-handle receipt is not a fresh C-source,
  C-owner-epoch, Swift transport or iOS engine receipt. Native service calls in
  these fixtures are explicitly recorded Python doubles.
- The OWN_GIL child checks its actual `_interpreters.get_config` (`gil='own'`,
  daemon/fork/exec disabled), observes the real daemon-constructor rejection,
  then runs the developer adapter regressions with Python listener/thread
  creation trapped. `Interpreter.close()` completes within the outer deadline.
- The initial isolated Elyx import failed with `ModuleNotFoundError: yaml`.
  Fixtures explicitly add the already installed host PyYAML location, without
  site initialization/downloads. This is not verification of an iOS vendor bundle.

New Darwin-only `test_sdk_developer_native.py` plus
`fixtures/sdk_developer/NativeDeveloperServerProbe.swift` compiles the **actual**
native listener/protocol/UI wire sources, then checks readiness, own port conflict,
retry, free ping, bad/retired tokens and synchronous session revocation. It sends
only to a listener the fixture itself proved ready. Limits: 18 s compile, 10 s
execution, 30 s outer process. **Provided, not executed on Windows.** It does not
compile the PluginHost-dependent bridge/composition handoff; that needs native
application compilation by the coordinator.

Run the bounded regression files explicitly:

```text
python -B -m pytest tools/compat/tests/test_sdk_developer_proxy.py -q -s -p no:cacheprovider
# Darwin only (real loopback source fixture):
python3 -B -m pytest tools/compat/tests/test_sdk_developer_native.py -q -s -p no:cacheprovider
```

No CI, running app, external HTTP or accounts were queried. The supplied GREEN
SDK3/Core680/C219 context and running app build are separate receipts, not results
of this correction.

## Raw source pins

| File | SHA-256 |
|---|---|
| `python/sdk/elyx_runtime/facade.py` | `a61a3b1920f3daf9fbb4d42df9af65f46f9da03782f847c3dc8463a291c0f390` |
| `python/sdk/elyx_runtime/dev_commands.py` | `5d33aaac3e89f36d3eb7d6bf7f0ee43219b5d871f18c68aec837310e8e8b2ee3` |
| `python/sdk/dev_server.py` | `686dac5329b52f478a8ab9b1c837e752cd6c61a22022a3979cbd7105b77d1e38` |
| `python/sdk/extera_utils/plugin_loader.py` | `c90134bde58559d675ffeff313eecd4223f39d60edbe0992137b41461b6547f5` |
| `python/virtualjava/proxy.py` | `025acce2920244788ec5f69874228b5db459fc3a3c5b5555edeb85f10d32de92` |
| `python/exteraless_runtime/_developer.py` | `22611badcf6c3be224e68c3f9acdefeae7edff937e1aa5a278b68b0eed27ff2d` |
| `python/exteraless_runtime/_elyx_helpers.py` | `f9a9cd73cbaf0d7ab987a1158e090935ec4fdd936f837e1801b04a2d4f0abaee` |
| Existing Windows C extension | `3aeb8aae3d38a33c3bb2eb0bd3b0b3f027565aa55a8621a22385fd4e64bf18b0` |
| `PluginDeveloperServer.swift` | `4b89315efbd8f9a9705d2b4cdf457e2db1d2a4c02d84ca50c8a41b826c68be92` |
| `PluginDeveloperProtocol.swift` | `10264599523943c3de7d15d56688aaa5805f2a98229921cee2ae3dacb5e6f096` |
| `ExteralessPluginRuntime.swift` handoff base | `6998d97a25376dcdc8f9b965ef5fcc4f1a3309b309b30fd74e9c90ed13f019ee` |

## Coordinator integration delta

The native patch's provider, Runtime composition and inert `_platform.install`
seam are applied in the working tree. Other owners are completing the shared
runtime cohort; these common files are not yet a separately published snapshot.
The Darwin fixture now separates a 120-second cold compilation budget from its
unchanged ten-second listener execution budget, with process-group cleanup. This
supersedes the earlier 18/10/30 budget above and still requires actual Darwin execution.
