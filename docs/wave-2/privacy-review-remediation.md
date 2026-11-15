# Privacy review remediation — PR02 / PR04

Source remediation and exact integration handoff for PR02 and PR04 in
`reviews/privacy-retention.md`, checked on 2026-11-15. The regression fixtures use
controlled signals/queues and synthetic account identities with a transport recorder.

## PR02 — automatic reads and manual grants

**Source correction supplied; shared final-admission patch and native execution
remain acceptance gates.**

`exteralessReadMessageContents` now uses the production typed
`exteralessAutomaticReadMessageContents` adapter. It records an **automatic**
account/peer annotation and reevaluates `PrivacyPolicy` at final admission, also
respecting validated final metadata when present. It never acquires a manual grant.
`markReadAfterSend` has a separate revocable `.afterSend` intent; disabling that
permission while the prefix is suspended cannot turn it into a manual read.

The manual UI entry still issues `.manual` through `exteralessOwnedReadRequest`.
Its lease binds the exact Account owner, Network object, descriptor object and
immutable original body. Owner validity is checked against the registered current
Account. Only one subscription can begin and only one final admission can consume
the lease. Cancellation/completion retires it; a denial tombstone remains while
the descriptor is alive. A changed descriptor/body, replaced owner or another
Network cannot use that grant. Automatic annotations do not bypass the current
read setting or peer-exception removal.

The older network-only `exteralessExplicitReadRequest` used by offline presence
is a passthrough with **no grant**. Offline status remains subject to the normal
presence policy. Owned read grants accept read-method names only.

### Exact final-admission API / App-owner patch

```swift
func exteralessPrivacyRequestError(
    network: Network,
    description: FunctionDescription,
    body: Data
) -> MTRpcError?
```

This is a **final, consuming admission check**, not a speculative prefix/preflight
query. Call it once directly before transport admission, with the immutable bytes
that will be submitted. Apply `shared-PR02.patch` from repository root:

```text
git apply --check docs/wave-2/shared-PR02.patch
git apply docs/wave-2/shared-PR02.patch
```

The transport changes are two small raw-Network callsite hunks (snapshot payload
before the guard) and the one-line TLNetworkRequest final-guard change. The App
owner must merge that line with Cloud C5 at the final `gate.submit` boundary.
Final descriptor validation and the TL owner's fresh descriptor for changed bytes
remain prerequisites. `EXTERALESS_PRIVACY_SUPPRESSED` is a terminal error; native
callers' existing nil/false catches and local finalizers handle it without a
fabricated affectedMessages/PTS response.

The companion BUILD hunk adds the two new test files and their explicit
ExteralessCore/MtProtoKit dependencies to
`//submodules/TelegramCore:ExteralessPrivacyTests`. The general TelegramCoreTests
glob already sees both files, but the dedicated privacy target uses a fixed list.
Shared Network/BUILD files still require the owner to apply this patch together
with the new API: their old two-argument guard calls do not compile against it.

### Native regression fixtures

`TelegramCore/Tests/ExteralessPrivacyAdmissionTests.swift` drives the actual typed
automatic adapter, common owned-read subscription and admission ledger. Generic
identity parameters instantiate Account/Network/FunctionDescription in production
and synthetic account/network identities with real generated request descriptors
in the test. A held ValuePipe prefix and transport recorder execute no plugin or
RPC, and produce no fake PTS response.

- unchanged bytes after global receipt revocation: zero submissions, one error;
- unchanged bytes after peer-exception removal: zero submissions, one error;
- final validated-metadata denial cannot be overridden by the automatic hint;
- allowed automatic control and cancelled-prefix control;
- real manual-lease control after policy revocation, single consumption and
  rejected repeated subscription/admission;
- replaced owner, different Network, changed bytes and fresh descriptor rejection;
- cancelling a manual prefix retires its grant even for a direct admission retry;
- read-after-send permission revoked during the held prefix.

## PR04 — real history-subscription lifetime

**Source correction supplied; native execution remains pending.**

The actual `AccountViewTracker.wrappedMessageHistorySignal` withState now owns one
`ExteralessHistoryObservationLifetime` per history subscription. On receiving a
batch it calls the following synchronously, **before** `strongSelf.queue.async`:

```swift
func exteralessCaptureLoadedMessagesObservation(
    lifetime: ExteralessHistoryObservationLifetime,
    account: Account, peerId: PeerId, messages: [Message]
) -> ExteralessHistoryObservationLifetime.Batch?
```

The batch captures the existing per-Postbox epoch work at that moment. The queued
block can only call `batch.start()`, never recapture a fresh epoch. It will not
start stale or cancelled work. On history disposal, the lifetime is disposed
synchronously before the existing tracker-queue cleanup. Both pending work and
already installed child signals are cancelled. Signal factories, signal start,
child disposal and completion callbacks run outside the lifetime lock.

`exteralessPrivacyObservationTransaction` has one defaulted internal parameter:

```swift
capturedWork: PrivacyObservationWork? = nil
```

History passes the exact captured work through to the real Postbox transaction;
its cancellation/epoch and authorized identity checks still run before row
mutation. Existing callers retain independent work per subscription. Retention's
`exteralessPrivacyImportWork`, `exteralessPrivacyImportSnapshot` and
`exteralessPrivacyPrepareImportCommit` bodies are preserved.

The existing webpage, poll and history-validation next/dispose hooks in the
tracker retain their arguments and queue order. No other AccountViewTracker
region is changed. Neither capture nor disposal needs a MainActor.

`TelegramCore/Tests/ExteralessPrivacyHistoryLifetimeTests.swift` exercises the real
lifetime helper with withState and controlled tracker/database queues. The fake
database body deliberately remains queued after disposal, matching Postbox's
behavior, and applies real `PrivacyObservations` only through its captured work:

- receive batch → clear → drain: no start/write; a later new batch still works;
- receive → dispose before tracker hop: no write; another account continues;
- start signal → dispose before database drain: child disposable called and no write;
- clear after signal start without disposing history invalidates the queued store
  body, while a later new batch can still write;
- two subscriptions on the same account remain independent;
- the same flow executes on a non-main queue, with a 1-second test wait bound;
- an explicit MainActor case clears/disposes before the tracker hop while another
  account's subscription continues;
- synchronous completion before handle installation disposes the child exactly once.

## Validation

| Check | Observed result |
|---|---|
| `python -B docs/wave-2/tests/privacy_source_fixtures.py` | **10/10 static tests passed**; includes actual tracker capture-before-hop/disposal hooks and the automatic adapter intent. |
| `git apply --check docs/wave-2/shared-PR02.patch` | **Exit 0**, including the final BUILD hunk; patch is supplied for owner application. |
| In-memory application of every handoff hunk | **PASS:** three guards receive the final payload, changed bytes retain the fresh-descriptor boundary, and the dedicated privacy target selects both new suites exactly once with their direct dependencies. |
| `python -B build-system/Make/PostboxImportCheck.py .` from `telegram-ios` | **Exit 0.** |
| Scoped `git -c core.autocrlf=false diff --check` and direct whitespace/duplicate-method checks of the new test files | **PASS.** |
| Retention import tail and read-only review snapshot comparison | **PASS.** All three retention import API bodies equal the pre-edit snapshot; the independent review hash is unchanged. |
| `Get-Command swift,swiftc -ErrorAction SilentlyContinue` | **Unavailable, exit 1.** Swift/native tests have not executed on this Windows host. |

**17 new native regressions prepared:** 9 in
`ExteralessPrivacyAdmissionTests`, 8 in
`ExteralessPrivacyHistoryLifetimeTests`. The dedicated target is
`//submodules/TelegramCore:ExteralessPrivacyTests`, using the existing
`//Tests/Exteraless:Runner` / `NativeTestHost`. Execute the two classes after shared
patch integration and native compilation, with an external fixture deadline
**at most 30 seconds**. The only asynchronous test wait is bounded to 1 second;
all held prefixes and controlled queues are explicitly released within each test.

The MainActor and non-main queue cases both drive the same production history
lifetime helper. The actual Postbox adapter is source-checked here; its native
compilation and execution are still acceptance gates. Static checks and the
in-memory projected BUILD are not receipts for an applied patch or a native pass.

Snapshot anchors (SHA-256):

- Retention import tail, normalized UTF-8/LF:
  `28adf5115d2026252e54293abfed6f9fb9dbac9a16d78288fc390fe48eb5a0b6`.
- Independent review, file bytes:
  `c5691d57b669994abbbba01a6de55064d5c13d0dc3b43ae1e0338af269eb02af`.
