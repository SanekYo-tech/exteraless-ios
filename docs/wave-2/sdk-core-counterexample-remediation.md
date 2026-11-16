# SDK core counterexamples — F01/F03/F04/F05 remediation

**Ready for coordinator join.** The four owned fixes are implemented and pass
configured-SDK checks on CPython 3.12.10 and 3.14.8. F03's production install is the
separate `sdk-core-reflection-install.patch` below. F02 send-hook priority remains
the TL/direct-hook owner's cohort.

## Changes

### F01 — preserve omitted edit fields through AccountClient

`_tl.install` now overrides `AccountClient.edit_message` with the same argument
names/order and an internal `_OMITTED` default for `with_spoiler`. It forwards all
edit arguments to the existing native-edit adapter using `self.account`.

- Omitted spoiler stays absent; explicit False and True remain explicit.
- Text/parse_mode, empty caption, file_path and native target fields retain their
  existing validation and projection.
- An unpinned client follows hook scope; explicit account pins remain authoritative.
- The original `python/sdk/client_utils.py` declaration is byte-identical.

### F03 — actual backend existence for unregistered native classes

New `python/exteraless_runtime/_reflection.py` installs an iOS-only wrapper around
the original `hook_utils.find_class`.

1. Preserve original permission/alias/substitute adaptation.
2. Unwrap SDK field-shaped aliases for classification without probing native fields.
3. Return registered/local Python ports, lazy schema classes and array types through
   their valid fast path.
4. For an unregistered native JavaClass proxy, require a successful permission guard
   and **actual installed backend.class_exists(fqcn) is True**.
5. Missing, denied, malformed or unavailable metadata returns None. A failed owner/
   permission query cannot be treated as class existence. BaseException is not caught.

Installation is idempotent for the same Platform. The C backend's existing metadata
semantics remain intact; this lookup does not certify every member/provider of a
declared class. The Foundation Class/ArrayList and registered Config/TL/alias paths
are valid controls in the tests.

**Coordinator-only production hunk:**
`docs/wave-2/sdk-core-reflection-install.patch` adds the helper installation at the
end of `Platform.install`, after native metadata registration. It does not alter
the shared hook-registration or archive/dev installation bodies. Read-only
`git apply --check --whitespace=error` passed. Tests execute this exact helper join
in memory after real configure; the shared `_platform.py` was not edited here.

### F04 — contain user callback exceptions after decoding

`Requests.completed` decodes response/error before calling the installed
`android_utils.safe_call` on the selected user callable/delegate. `RequestCallback.run`
also uses that actual helper within its account scope and ignores the result.

- User Exception is logged and contained; arbitrary return objects remain void and
  are never exported as extra C handles.
- Schema errors, native admission/cancellation failures and stale/closed lease guards
  remain outside the user guard.
- KeyboardInterrupt/BaseException control still propagates.
- Terminal close and native-owned FIFO release remain separate, including when user
  code throws. Duplicate wrapping of RequestCallback does not duplicate error logs.

### F05 — queue-local cancellation and public admission Bool

`Scheduler` retains `(lease, callback, logical_queue)` for each native task id;
`OwnerQueue.cancelRunnable` passes its queue name into cancellation selection.
The same callback on STAGE_QUEUE, GLOBAL_QUEUE and UI is independently cancellable.

- False native cancellation retains the lease until actual completion.
- Malformed/throwing cancellation remains an error and retains the lease.
- Positive native Bool closes only the selected lease, retaining FIFO release ownership.
- `OwnerQueue.postRunnable` returns typed **True** after successful admission. Invalid/
  rejected native admission still raises; `Scheduler.post` continues returning the
  actual internal native id.

The existing cancellation identity-race test now obtains retained internal ids after
checking the public Bool. The native HNS Python fixture also used the public return
as an id; it now observes the newly retained scheduler id and still returns that
real string token to its native cleanup checks. Its bounded unit check asserts that
the reported token identifies the actual postToOwner entry. No native fixture
registration or expectation was replaced with a fake id.

## Bounded verification

| Suite | Python 3.12.10 | Python 3.14.8 |
|---|---:|---:|
| Four cases × unit host / existing real C BridgeBackend | **8 passed**, 4.22 s | **8 passed**, 4.80 s |
| Targeted TL, queue publication/cancellation and HNS fixture regressions | **9 passed**, 5.33 s | **9 passed**, 6.00 s |

**17 passed per Python version; zero skips/failures in these selected runs.**
Seventeen unrelated wave-2 cases were deselected from the regression command.
Each suite/child was bounded to at most 30 seconds; existing regression workers use
20-second children. The new worker is below 32 KiB and uses one own source plugin.

Main command, with `EXTERALESS_TL_C_BRIDGE` set to the matching existing C extension:

```text
python -X utf8 -B -m pytest tools/compat/tests/test_sdk_core_counterexamples.py -q
```

Regression selection:

```text
python -X utf8 -B -m pytest tools/compat/tests/test_sdk_tl_remediation.py tools/compat/tests/test_sdk_adapter_wave2.py tools/compat/tests/test_native_sdk_hns_fixture.py -k "test_tl_remediation or test_native_hns_python_fixture or queues or queue_publication or cancellation_winners" -q
```

The C extensions already existed and their binary/source/header pins were checked
against the current C bridge; no bridge rebuild was needed. Their source SHA-256 is
`f9a94d4ed8cbaa7fae9e23f7b232313fa838a89c5407b60a603cebcea277f92a`.
They retain the real C backend, immutable C epochs, handle table and transport;
legacy mock-service tables remain empty and final handle counts are zero.

**Execution boundary:** the configured SDK and own plugin run for real. Native
services and edit-validation responses are recorders; the C tests use a desktop
ctypes host callback. Its nested audit permission probes are distinguished from
the outer deliberately failing permission request. No Swift Host/provider, UIKit,
live RPC, device or new Mac execution is claimed. The current Mac20/e16 green base
remains evidence for that earlier snapshot.

### JUnit receipts

Root: `C:/Users/sasha/AppData/Local/Temp/opencode/`

| File | SHA-256 |
|---|---|
| sdk-core-remediation-py312-r2.xml | `7d12b29d32d8b1ac2db8c16c73d7c00dcbd4e79b652453ec4fa2b5d267409d52` |
| sdk-core-remediation-py314-r2.xml | `9a3b1239dfaa145b8f8f436001eba3d2e0fa79cf0792aacbe4958917595af7d0` |
| sdk-core-remediation-regressions-py312.xml | `bddfe17baafa65ec7d3fa57415fea4fe87996e04324e2effbe57a4e8c17a8a67` |
| sdk-core-remediation-regressions-py314.xml | `74552d0573bd805dfa5dc3cb7ffb00963de05b5f15192e47a052d76d6aa53285` |

## Ready file hashes

| Repository path | SHA-256 |
|---|---|
| python/exteraless_runtime/_tl.py | `00b016b315a43fcd7015ee4d37debf69fcc1c347b6e380ade92d06775eb03d9f` |
| python/exteraless_runtime/_scheduling.py | `53428ff5b9a207405377d86939e582748d45e4e3a016d75f0d34552bcd92a293` |
| python/exteraless_runtime/_reflection.py | `8f5a3e9cdd064f2d593852005b36dfff387ac6915848e430554357c7aac7ed6f` |
| python/runtime/smoke/plugins/native_hns_probe.plugin | `a025555c274fa08f2b52b51f9163b33a8b50f713eea0bd103651f30e9fe32a2e` |
| tools/compat/tests/test_sdk_core_counterexamples.py | `0e963f96e19b71b813ab9ad5e2a6bead1935e2aee906cf0319affd2d34b524d7` |
| tools/compat/tests/test_sdk_adapter_wave2.py | `ae17526bda3495dcf127a125a897439ba73fe5bfd5c0ddd8bae7d4d426e4ccef` |
| tools/compat/tests/test_native_sdk_hns_fixture.py | `e8d292ee54f633aa59f3f30aa0a8da6555b1d28db57d0910fec7191b94d74048` |
| docs/wave-2/sdk-core-reflection-install.patch | `7d802a960aa42d006dc9a12e55d2df7693244969f8dd40fb563d4837fb7f36e8` |

All five owned original SDK module copies remain byte-identical to their Android
sources. These changes are uncommitted. Source/SDK receipt regeneration and the
combined inventory update remain the coordinator's join step.

## Next native checks for this new snapshot

After the install hunk and coordinator pin regeneration, verify the same cases through
the real Mac Host/provider path: omitted/explicit edit spoiler, existing/missing class
metadata, contained user callback Exception versus strict schema/cancellation failure,
and queue-local cancellation with the HNS fixture's retained string task id. Retain
all three SDK child and C/FIFO cleanup checks; the new code has no Mac PASS receipt yet.

Coordinator applied the two-line `_reflection.install(self)` seam after native
metadata registration. The direct-hook and developer installation sections remain
in the same working-tree composition; publication awaits the coherent SDK cohort.
