# iOS bubble compiler follow-up — 47858c64

2026-11-15. **One production file, four narrow hunks; source checks passed. Native
Swift/UIKit compilation is pending the coordinator's next full build.**

## Input / scope

- Failed full-iOS run: **43756409676**, commit
  `47858c640a4d931dc9d5396e8ba70d06f203802c`.
- Local log: `C:\Users\sasha\AppData\Local\Temp\opencode\ipa-47858c64-failed.log`.
  Its raw SHA-256 is
  `05cf4006758f0f97cfa3d2af71b0f045bb3b577679864e29ab0744a0929bb49c`.
- Working-tree base inspected: `93edf05ec061ff976380465c838f2bfe0fe82caa`.
- Changed production source:
  `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift`.

The log has five compiler diagnostics for this file at 1571, 2027, 2977 and
3008 (two diagnostics). They reduce to an outdated local closure type and a
branch-local comment-button flag referenced by a later policy.

## Fixes

1. **`beginLayout`, line 1615:** add the missing `Int32?` argument between
   `ChatMessageForwardInfoNode.StoryData?` and `CGSize` in `forwardInfoLayout`.
   The actual callee at `ChatMessageForwardInfoNode.swift:285` already takes eleven
   inputs, with `originalTimestamp: Int32?` at position 10. Both bubble callsites
   now match that type and its `(CGSize, (CGFloat) -> ChatMessageForwardInfoNode)`
   return value. This addresses the conversion diagnostic, the forward-expression
   diagnostic and the story call's extra-argument / nil-as-CGSize diagnostics.
2. **Lines 1905 / 1977 / 1984 / 2027:** hoist
   `mayHaveSeparateCommentsButton` beside `needsShareButton` and
   `needsSummarizeButton`. Its existing true assignment remains in the native
   incoming, share-eligible `TelegramMediaFile.isInstantVideo` branch. Both the
   copy-protection gate and the later channel-share policy consume that same value
   together with `hasCommentButton(item:)`. A permitted round-video comment
   affordance therefore survives hiding the channel share button; unavailable
   comments still follow native eligibility.
3. **Forward call, line 2977:** supply `forwardInfo.date` from the bound
   `firstMessage.forwardInfo` used by the author/source/signature resolver and its
   `firstMessage.id` identity. This avoids reading the timestamp from a different
   grouped-message representative through `item.message`.
   The story call at line 3008 still supplies **nil** for `originalTimestamp`.
   The callee's `storyData == nil` check and
   `exteralessIdentityForwardDate`'s `dateOfForwardedMsg && timestamp > 0` policy
   retain optional date omission. No send-time or current-time fallback is added.

## Source-bound checks

- `git diff --check` passed for the changed file.
- A read-only comparison against the pinned base confirmed that the entire file
  differs by exactly the four stated replacements.
- A balanced-argument source check compared the actual callee's eleven input types
  and return type to the local annotation. Both callsites have eleven arguments;
  source, author signature, inline bot, PSA, story and timestamp occupy their
  declared positions.
- Source checks confirmed the bound forward identity/date, story nil, one hoisted
  flag declaration, the existing native true assignment and both real comment gates.
- UTF-8/NUL checks passed. No new mirror-layout tests were added for this type/scope
  correction. Local Swift is unavailable, so these checks are **not a compiler pass**.

## Source pins

SHA-256 of UTF-8 source with CRLF normalized to LF. The changed file's pre-fix hash
was `6e20962f5b4052589220b3bf0d636bbe0fbad46006da93b5b100840f39b53513`.
The remaining entries pin the read-only contracts inspected for this fix.

```text
736ad729c23ebbfbd840c6fb5fbe5ca2a3dc136aab0d1872a9a6957088250bfb  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift
2ad62b4ffbc4645665610191e19e0ab45ef405f0c7fc9e4d713fa00af98e1af0  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageForwardInfoNode/Sources/ChatMessageForwardInfoNode.swift
2248e51da09fef9a8751467513ffd84c67522cd19b36255635ec1220c7080014  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageItemCommon/Sources/ChatMessageForwardInfoDisplay.swift
695b5a18926db4ad2820c4353b8649cad5768737baba24cda578e2fdceebc9bd  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageItem/Sources/ChatMessageItem.swift
c9d296279bc69754bcc10ac879779d7fa962ad15c6186a8e8d3b44ee00711a08  telegram-ios/submodules/TelegramStringFormatting/Sources/ExteralessIdentityDateFormat.swift
```

## Coordinator verification

The source boundary is ready for the next full `//Telegram:Telegram`
`release_arm64` build. That run must confirm elimination of the five diagnostics;
this note does not claim successful IPA production or a green downstream graph.

No native UI, accounts, network, CI dispatch or commits were used here. No frames
were recorded; the existing composer/feed/wall-clipping frame expectations remain
pending. Forward date on/off, story date omission and eligible round-video comments
also require native visual acceptance rather than inference from these source pins.
