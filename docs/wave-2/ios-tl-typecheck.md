# iOS TL declaration/capture fixes

Source fix for the five assigned TelegramCore diagnostics in full iOS build
`43740868881` / `fac6` (`ipa-fac6cf26-failed.log`, lines 5932–5976 and 6035–6052).
Inspected working-tree HEAD: `16c23a99449eba704885a83982e35a079054f815`.

## Exact changes

Paths below are relative to `telegram-ios/submodules/TelegramCore/Sources/`.

| File / location | Change |
| --- | --- |
| `ExteralessRuntime/TLMediaEditServices.swift:37–38` | Rename the guard-bound filesystem dictionary to `fileAttributes`; the later `[TelegramMediaFileAttribute]` builder retains `attributes`. |
| `PendingMessages/EnqueueMessage.swift:764–765,819–820` | Use immutable `preparedMessages` for the outgoing-text stage, then immutable `messages` for notification defaults. Both admission entry points retain their existing typed result and `tlCommit` forwarding. |
| `ExteralessRuntime/TLNetworkRequest.swift:141` | Make the already-strong outer async capture explicit: `self.queue.async { [self] in`. Both nested timer/submission closures retain `[weak self]`. |

Seven changed source lines total. The compiler's capture-list diagnostic and
`telegram-ios/CLAUDE.md:640–657` were inspected. The outer async block retains its
original one-shot ownership; inner weak captures, post-async gate/account checks,
timer disposal and cancellation retain their intended lifetimes. Message stages
remain immutable, and original-versus-replacement validation still uses the same
snapshots and byte comparison.

## Local evidence

- Reversing only those seven lines in memory reproduced the captured preimage
  SHA-256 of all three complete files exactly.
- Scoped `git diff --check` passed; diff is 7 additions / 7 removals in three files.
- Existing tests were retained. No new tests, iOS compilation, CI dispatch, commit,
  account or RPC execution was performed for this scope fix.
- The supplied Mac SDK receipt `43738810843` / `136c` remains the existing green
  three-child + C219 result. It is not a new full-iOS graph verification of this patch.
  A subsequent native build is still required for a fresh compilation result.

## Frozen source hashes

Raw-file SHA-256:

| Source | Before | After |
| --- | --- | --- |
| `ExteralessRuntime/TLMediaEditServices.swift` | `32081bed061ef977da64aea4f6b5d25830c2b07fe7f956dc53166b22620ac8be` | `983fc558d13ad1ca6cbef67c3544c18e0785fbf8bcfc21edd855c1b830e37c10` |
| `ExteralessRuntime/TLNetworkRequest.swift` | `468aebbb567a665ce93d54f24e4e816c88519a48f3b1f228ad7e625597c5c9ab` | `032fa13dcd6a0f1cc600ecb3c9cf866a361d8dbfe79a6d38d51fe7e9a3861548` |
| `PendingMessages/EnqueueMessage.swift` | `f67e1f05f49418392d2781201c07b2f0a48e40e3803a38d39fab544df0fc3cfb` | `28bd65470f8bbe0f354330655959413b00626405d8697693392b1c82f233fc11` |

Postimage corpus: `dac49fa63b159510407b5ebdd01519e38b1f0bafe6cc35eb8e773e3c3cb0ee03`.
Formula: SHA-256 of sorted full repo-relative `path + NUL + raw_sha256_hex + LF`
records for these three source files.
