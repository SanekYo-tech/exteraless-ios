# Native disk pressure selection — 43822623419 / bfcce7bc

**Implemented:** pressure-aware selection in `tools/runtime/native_test_disk.py`.
The actual failure was the60-second reclamation budget being consumed by old,
small cache entries while useful large blobs remained. Ownership and capacity
checks worked; the required floor is unchanged.

## Actual completed-run evidence

`build/artifacts/client-ui-43822623419/native-tests/disk-capacity.json`

SHA-256: `bc64aeb8add7d14528fd3425fedf58f8c8523c44484d1a6bb0750a76c7708b43`.

| Observation | Bytes / value |
| --- | ---: |
| APFS volume total | 192749240320 |
| Starting free space | 2753368064 |
| Starting eligible cache | 24948412182 |
| Deleted files | 37728 |
| Deleted logical bytes | 6410214142 |
| Deleted allocated bytes | 6532018176 |
| Ending actual free space | 9305899008 |
| Remaining eligible cache | 18538198040 |
| Required floor | 21474836480 (20 GiB) |
| Elapsed | 59.778s |

All measured paths were on device16777226. The receipt reports
`time/file/byte reclamation quota reached` and `failed-before-compile`.
The retained cache was ample to address the floor deficit; LRU-only ordering
spent the budget before reaching enough of it. The logical starting free+cache
sum,27701780246 bytes, is also below the optional30 GiB goal.

## Applied selection policy

New receipts identify **`pressure-largest-allocated-then-lru-v1`** and persist:

- `selectionThresholds.pressureBelowFreeBytes`: existing20 GiB floor;
- `selectionThresholds.targetFreeBytes`: existing30 GiB goal;
- `selectionThresholds.maximumCacheBytes`: existing8 GiB eligible-cache cap;
- `pressureRanking`, `pressureDeletedFiles`, `lruDeletedFiles`, `stopReason`,
  `remainingPotentialBytes` and `targetFreeReached`.

After the same full verified inventory, only single-link AC/CAS entries enter
the selection queues. Below the measured floor, candidates are ordered by:

1. allocated bytes, descending;
2. logical size, descending;
3. mtime, oldest first;
4. relative digest path for deterministic ties.

Thus newer large blobs are reached before thousands of older metadata files.
Equal-allocation/equal-size entries retain LRU order. Once actual free space
reaches the floor, the existing LRU order is used for any remaining cache-cap
or reachable-goal work. A considered/changed candidate is never retried through
the other queue. Queue construction and traversal remain bounded by the existing
inventory limit; there is no per-unlink full re-sort.

The optional target uses an effort estimate from the unprocessed single-link
entries: `max(allocated, logical size)` per entry. **This estimate cannot pass
the readiness gate.** Only after measured free space satisfies the floor and
actual retained-cache accounting satisfies the cap may the helper stop chasing
an optional target that the remaining estimate cannot reach. Such a success
records `targetFreeReached=false` and
`minimum-and-cache-cap-met-target-not-estimated-reachable`.

Every successful unlink still triggers the real `disk_usage` measurements.
If allocation is retained, a large-file unlink does not manufacture free space.
If the floor or cap remains unsatisfied at exhaustion/cutoff, the helper still
fails before compilation.

## Preserved boundaries

The source definitions for `Limits`, workspace/generation checks, fixed-root
cache authorization, marker/inode validation, full cache inventory,
`O_NOFOLLOW`/dirfd parent opening and leaf unlink are byte-equivalent at AST level
to the preceding implementation. The per-deletion claim and identity checks,
hardlink/changed-leaf refusal and filesystem-derived capacity gate remain active.

There is no reduction of the20 GiB floor, no increase of the60s phase or100000-file
deletion limit, and no change to source/output/IPA/simulator retention. Native
runner/workflow code is unchanged; the complete37-target/434-method compile and
twenty-scene gate remain the coordinator's next full run.

## Regression evidence

`tools/runtime/tests/test_native_test_disk.py`: **16 tests passed; one POSIX-only
dirfd test skipped on Windows**, total3.412s.

- Two thousand real old one-byte AC entries, three newer1 MiB blobs and the
  retained source/output/IPA/sibling files: a three-unlink budget reaches the
  scaled floor and cache cap by deleting exactly the three large blobs. Tiny
  entries and unrelated files remain. Simulated free space increases from each
  unlinked file's stat allocation (the helper's portable allocation fallback on
  Windows); measurements after all three successes are asserted. The unattainable
  optional goal is reported false, without consuming more unlink budget.
- A separate transition test verifies normal LRU selection after the floor.
- Equal-size pressure ties preserve oldest-first selection; a changed large blob
  is kept and not retried.
- Adequate-free no-delete, quiescence, stale generation, arbitrary roots,
  symlink/junction refusal, hardlinks, time/file/scan quotas and zero actual space
  returned by unlink continue to pass.

New pre/post hashes and delivery receipts are under
`build/wave-2-dependencies/native-test-disk-pressure-bfcce7bc/`.
The original disk-recovery document, completed-run artifact and historical
receipts remain unchanged. No CI query/launch, network access, commit/push or
actual runner cleanup was performed in this followup. Coordinator can dispatch
the same full gate with the pressure policy in place.
