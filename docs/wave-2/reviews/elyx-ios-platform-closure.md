# Elyx iOS platform selection — P2-01 closure

2026-11-16. **Verdict: SOURCE-CLOSED.** No remaining P1/P2 was found in this
exact platform-selector follow-up. **Actual iOS FD execution remains pending**;
`native_execution_claimed: false`.

Reviewed input:
[`elyx-archive-p2-inputs.json`](../elyx-archive-p2-inputs.json) and the applied
[`elyx-ios-fd-probe-coordinator.patch`](../elyx-ios-fd-probe-coordinator.patch).
The earlier P1 conclusions are used only as the inverse-hash baseline.

## Exact production change

All **5/5 P2 receipt hashes match** the current files. The production delta is
exactly three occurrences of
`sys.platform == "darwin"` → `sys.platform in ("darwin", "ios")`:

| Source | Line | Effect |
|---|---:|---|
| `python/exteraless_runtime/_audit_paths.py` | 170 | iOS selects lexical `/var`, `/tmp`, `/etc` → `/private/...` normalization, without resolving an untrusted descendant. |
| `python/exteraless_runtime/_audit_paths.py` | 186 | iOS selects real `fcntl.F_GETPATH`; Linux retains its separate `/proc/self/fd` branch. |
| `python/exteraless_runtime/_archives.py` | 913 | iOS selects the qualified OS-root alias pinning branch before the held-directory walk. |

Replacing those expressions back in memory restores the previous P1 bytes:

| File | Replacements | Inverse SHA-256, equal to P1 receipt |
|---|---:|---|
| `_audit_paths.py` | 2 | `3e0d7444eb0dd7a035f55e92d438e1dcf54c62f79b7a83b1a68f4ccf87921e03` |
| `_archives.py` | 1 | `04a0403b7df7977b22714156394430a7760559252745a16d7d7bbcc3e5c9f824` |

This establishes the narrow delta: Linux selection, literal root-alias targets,
descendant nofollow rules, source-image/code-label logic and descriptor ownership
are not rewritten by this fix. The root branch still accepts only `private/<name>`
or `/private/<name>` for the three documented OS aliases.

The previously demonstrated `ios` path now reaches `F_GETPATH` instead of
returning None solely because its platform name is not `darwin`. An actual
F_GETPATH failure still returns None; it does not fall through to a Linux
implementation.

## Applied native probe: actual call path

The coordinator patch is present in both current fixture files;
`git apply --reverse --check docs/wave-2/elyx-ios-fd-probe-coordinator.patch`
passed without applying or reversing any edit.

The source route is:

1. `python/runtime/smoke/swift_plugin_probe.swift:138–158` loads the trusted
   probe helper before the normal Host source and exports its checks handle
   after the SDK plugin load.
2. `swift_plugin_probe.swift:516–522` invokes the checks handle's
   **`verify_services`** through the current Host and requires successful service
   verification.
3. `python/runtime/smoke/native_plugin_probe.py:124–140,367–399` checks the owner
   worker, obtains the actual SDK `PluginRecord`, obtains native directories and
   calls `_probe_darwin_family_fds(record, directories["cache"])`.
4. `_probe_darwin_family_fds:151–198` uses the executing `sys.platform`, the real
   `_Extraction` and real OS descriptors. Trusted helper code creates the tiny
   asset/code files and opens exactly two file descriptors relative to their
   held parent directory.
5. Line **174** calls **`record.instance.fd_family_probe`**, whose body lives in
   the real owned plugin source
   `python/runtime/smoke/plugins/native_wave_probe.plugin:31–51`. Thus the
   guarded write attempts have a plugin code frame; setup is not substituted
   for the plugin-frame check.

The native plugin method requires:

- asset `os.write` returns exactly five bytes;
- code-FD `os.write` raises `PermissionError` containing `archive code`;
- relative `os.open("code.py", O_WRONLY | O_TRUNC, dir_fd=...)` raises the same
  archive-code denial, closing an unexpectedly returned fd before failing.

The trusted helper then verifies real F_GETPATH/`samefile` agreement with the
asset inode and reads back `owned` from that fd. It creates a real descendant
symlink and requires `_Directory.open_native` to reject it. No native probe
function patches `sys.platform`, installs a counted `fcntl` stand-in, or uses
the platform suite's `RootTrace`.

The helper holds the parent directory object while both file descriptors are
borrowed by the plugin method. Its `finally` closes the file descriptors, then
performs extraction cleanup and closes the held directory pool. The fixture
uses a fresh UUID-qualified load directory and only tiny owned data.

### Result flags and acceptance boundary

`native_plugin_probe.py:189–191` sets:

- `darwin_family_fd_paths` only after the FD/readback/link assertions succeed;
- **`actual_ios_fd_paths` only inside `if sys.platform == "ios"`**.

The helper returns early on Linux and does not set either flag there. The
checks are included in `snapshot_json` as `sdkChecks` at line 457. Outer
`servicesVerified` is set only after the helper returns, including its cleanup.
Future acceptance must use the flag from a successfully completed,
source-pinned run on the matching platform. These source assignments do not
constitute an emitted native result in this review.

## Independently performed checks

On Windows CPython 3.12, the focused suite was rerun with pytest plugin
autoload/cache output disabled, a 30-second outer tool budget, a 25-second test
launcher limit and the suite's existing 20-second child limits:

```text
tools/compat/tests/test_ios_elyx_platform.py
4 passed, 1 skipped in 1.20s
```

The four passes cover `darwin`, `ios`, Linux and root-alias selection, including
F_GETPATH failure without Linux fallback and rejection of an unexpected root
alias target. They deliberately use counted selector stand-ins plus real owned
Windows file descriptors. **The actual POSIX FD case was explicitly skipped**;
these results are not Darwin/iOS syscall evidence.

Additional data/source checks passed:

- all five P2 receipt hashes;
- exact two-file, three-expression inverse match to the P1 hashes;
- applied native probe patch via the read-only reverse-apply check;
- AST parsing of both production files, the platform test and both native
  Python fixtures; no `sys.platform` assignment in the native fixtures;
- **36/36 Original/SDK Python files byte-identical**;
- historical P1 closure report retained at its existing hash.

Only this new review report was authored. Native probe/plugin execution, CI,
network and account operations were not performed.

## Historical result and pending native evidence

The coordinator-reported Linux/POSIX result **43768124344 / ff913492 — 42 passed,
0 skipped** is preserved as historical **pre-selector-fix** evidence. It was
not queried or rerun here and is not a green iOS result.

The new probe is source-connected and uses actual platform/FD operations when
run natively. A fresh iOS receipt with `actual_ios_fd_paths`, and the applicable
Mac/native gates, remains pending. No UIKit or whole-archive acceptance is
inferred from this focused platform closure.

## Source pins

HEAD observed: `31287b9204aef5384b85d75f97f233dccf230409`. Hashes below are over
the reviewed current raw bytes, including the two coordinator-edited fixtures.

```text
2bc190ed5a1b4854f038fdd86ee938d10584ef2f6271632eedab1aecd2640cc6  docs/wave-2/elyx-archive-p2-inputs.json
7c9474064d6afede795502b022f8a4e20ecde27fe44d92cd27d88b299fd927d5  docs/wave-2/elyx-archive-p1-inputs.json
f68ed0c19989f959fd376fe94a3ca75365ade9be0e68244de3c29ab5a204773e  python/exteraless_runtime/_archives.py
da7fcc6c4c5ea4cef9fbb7576f26f858eb63276961569a7fe1d8f6aef0b8b40e  python/exteraless_runtime/_audit_paths.py
27500bfa24b106ae4bc742a3adc2bfa2a39c7a881c0b5d6ef5e26b09df46e96d  tools/compat/tests/test_ios_elyx_platform.py
b866f2d05bc22edd858eee9642c6b52d8a5da06e17557b6e2f595e4fdc19f138  docs/wave-2/elyx-ios-fd-probe-coordinator.patch
60b5cfe07246fac7d7a924723bee0091d39c03f0193ed86a6dd9a3ca37c98d92  docs/wave-2/elyx-archive-remediation.md
d54c15079a7eb8fc6a2dec8a2e65cd59c54e89e70ae172a24a463a3020ed6d97  python/runtime/smoke/native_plugin_probe.py
a0e2bd5847c904eb85205b6fd2ad6c24b91a9a5fab130acd7f72290a18d4932e  python/runtime/smoke/plugins/native_wave_probe.plugin
0b5287f71143e07bc22f91975546aba9136094499c59779b496c9292d3d8c742  python/runtime/smoke/swift_plugin_probe.swift
2d671e48b31d7de4841bba6a3bbeb2261ef949c6bb95922aa21665d2b2222a6f  docs/wave-2/reviews/elyx-archive-p1-closure.md
```
