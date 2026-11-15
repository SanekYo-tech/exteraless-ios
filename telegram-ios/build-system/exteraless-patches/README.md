# Canonical client source patches

`mtproto-engine-native-dns.patch` carries the Network/Maps owner's three Rust
source changes outside the nested gitlink. The base remains
`da4b2170210aab0430c4ff18c032991f3030cf45`; upstream remotes and submodule pins are
not changed. Commit these ordinary outer-repository files with the preparation
hooks before a fresh native CI build.

The canonical applicator is `build-system/Make/ClientSourcePatches.py`, exposed
from the outer checkout as:

```sh
python -B tools/runtime/apply_telegram_client_patches.py --prove-clean-base \
  --report build/client-source-patches.json
```

Use `--verify-only` to require the already-prepared state without writes. The
helper accepts all three exact preimages, or all three exact postimages. Unknown,
missing, mixed or partially applied sources fail before application. A Git worktree
must still have the pinned HEAD; a gitless source copy is checked by the same raw
file hashes. There is no reset, upstream push, fuzzy application or hash repinning.

## Exact bytes, including line endings

`manifest.json` is the authority for each file's raw preimage/postimage SHA-256
and byte count. Preimages are the raw LF blobs from `git show BASE:path`. The
author's Windows postimages contain mixed CRLF/LF. The checked-in diff is the
exact LF `git diff --binary --full-index --no-ext-diff --unified=0`; the metadata's
1-based inclusive `postimage_crlf_ranges` reconstruct those exact raw bytes.
Hashes are never normalized. Use the canonical helper rather than plain
`git apply`, which does not encode this raw line-ending map.

The entire output is constructed and checked before any source is replaced.
Already-correct postimages are read-only, including their modification times.
`.gitattributes` preserves patch/metadata bytes across checkouts.

## Entry points and evidence

- App CI proves replay from three temporary `git show` files and prepares the
  checkout before its git-metadata-free canonical copy.
- Harness CLI staging performs that proof/preparation inside the existing owned
  workspace lock before rsync. Its build and IPA checks verify the resulting stamp.
- Runtime source preparation checks both checkout and relocated copy before the
  support download. Make's common Bazel entrypoint prepares local build/test inputs;
  remote/VM Make builds prepare before copying too.
- Runtime staging, preflight and IPA reports carry `client_source_patches` with
  patch/metadata/helper hashes, raw postimages and a deterministic source fingerprint.
  Old or changed staging is rejected. These build-only inputs are not app resources.
- CPython-only jobs need no Rust checkout or Rust compiler. Their fingerprint
  includes the tracked contract/helper; full Telegram/harness preparation requires
  the actual three Rust postimages.

For the two authored host-Rust resolver fixtures, the supported prepared entrypoint is:

```sh
python -B tools/runtime/apply_telegram_client_patches.py --rust-tests \
  --report build/mtproto-resolver-tests/result.json
```

It uses locked Cargo dependencies, a 300-second compilation budget, then runs the
single produced test executable with a 30-second process-group deadline and requires
both `app_resolver_*` cases. It rechecks source identity before and after execution.
Host Rust tests do not prove the iOS-only FFI linkage. Native compilation/execution
and full-app CI remain coordinator-run; the local clean-base proof runs no compiler.
