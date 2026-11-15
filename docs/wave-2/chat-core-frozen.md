# Core Chat — FROZEN

Frozen source handoff, 2026-11-15: **16 sources + 6 XCTest files (51 methods)**.
Take this cohort together, including tracked modifications and untracked files.
`ChatPolicy.swift` contains the public `ChatDoubleTapAction` required by
`CloudLegacyRules.swift:158` and `CloudLegacyImportTests`; the reported
`43699189463 / ddc25d69` failure used a committed slice without that definition.
This handoff does not claim that a newer build or XCTest run passed.

## Cohort

All paths below are under `swift/ExteralessCore/`.

### Sources/ExteralessCore/

```text
ChatAdGuardRules.swift
ChatBookmarkStore.swift
ChatComposerPolicy.swift
ChatContextPresentationScope.swift
ChatCurrencyQuery.swift
ChatDeleteMenuDefaults.swift
ChatFeatures.swift
ChatFeedPolicy.swift
ChatLegacyPreferenceMigration.swift
ChatMathExpression.swift
ChatMediaPolicy.swift
ChatMenuPolicy.swift
ChatMessageLayoutPolicy.swift
ChatPanguPolicy.swift
ChatPolicy.swift
ChatTrackingRulesStore.swift
```

### Tests/ExteralessCoreTests/

```text
ChatContextPresentationScopeTests.swift
ChatDeleteMenuDefaultsTests.swift
ChatLinkRulesTests.swift
ChatMediaPolicyTests.swift
ChatPhase2PolicyTests.swift
ChatPolicyTests.swift
```

## Required composition

- Keep the existing ClientSettings `applyPublic(expected:)`, `readSnapshot` and
  `migrateKey` APIs in the same Core snapshot. Chat defines no replacement store.
- The AI follow-up is now present: `AITranslationPolicy.showTextTranslate` reads
  `ChatFormattingPolicy`, and `AIFeatures` has removed its independent
  `ai.showTextTranslate` definition. Include both AI files in the same committed
  slice. The two-consumer Chat test deliberately requires that real connection.
- `ChatFeatures` includes every previous Feed/Playback/Pill declaration, plus its
  Chat menu/composer/media dependencies above. Domain feature arrays supplement it.
- `ChatLegacyPreferenceMigration` is a pure source-defined archive projection. Its
  importer handoff is separate from the missing-enum build fix; Cloud source was
  not changed to avoid its dependency on `ChatDoubleTapAction`.

## Checks actually performed

- Core Chat `git diff --check`: passed.
- UTF-8, NUL, trailing whitespace and balanced source delimiters: all 22 files passed.
- Swift/Swiftc are absent in this Windows session. **No Swift/XCTest execution.**

Bounded coordinator checks after composing the Core snapshot:

```sh
swift test --package-path swift/ExteralessCore --jobs 1 --filter Chat
swift test --package-path swift/ExteralessCore --jobs 1 --filter CloudLegacyImportTests
```

Native Chat integration, frame evidence and parity records remain documented in
`chat.md`; this freeze covers the Foundation-only source/test cohort above.
