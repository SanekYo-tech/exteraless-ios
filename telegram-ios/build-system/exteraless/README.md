# Telegram runtime packaging

Prepare the external source module **before** running Make.py, from the outer
exteraless-ios checkout:

```sh
python3 tools/runtime/prepare_telegram_runtime.py --telegram-root telegram-ios
```

`--cache PATH` reuses the downloaded support archive; `--archive PATH` accepts an
existing copy. Both paths require the SHA-256 in `python/runtime/support-lock.json`.
CI passes `--source-root "$GITHUB_WORKSPACE" --telegram-root "$SOURCE_DIR"` after
relocating Telegram. No plugin corpus is needed.

`--dependency-cache PATH` caches the eight universal wheels pinned by
`python/runtime/dependency-lock.json`. They are staged without pip or executing
their code in `python/vendor`, then copied byte-for-byte with the sealed file
inventory to the app. The preparer and final IPA verifier both check the seal.

The generated module is `telegram-ios/build-input/exteraless` (gitignored).
Re-run preparation after source changes. Make.py checks the complete staged file
inventory and, in a local outer checkout, refuses outdated source fingerprints.
Preparation never builds or modifies an IPA.

## Build graph

| Telegram label | Swift module / purpose |
| --- | --- |
| `//third-party/exteraless:PluginHost` | `PluginHost`, including the native engine and binding; TelegramUI dependency |
| `//third-party/exteraless:PluginHooks` | `PluginHooks` + its C11 atomic gate; TelegramCore and TelegramUI dependency |
| `//third-party/exteraless:RuntimeFrameworks` | Python + 54 `bundle_only` extension imports; main app dependency |
| `//third-party/exteraless:RuntimeResources` | Main app resources with preserved directories |

`@exteraless//python/runtime:CExteralessPythonBridge` exposes the public C ABI.
The implementation compiles `engine.c`, `register_bridge.c`,
`cpython312_compat.c` and `_exteraless_bridge.c` into a static archive, using the
same support archive's CPython 3.12.16 public/internal headers. The pinned
rules_swift generates the public Clang module; its rejected legacy `module_map`
attribute is not used. Diagnostic bridge XCFrameworks are not build inputs.

PluginHooks has one linked copy in TelegramCoreFramework. Its existing computed
export list includes the symbols needed by TelegramUI, which avoids linking that
archive again. PluginHost and the C runtime live in TelegramUIFramework.
Initialization remains an explicit main-application lifecycle operation.

The app embeds all Python frameworks directly in `Frameworks/`. The four UI-linked
extensions reach Python through TelegramUIFramework; Widget and Siri use Core.
All six keep `@executable_path/../../Frameworks`. TelegramUIFramework additionally
has `@loader_path/..`; `ios_framework.linkopts` takes raw linker arguments at the
pinned rules revision. Imported frameworks belong in `deps`, not `frameworks`.

Resources are `python-stdlib/lib/python3.12`, `python/virtualjava`, `python/sdk`,
`python/exteraless_runtime` and `python/compat-manifest.json`. Test suites, build
headers/configuration and native `.so` files are excluded from resources.
The compatibility manifest uses `compat-classes.txt` and the versioned Android
declarations/parser. It contains no corpus execution or compatibility-rate claim.

## Checks

Unsigned Make.py runs its existing signing preflight plus runtime action checks:
the four C compiles, native Swift binding/hooks, all main-app framework imports
and the shared framework's rpath. CI publishes structural reports only.

After the build, `Make/RuntimePackaging.py` verifies the actual IPA's resource
hashes, `.fwork`/`.origin` pairs, Mach-O platforms, dynamic Python install name and
dependency resolution from the app, all six extensions and all dynload modules.
It also rejects a Python dependency from TelegramCoreFramework. This is packaging
verification; interpreter execution and installed-app behavior need separate tests.
