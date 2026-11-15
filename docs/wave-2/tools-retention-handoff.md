# Ayu database import — handoff to the retention owner

Tools does not open/replace account SQLite, dialog history or auth storage. Its
configuration archive accepts only ClientSettings and explicit plugin settings.
The Android Ayu importer is a separate history migration and belongs exclusively
to `ExteralessRetention`.

Original source: `java/app/exteraless/backup/AyuDatabaseImport.java`:

- Filename gate: `database-export.sqlite` (`isAyuGramExport`, lines 40–56).
- A source copy is opened, integrity checked, and must contain DeletedMessage or
  EditedMessage (130–145). The original merges into one target transaction, not
  by replacing its live database.
- DeletedMessage dedupe: `(userId, dialogId, topicId default 0, messageId)`;
  source `fakeId` is not a native message ID (167–195). Map it only for the child
  DeletedMessageReaction foreign key; skip `fakeReactionId` (199–218).
- EditedMessage dedupe: `(userId, dialogId, messageId, entityCreateDate, editDate)`;
  don't reuse source `fakeId` as a native ID (221–247).
- Additional tables: DeletedDialog, SpyMessageRead, SpyMessageContentsRead.
  Read-date source alias is `entityCreateDate` for target `date` (42–50, 249–259).
- LastSeenEntity.lastSeen or legacy SpyLastSeen.lastSeenDate; upsert maximum only,
  never infer newer activity (261–284).

Native boundary already present in the retention owner's source:

- `RetentionMessageKey(peerId: namespace: id:)`: **packed native PeerId**, not
  `abs(Android dialogId)` and not a guessed account slot.
- `RetentionVersion` / `RetentionPolicyRecord`: native versioned payload, real
  capture/version dates, local sequence numbers, bounded media references.
- `ExteralessRetentionSnapshot` plus `ExteralessRetentionStore` inside TelegramCore;
  `TelegramEngine.Messages.retainedMessages/retainedVersions/...` are read/view APIs.

Required conversion contract before a Files importer is advertised: a bounded,
read-only external SQLite parser, explicit Telegram user-ID/account matching,
Android dialog-kind → native peer namespace resolution, native snapshot construction
through trusted typed converters, dedupe inside the retention store transaction,
and imported-attachment mapping that never trusts source absolute paths. The native
snapshot's payload is not an Android TL blob and must not be relabeled as one.
Do not insert imported rows into cloud message history or emit read/send requests.

Tools can hand over a security-scoped selected file after the retention owner
exposes its concrete inspector/import API. Until then the configuration picker
rejects SQLite by schema and this feature remains explicitly pending, not an empty
Import button. This handoff introduces no account DB access in Tools.
