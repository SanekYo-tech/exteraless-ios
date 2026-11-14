# Embedded SDK audit-path fix

## Cause and reproduction

CI `43629521505`, code `36e3aba2`, failed in the real SDK `load_plugin` while
`nativeWaveProbe.on_plugin_load` imported `cachetools`. The relevant artifacts are
`build/artifacts/python-runtime-43629521505/python-plugin/swift-plugin-smoke.json`
and `swift-plugin-console.log`. The native engine/bridge compiled and cleanup
completed; this failure was in Python file attribution.

The SDK's `audit_gate._runtime_paths()` evaluates this tuple **before** entering
the first iteration:

```python
(sys.prefix, sys.base_prefix, os.path.dirname(os.__file__))
```

Embedded CPython's frozen `os` may have no `__file__`. CPython's actual
`FrozenImporter._resolve_filename` returns no filename when `sys._stdlib_dir` is
unavailable. The resulting `AttributeError` is caught by the SDK's broad `except`,
which stores the still-empty set as `_runtime_prefixes = ()`. The `sys.path` loop
is never reached, and the empty result is then cached permanently. It is not a
missing wheel, failed dependency specifier or late removal of vendor from sys.path.

Before applying the fix, two fresh Python 3.12.10 subprocesses used the real
`python/vendor` bundle and native-service grants `ui`, `messages.send`, `network`:

- Normal frozen-module metadata: imports passed.
- `sys._stdlib_dir = None`, then a fresh **real CPython frozen os module** created
  through `FrozenImporter`/`module_from_spec`/`exec_module`: failed on
  `import cachetools` with the same SDK traceback and `PermissionError` as CI.

The failing child recorded:

```json
{"os_file": null, "stdlib_dir": null, "runtime_prefixes": [], "vendor_on_sys_path": true}
```

Only frozen-module metadata was varied; SDK import/audit helpers were executed
from their actual source files. The CI artifact does not itself log `os.__file__`;
the controlled reproduction supplies the missing observation and isolates this
failure mechanism.

## Adapter changes

`Platform.install` installs `_audit_paths` before any plugin module/lifecycle
execution. Paths are resolved once in the owner interpreter, with these sources:

- Actual SDK, adapter and virtualjava package directories.
- The vendor directory returned by the validated `ProvidedDependencies` bundle.
- Stdlib anchors from `importlib`, `encodings`, optional `os.__file__`, optional
  `sys._stdlib_dir`, and `sysconfig` stdlib/platstdlib/extension locations.
- Explicit stdlib ZIP/Python binary files and the Windows DLLs directory.
- For the standard iOS app layout: Python.framework and **only** the extension
  frameworks named by validated stdlib `.fwork` files. Their `.origin`/data files
  are covered by the same read-only framework directories. The marker reader is
  bounded and does not load code; other frameworks, including TelegramUI, receive
  no implicit runtime exemption.

The SDK providers `_runtime_paths` and `_is_runtime_file` use this captured
inventory, independently of the old cache and later sys.path changes. Whole
`sys.prefix`, `sys.base_prefix`, sys.path entries, plugin trees and Application
Support are not runtime roots. Plugin/settings/native files/cache directories are
explicitly excluded; a candidate prefix covering those directories is rejected.
Paths are canonicalized with realpath/normcase and directory boundaries.

The existing SDK audit hook and native permission providers still decide ordinary
file/network access. The adapter additionally enforces read-only runtime targets
through the SDK protected-write seam, including write flags, rename/removal of
parent directories and hard-link aliases. Granting `files`/`hooks` does not bypass
this read-only check under the active SDK policy. Direct `open` and SDK read/list
helpers may read trusted runtime files, while the underlying C open still emits
its real audit event.

iOS own-data roots are explicit: native per-plugin files/cache and the SDK
`<plugins_dir>/.data/<plugin_id>` directory. The host creates that scoped directory
before plugin execution. The Android fallback's app-wide TMPDIR exemption and
incorrect `getFilesDir()/plugins` storage inference are replaced with the actual
configured plugin/settings paths. No bundle directory is classified as plugin-owned.

## Checks and limits of the result

`tools/compat/tests/test_ios_runtime.py` adds `audit_paths`, `audit_paths_frozen`
and `audit_layout`, plus the small local `audit_import.plugin` fixture.
Every case runs in its own `-I -S -B` child with a **20-second hard timeout**.

The two import cases execute actual pinned `cachetools`, `certifi`, `requests`,
the SDK loader/audit code, and the adapter. Only native host services are a strict
unit fixture. Distribution metadata is **not** substituted in these cases.

For each normal/frozen case:

- Load, cachetools LRU operations, version/source-path checks, certifi CA-file
  reads, scoped own-data directories and unload succeed without `files`.
- Twelve foreign reads (builtin open, pathlib and SDK read_file across foreign
  data, shared TMPDIR, another plugin and settings) raise PermissionError.
- Eight mutation attempts against bundled files/parents/hard-link aliases are
  denied, including with `files`/`hooks` granted for this negative check.
- Revoking native `network` causes a real SDK denial of
  `sys.audit("socket.getaddrinfo", ...)`; no DNS lookup or connection is made.
- Unavailable `hasPermission` or `isUnsafeMode` providers also deny the audit event.
  Their failures become PermissionError so the SDK audit wrapper cannot swallow
  an ordinary helper error and accidentally allow the operation.
- Both `files` and `network` finish denied, unsafe mode stays false, context and
  callback/loader registries are cleaned up.

`audit_layout` checks actual temporary filesystem `.fwork` metadata, framework
selection, containment and rejection of over-broad/plugin roots; it does not
execute framework binaries.

Run from the repository root (the sealed `python/vendor` bundle must exist):

```powershell
& 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe' -B -m pytest tools/compat/tests/test_ios_runtime.py -q -s --basetemp='C:\Users\sasha\AppData\Local\Temp\opencode\ios-audit-check'
```

Local result: **12 passed on Python 3.12.10**, **12 passed on Python 3.14.8**.
This verifies the reproduced Python blocker and permission boundaries on the
host. A new macOS/iOS native integration run is still needed for this patch;
these tests do not claim UIKit, Telegram service or IPA execution.
