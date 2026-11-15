# Chat admission contract — CMC-02 / CMC-13

2026-11-15. **Integration contract for coordinator + TL owner.** The coordinator has
applied TLN-05 and returned the Enqueue block to Chat. Both typed doors and legacy
array adapters now share its single transaction with the provided `tlCommit` passed
through unchanged. Chat is implementing the consumers; the original review is read-only.

## Public result, before Chat cleanup

```swift
public enum EnqueueMessageRejectionReason: Equatable {
    case pluginCancelled
    case botAuthorizationDenied
    case retainedReplyUnavailable
    case cancelledBeforeCommit
    case localEnqueueUnavailable
}
public enum EnqueueMessageAdmission: Equatable {
    case enqueued(MessageId)
    case rejected(EnqueueMessageRejectionReason)
}
public struct EnqueueMessagesResult: Equatable {
    public let slots: [EnqueueMessageAdmission]
    public var messageIds: [MessageId?] { /* same cardinality/order */ }
}

public func enqueueMessagesWithAdmission(
    account: Account, peerId: PeerId, messages: [EnqueueMessage],
    tlCommit: ExteralessTLEnqueueCommit? = nil
) -> Signal<EnqueueMessagesResult, NoError>
```

- **One implementation:** move the existing hook → authorization → media → transaction
  pipeline behind the typed entry. Existing `enqueueMessages` is only
  `enqueueMessagesWithAdmission(...) |> map { $0.messageIds }`.
- The plugin-origin typed door uses the same private implementation with hooks
  bypassed; its old `[MessageId?]` API remains a thin mapping adapter. Retain the TL
  owner's optional `tlCommit` and origin/correlation arguments in both doors.
- Original slots survive CANCEL and partial acceptance. A cancelled hook slot is
  `.pluginCancelled`; subsequent failures fill only its accepted-index slots.
- Bot denial is `.botAuthorizationDenied`. Deleted-reply rewrite failure is
  `.retainedReplyUnavailable` before inserts (retain the existing retention report).
- TL precommit cancellation maps to `.cancelledBeforeCommit`; do not convert a
  committed ID into cancellation after commit. A nil from the transaction's ordinary
  native enqueue becomes `.localEnqueueUnavailable`.
- Emit `.enqueued(id)` only after Postbox commit. Commit-owned correlations, ephemeral
  publication and NativeServices publication retain their existing ordering. These
  IDs mean **local enqueue**, not server delivery.

The optional permit is also accepted by the normal typed door. The UI's
`exteralessEnqueueWithExportPermit` bridges the **same inherited FU-02 permit** into
that existing transaction gate; it does not mint a new permissive export scope.
Provisional disposal cancels; a claimed commit retains native postcommit completion.
Both direct Forward and a handed-off destination draft use this adapter.

## Chat lifetime / draft contract

Each producer captures a draft revision, account/location, operation identity and
its own transition correlations before asynchronous work. Pending history cleanup
must not be authorized by `correlationId == nil` or an unrelated history update.

- Full refusal/CANCEL: cancel only that operation's cleanup/transitions; preserve
  captured/current text, media, reply, forward and URL state; surface the reason.
- Full local acceptance + matching revision: clear the captured draft exactly once.
- Partial acceptance: retain every returned slot/ID, retire only rejected transitions,
  preserve the draft and surface partial admission; never treat it as all-nil or clear
  a newer draft. This avoids deleting unsent batch content.
- Revision mismatch: no cleanup of newly typed text or a different edit; committed
  results remain committed. A → B → A is a changed revision, even if values match.

## Pending Edit admission

Chat captures **edit A + media A + preview A + revision** before either source read.
It rechecks its operation immediately before requesting pending-update admission.
The pending-update boundary needs a typed callback/Signal confirming local admission
or rejection; its legacy `add` should share the same implementation. Precommit token
cancellation/source disappearance must reject before installing a pending update.
Chat clears the editor only on `.admitted`/`.unchanged` A with the same revision. A
missing source and late A callbacks never close editor B. `chat-review-integration.patch`
contains `PendingUpdateMessageManager.addWithAdmission(... expectedStableVersion: UInt32?,
token: PendingMessageUpdateAdmissionToken) -> Signal<PendingMessageUpdateAdmission, NoError>`.
The manager rechecks existence/version, then claims the token immediately before its
existing `impl.add`; old `add` is a thin adapter. This edit-only source read is separate
from the single transaction in the new-send pipeline.

The same packet changes only the GIF-specific `ChatControllerInteraction` field to
`Bool?`. Its keyboard producers now pass nil for ordinary taps, true for explicit
silent. Other already-integrated optional sound fields retain their signatures.

## Coordination with Rich Composer

Chat owns CMC-13's `ChatControllerLoadDisplayNode.editMessage` body, including replacing
its `convertMarkdownToAttributes` call with existing `exteralessComposerMarkdown(...,
respectDisableMarkdown: false)` (CMC-07 overlap). Edit/caption/forward comment always
parse using the selected grammar; ordinary send keeps the default disable policy.
Rich Composer owns the other parser/date/selection/paste producers and Date sections.

## Required bounded fixtures

Reduce Motion / nil transition correlation + all-nil admission + unrelated history;
plugin CANCEL; bot denial; retained-quote failure; mixed admitted/rejected slots;
new user input before completion; Edit A held at each read then Edit B; cancellation
before pending-update admission. No live accounts, network, CI or commits.
