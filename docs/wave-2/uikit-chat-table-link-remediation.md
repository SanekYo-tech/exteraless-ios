# UIKit chat-table link remediation

**2026-11-16: one-line source fix, reproduced and verified in an Apple SDK
cross-primary-file compiler probe. The corrected full Telegram + Harness build
remains coordinator-run.**

## Actual failure and source identity

- Full UIKit run **43801470131**, revision `039fc5da`, built the main TelegramUI
  archive, then failed linking `//Telegram:TelegramUIFramework` for the arm64
  simulator. `build/artifacts/client-ui-43801470131/build/build.log:6138–6155`
  names one undefined symbol: `ExteralessChatTableController.writeSettings`,
  referenced by **full type metadata for ExteralessAyuImportController**.
- That log is 635609 bytes, SHA-256
  `29aaa8e473d055f3718d058f9927cd693fca8fd9411781403aae1e2bb07d22c2`.
- Both class files at local base `209d1115c950db541bb651f042495ce1c34635af`
  match `039fc5da` and successful release-IPA40 revision `6de4ac36` byte-for-byte
  after LF normalization. The failed run's `harness-inputs.json` also records the
  baseline ChatTable hash below. Release uses WMO (`Make.py:96–106`); its success
  does not verify the debug separate-primary-file path.
- Repository-wide Swift searches found **one relevant declaration, eight call
  sites, no overrides and no competing overload**. The calls are LyricsSelection,
  PillSettings, FeedActions, PlayerController, FeedChannels, DeleteDefaults, and
  two LinkRules calls. Ayu neither calls nor overrides the helper.

## Cause: inconsistent inferred preconcurrency mangling

The baseline source has no explicit isolation on `writeSettings`, but its
UIKit-derived context makes the primary-file SIL declaration
`@MainActor @preconcurrency func writeSettings`. In that compilation the mangler
strips `@Sendable` from the function's ABI name. While compiling Ayu as a separate
primary file, its inherited vtable entry uses the unstripped name instead.

Freshly compiled objects show the mismatch directly (`T` defined, `U` undefined):

```text
ChatTable T _$s10TelegramUI29ExteralessChatTableControllerC13writeSettings_10completionyyyKc_yyctF
Ayu       U _$s10TelegramUI29ExteralessChatTableControllerC13writeSettings_10completionyyyYbKc_yyctF
```

The `Yb` difference is `@Sendable`. This is a present implementation with a
different mangled name, not an absent writer or an unresolved SDK implementation.
The probe reproduces the actual build's exact demangled undefined symbol and
metadata reference. Its baseline SIL pins both sides:

- `baseline-ExteralessChatTableController.sil:65,5941`: inferred annotations and
  the stripped base vtable entry;
- `baseline-ExteralessAyuImportController.sil:4102`: the unstripped `[inherited]`
  entry, despite no method call in Ayu.

Upstream [Swift issue #84908](https://github.com/swiftlang/swift/issues/84908)
reports precisely the UIKit/Sendable-closure/cross-file-subclass shape, including
the nearby UIUtilities/SwiftUICore warnings. [Swift PR #92769](https://github.com/swiftlang/swift/pull/92769)
describes the underlying lazy-inference hazard: inferred `PreconcurrencyAttr` is
only recorded when actor isolation is requested, while mangling previously
consulted that attribute without forcing inference. These references support the
locally reproduced mechanism; they do not imply the installed compiler contains
that upstream fix.

## Applied correction

`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatTableController.swift:109`:

```diff
-    func writeSettings(_ operation: @escaping @Sendable () throws -> Void, completion: @escaping () -> Void) {
+    @MainActor func writeSettings(_ operation: @escaping @Sendable () throws -> Void, completion: @escaping () -> Void) {
```

Explicit method isolation makes producer and inherited consumer agree on the
`...yyyYbKc_yyctF` name. It expresses the existing main-actor contract directly;
the operation remains a nonisolated `@Sendable` throwing closure. Both method and
inherited vtable remain present. All eight existing callers are in the inherited
main-actor controller context, including the Feed extension and Pill wrapper.

The entire body is byte-identical: the serial utility writer still performs the
durable operation off-main, error/success handling returns through
`DispatchQueue.main.async`, admission remains account-valid and single-in-flight,
and completion still follows weak-owner resolution, in-flight reset and the
second account-validity guard. Table-selection admission, recursive child
invalidation, and callers' captured account keys, snapshots and Pill lease checks
retain their original ordering. Ayu's source is byte-identical to the baseline.

## Executed bounded probe

- [Run **43804717243**](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43804717243),
  success; private branch `ci/uikit-chat-table-symbols-209d1115`, commit
  `24a2640870ffac79e1a741942ecded4c727c97af`; job 133092724696 lasted 25 seconds.
- Xcode **27.1 / 27A9275**, Apple Swift **6.4 / swiftlang-6.4.0.34.1**,
  iPhoneSimulator27.1 SDK, `arm64-apple-ios15.0-simulator`, Swift language mode 5,
  `-Onone -DDEBUG`. Compiler/link commands consumed **11.324 seconds total** under
  the 120-second limit; inspection commands had 10-second limits.
- Two complete, hash-checked production class files retained their imports,
  bodies and inheritance. Six explicitly labelled compile-only dependency stubs
  supplied Telegram types; UIKit, Foundation and UniformTypeIdentifiers were real.
  Separate primary-file object compilations were followed by an additional
  cross-file caller compilation, `nm`, demangling and linking.
- Each variant changed only the declaration prefix. Recorded results:

| Declaration | Base definition | Ayu inherited reference | Link exit |
|---|---|---|---:|
| Baseline | stripped, no `Yb` | includes `Yb` | 1 |
| **Explicit `@MainActor` (applied)** | includes `Yb` | includes `Yb` | **0** |
| `final` control | stripped | no writer vtable entry | 0 |
| Explicit `@preconcurrency` control | stripped | stripped | 0 |

The `final` control also emitted a real direct caller reference resolving to the
writer. The chosen fix instead corrects the declaration's isolation/mangling
without changing its override contract or adding preconcurrency to the API.
Both exact production-class compiler logs for the applied variant are empty.
All four probe link commands emitted a common `-Wincompatible-sysroot` warning
(`macOS 27.0` versus the simulator target); the recorded object/SIL evidence comes
from the explicit iOS-target/iOS-SDK frontend commands. This probe's linked stub
library is not a full-module, app-packaging or UIKit-execution result.

The initial private revision `a7825925` had a workflow-context validation failure
([43804561106](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43804561106),
0 seconds, no jobs). Moving the runner-temp expression into step context produced
the successful run with identical compiler-probe source. Both revisions used a
private Git index; main HEAD and index hashes were unchanged by publication.
The diagnostic used a fresh RUNNER_TEMP directory/module cache, shared the
coordinator's non-cancelling queue, and never accessed its canonical app source
or cache trees.

## Cache, evidence and remaining gate

The failure reproduces without Bazel or any old object/action cache. Both Swift
files are ordinary inputs of `TelegramUI/BUILD:178–183`'s source glob.
`rules_swift/swift/internal/compiling.bzl:816,840–849` passes those sources to the
compile action, and `swift/toolchains/config/compile_config.bzl:2306–2327` declares
them as action inputs. The one-line source edit therefore changes the normal
compile input digest, including the dependent vtable output; cache deletion or
an unrelated linker dependency is not a remediation for this reproduced defect.

Evidence is retained at `build/artifacts/uikit-chat-table-symbols-43804717243/`:
`result.json` includes commands, source hashes, raw/demangled symbols and all
variant exits. Its SHA-256 is
`7065037b6eec4a3749f9afeaf70699b658d4c580a463ae9b63ea6510c20395e7`.
Artifact `chat-table-symbols-43804717243`, ID **14197009292**, is 276564 bytes;
`download-receipt.json` records the advertised ZIP digest and independently hashed
extracted files. The original full-build archive was not captured: its evidence
is the full-build link log, not an original-archive `nm` claim.

Scoped whitespace and exact one-line/postimage checks passed. The final source
hash equals the Apple probe's applied-variant hash. No application, XCTest or
durability runtime test ran in this slice. The next acceptance gate is the
coordinator's existing `tools/runtime/client_ui_harness_build.py`, building
**both `//Telegram:Telegram` and `//Telegram:ClientUIHarness`** in the same supported
debug simulator graph, then its required execution/frame gates. No full-app CI
was dispatched here; no main commit or main push was made.

## Frozen LF-normalized SHA-256

```text
738d48806e2bce59603c6c4384d5ddd98105166cf747f650668d861e519596d4  baseline Chats/ExteralessChatTableController.swift
f1d81f067f0c3ce2b7ef0b46fbb7018f04fb7fe11740d22047d09240cc19dce1  fixed    Chats/ExteralessChatTableController.swift
36f2f1b9489ed572a2af5bfc032800dad796425e38c6b11deeb44d374f79e82d  retained Retention/ExteralessAyuImportController.swift
```

All three paths are relative to
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/`.
