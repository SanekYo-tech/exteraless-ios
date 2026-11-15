# iOS data adapters — scoped compiler corrections

2026-11-15. **Applied to the four assigned adapters.** These are source/header
corrections for the TelegramCore diagnostics from full iOS build
`43740868881` / `fac6cf26`; current native compilation remains the coordinator's gate.

Input log:
`C:\Users\sasha\AppData\Local\Temp\opencode\ipa-fac6cf26-failed.log`.
The six source sites produced seven diagnostics (Cloud's ID initializer produced two).
Working-tree HEAD when the four-file baseline was captured:
`16c23a99449eba704885a83982e35a079054f815`.

## Actual declarations and applied mappings

Adapter paths in this table are relative to
`telegram-ios/submodules/TelegramCore/Sources/`.

| Adapter / original diagnostic line | Actual API inspected | Applied correction |
| --- | --- | --- |
| `ExteralessCloud/ExteralessCloudTransport.swift:26` | `MtProtoKit/PublicHeaders/MtProtoKit/MTGzip.h:15` takes `NSUInteger` (`UInt` in Swift); `MTGzip.m:60–68` enforces the explicit output ceiling | `UInt(exactly: limit)` feeds `maxOutputLength`. An unrepresentable limit follows the existing malformed-remote error; no truncation/clamping or unbounded overload. |
| Same file, `:68` | `Postbox/Sources/Peer.swift:54–100`: the numeric ID initializer is fileprivate; the public factory is `PeerId.Id._internalFromInt64Value(_:)` | Pass `CloudProtocol.botId` directly through that factory, retaining `.CloudUser` and the exact resolved-ID comparison. The compiler's `from:` suggestion refers to synthesized `Decodable`, not numeric ID construction. |
| `ExteralessPills/ExteralessPillCoreData.swift:19` | `Postbox/Sources/Postbox.swift:486`: `public func getPeerPresence(peerId: PeerId) -> PeerPresence?` | Add the `peerId:` label to the existing account peer argument. |
| `ExteralessStickers/ExteralessEmojiPackSource.swift:67` | `TelegramEngine/Resources/TelegramEngineResources.swift:493–509` returns `Signal<EngineMediaResource.ResourceData, NoError>`; the result class declares `isComplete: Bool` at `:149–162` | Filter on `$0.isComplete`. Native `.complete(...)` at `:502` is a request-option enum case, not a result member. Fetch cancellation, timeout, file inspection and exact declared-size admission retain their existing code. |
| `TelegramEngine/Messages/ExteralessFeedMessageProjection.swift:30` | `SyncCore/SyncCore_RestrictedContentMessageAttribute.swift:4–18` exposes `rules`. `platformText` is a public extension in downstream `PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift:19–33`, whose module imports TelegramCore | Apply that same iOS rule predicate in the Feed adapter: local-override handling, sensitive exclusion, all/iOS/additional-platform matching and ignored reasons. Preserve the current peer check and first restricted-content attribute. |
| Same file, `:126` | `Postbox/Sources/Message.swift:800–802` has the internal updater; `:719–744` already exposes the full public value initializer. `TelegramEngine/Messages/Message.swift:118–180` exposes the full engine constructor, with wrapped media/peer dictionaries | Use the existing public raw `Message.init` directly. All 24 initializer fields are mapped in declaration order; only `associatedMessages` is replaced by the bounded immutable snapshots. |

The public `Message` initializer preserves stable ID/version, composite ID, unique ID,
grouping/group info, thread, timestamp, all flags/tags, forward/author, text, the already
snapshotted attributes, original media/peers, associated ID list/media/thread info/stories.
The recursive depth and Feed retention/dependency limits remain unchanged. No new wrapper,
cache namespace or public access marker was needed.

## Finite source checks

- Exact native declarations above inspected; four-adapter UTF-8/NUL and call/header checks.
- All **24** public `Message.init` labels checked against the actual declaration, with
  23 unchanged `result.<field>` mappings and the associated-message substitution.
- Six existing Feed bounds checked; the complete source tail beginning at
  `exteralessFeedMessageRenderEqual` matches the captured baseline.
- Scoped `git diff --check` passed.
- The exact four-file patch passed
  `git -c core.autocrlf=false apply --reverse --check --whitespace=error` against the
  resulting working tree. Reverse checking did not apply or revert files.

These were bounded local source/header checks, **not Swift/native typecheck or test
execution**. Swift/swiftc are unavailable on this Windows host. No CI, commit, network,
account or Photos operation ran. Account/Network/TLEnqueue fixes remain with their
coordinator-assigned owners.

## Exact source SHA-256

Hashes cover raw working-tree bytes (newline-sensitive). Prefix for the paths below:
`telegram-ios/submodules/TelegramCore/Sources/`.

| Source | Before | After |
| --- | --- | --- |
| `ExteralessCloud/ExteralessCloudTransport.swift` | `b5d0edfe0ba8010dec8f9bf00ea0a930e82f8b390818361a65a56080a041c8f3` | `a770f7f9b307a38aa1675f2b0b722ef9a25c24f3e9b9dc6c5dea1e6bee188794` |
| `ExteralessPills/ExteralessPillCoreData.swift` | `bdbb1013448b7ba6ad0e9bb5d429d32df8ac31dc30827d6d8764d702ff04e447` | `45f83df1be109b43fa203ed65832cb1a6b798878f3f2ec296d610eff49e9648e` |
| `ExteralessStickers/ExteralessEmojiPackSource.swift` | `12ed7f92248a54492c150aaee1f1db4d451375ad384894fc0ff8ff9bf51aac11` | `9e3f3772d96e6a1a9c74a5c081990613bf4fbd289e4f95e7b691ee25da5fe5bf` |
| `TelegramEngine/Messages/ExteralessFeedMessageProjection.swift` | `eba26e7673dd5e11093d440288a789c6c64213cd2e3ae4c509146b21096937f4` | `f82fa3c8c518254ded62126dd48bad20b0cbf9f551dd2b9c7678dc26abefa796` |

This authorized adapter delta supersedes the Feed projection entry in the previous
Native36 source freeze. The coordinator can reconcile that entry using the exact
before/after hashes above; the Core Feed sources/tests have no edits in this task.

## Exact delta SHA-256

Delta baseline: the four captured working files at task entry. Format: Git unified
binary-capable diff, UTF-8 without BOM, repository-relative `a/` and `b/` headers.

- Bytes: **7188**.
- SHA-256: `9ca17b508ca8e12ed100e5575d9db52a2465eb36cd05606d7638fd9451bdace4`.
- Artifact:
  `C:\Users\sasha\AppData\Local\Temp\opencode\ios-data-adapter-typecheck-c3921f14bd9f4793a8c6e87faafcad85\ios-data-adapter-typecheck.patch`.
- Matching raw snapshots are under that directory's `before/` and `after/` subtrees.

Generation used `git -c core.autocrlf=false diff --no-index --binary --no-ext-diff
--no-textconv --src-prefix=a/ --dst-prefix=b/ before after`; the snapshot-directory
components in the headers were removed to make the final patch repository-relative.
Only the four assigned Swift paths occur in the delta. This handoff records the
applied source snapshot for the next coordinator native build.
