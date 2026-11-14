# Provided pure-Python dependencies (wave 2)

The build stages universal wheels into **`App.app/python/vendor/`**. The app
checks requirements against those already provided distributions; it never runs
pip, downloads a requirement or accepts a plugin-supplied wheel URL.

## Lock (PyPI, resolved 2026-11-14)

`python/runtime/dependency-lock.json` records each exact wheel URL, a
version-specific PyPI JSON URL, SHA-256, byte size, Requires-Python, Requires-Dist,
extras and the permitted top-level import roots. All wheels are `py3-none-any`,
not platform/native builds (including the pure variant of charset-normalizer).

| Distribution | Version | Requires-Python | Wheel bytes |
| --- | --- | --- | ---: |
| packaging | 26.3 | >=3.9 | 129956 |
| requests | 2.34.2 | >=3.10 | 73075 |
| urllib3 | 2.8.0 | >=3.10 | 135717 |
| idna | 3.20 | >=3.9 | 69583 |
| certifi | 2026.10.23 | >=3.7 | 135082 |
| charset-normalizer | 3.5.2 | >=3.7 | 68872 |
| cachetools | 8.0.0 | >=3.11 | 18610 |
| typing-extensions | 4.16.0 | >=3.9 | 45571 |

Total download: **676466 bytes**. Verified extracted files: **2265848 bytes**
(165 files), plus a 31569-byte manifest: **2297417 bytes total**.
All mandatory dependencies of requests are
included at satisfying versions. No extras are selected by the build; a plugin
requesting an extra must also have every activated dependency provided. For
example, `requests[socks]` fails with a named missing `pysocks` dependency.

## Build tool

From the repository root, using only the Python standard library:

```powershell
& 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe' -I -S -B tools/runtime/vendor_dependencies.py --cache 'C:\Users\sasha\AppData\Local\Temp\opencode\ios-python-wheel-cache' --output 'C:\Users\sasha\AppData\Local\Temp\opencode\ios-python-vendor-20261114' --report 'C:\Users\sasha\AppData\Local\Temp\opencode\ios-python-dependency-report.json'
```

These paths contain the locally verified wheels, extracted bundle and report.
All eight wheels were fetched once; already verified cache entries were reused.
The report's `wheel_code_executed` is false: the builder reads ZIP/metadata/data
only, never imports the downloaded packaging module or any other wheel code.

The coordinator can call the same CLI with its staging directory as `--output`,
then copy the **contents of that output** into `App.app/python/vendor`. The output
is already the site-packages root: no extra `site-packages/` nesting is needed.
`--report` must be outside the output tree. Optional `--lock PATH` selects the
lock file; `--offline` uses cached wheels or a re-verified existing output and
performs no fetches.
Python API: `vendor_dependencies.vendor(cache, output, lock_path=..., offline=True)`.

The tool streams fetch, hashing and extraction in 64 KiB blocks. Limits are
2 MiB per compressed wheel, 8 MiB total downloads, 8 MiB per expanded file,
32 MiB total expanded files and 2000 ZIP entries per wheel. It requires the
locked SHA-256/size, checks WHEEL's purelib/tag declarations, matches METADATA to
the lock, and rejects unsafe paths, symlinks, case-colliding files, native/binary
suffixes/content, `.pth` and unexpected import roots. `.dist-info`, RECORD,
licenses and data such as certifi's CA bundle are retained.

Staging happens in a private sibling directory and is published only after all
checks pass. An existing identical managed output is re-verified and reused;
a nonempty unrelated or different-lock output is refused. A different lock can
be staged into a fresh directory. The builder's fixed-lock constraint checker
is intentionally limited to numeric stable versions and the pinned optional-extra
marker forms. Unsupported metadata syntax requires a deliberate tool/lock update;
general plugin requirements use the real packaging parser at runtime.

## Manifest / interpreter contract

The output marker is **`exteraless-dependencies.json`**, schema 1, generator
`exteraless-pure-python-dependencies-v1`. It records the lock hash, package
inventory and per-file sizes/SHA-256. `bundle_sha256` is SHA-256 of canonical
UTF-8 JSON `{lock_sha256, files}` (sorted keys, compact separators, ensure_ascii=False).
For this verified bundle it is:

```text
17d37c2c2c6ef2852ebd7b758461f3961c6e24b91a394d6b639ea29b893e872b
```

`configure` validates this inventory/metadata before adding `python/vendor` after
`python/sdk`. It uses `importlib.metadata.Distribution.at` on those exact
`.dist-info` directories; arbitrary site-packages, plugin directories and
virtualjava's permissive class lookup cannot claim that a dependency is provided.
Top-level imports are restricted to the eight names; stdlib shadowing is refused.
Normal `importlib.metadata.version()` / `distributions()` can also discover the
preserved `.dist-info` through the resulting sys.path, separately per interpreter.

The adapter replaces the SDK's requirement installer and provided-version
providers. It also disables SDK PyPI resolution/download and makes requirement
removal a read-only operation. The SDK's original "use bundled version anyway"
conflict fallback and per-plugin pip refcount/deletion paths are not used.

Requirements support version constraints, name normalization, actual-sys markers,
Requires-Python and declared extras/transitive dependencies. Examples:

```python
__requirements__ = ["requests>=2.34,<3", "cachetools==8.0.0", "typing_extensions>=4.16"]
```

`cachetools<8`, an absent package, an unknown/unsatisfied extra, invalid PEP 508
or `requests @ https://...` fails with the named requirement in `PluginLoadError`.
Native packages, runtime installation and packages outside the provided set are
unsupported. This is a bounded dependency surface, not readiness of all plugins.

## Focused checks

`tools/runtime/tests/test_dependency_bundle.py` uses small synthetic wheels whose
modules raise if accidentally imported. It covers the lock/dependency closure,
checksums, streaming bounds, unsafe ZIP paths, symlinks, binary/native wheels,
atomic output, preserved distribution metadata and sys.path ordering.

The new `requirements` case in `tools/compat/tests/test_ios_runtime.py` runs the
real SDK loader/checker with injected distribution metadata and the strict native
host double. It uses the host's **already installed** packaging parser, never the
downloaded wheel code. Satisfied, missing, mismatched, URL, marker, Python-version
and extra/transitive cases run in an isolated process with a 20-second timeout.

Local verification on 2026-11-14: **40 passed** on CPython **3.12.10** and
**40 passed** on **3.14.8** across these two test files. The dependency SDK case
entered the real SDK `load_plugin` nine times; only the satisfied declaration
reached module execution (`_import_module` once). The real eight-wheel bundle
also passed the CLI's complete offline re-verification with the hash above.
