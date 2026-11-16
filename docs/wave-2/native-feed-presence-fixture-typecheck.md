# Native Feed, presence and Chats fixture typecheck

Source corrections for **43812503558 / 93dcb653**. Native compilation and XCTest
execution of these corrections are **pending**.

## Input

- Input commit: `93dcb653d408e45fe1327ee2ee945952520548b4`.
- Compiler log: `build/artifacts/client-ui-43812503558/native-tests/compile/console.log`.
- Log raw SHA-256: `1f2acdd3a353164aa4f540366bb9b754f6aac358baa7c7d7dd5f169a816d2a49`.
- Diagnostics: presence at log lines 1356–1400; Feed at 1743–1840; Chats at
  2147–2161. The five input test files matched the input commit before editing.

## Corrections against the native declarations

- `AppearancePresenceTests.swift`: both absolute-presence fixtures use
  `.present(until: last)`. Privacy cases are explicitly `[(UserPresenceStatus, String)]`,
  with `isHidden: false` supplied to `recently`, `lastWeek` and `lastMonth`.
  `SyncCore/SyncCore_TelegramUserPresence.swift:21–25,84–87` defines this exact status type
  and payloads; `TelegramUserPresence.status` is `UserPresenceStatus` in this checkout.
- `FeedFollowupTests.swift`: the existing public `EngineMessage` initializer
  constructs the native Postbox `Message` with all 24 arguments. The fixture keeps
  its intentional nil author and conditional reply map, forwarding every other
  field, including `associatedMessageIds`, custom tags, associated media, thread
  info and stories. The engine initializer unwraps the same native media/peers
  (`TelegramEngine/Messages/Message.swift:118–179`;
  `Postbox/Sources/Message.swift:719–743,800–809`).
- `FeedRemediationNativeTests.swift`: each affected test owns a fresh local
  `ContentSettings(ignoreContentRestrictionReasons: [], addContentRestrictionReasons: [])`.
  All six policy calls use that value. These are the canonical values declared in
  `TelegramCore/Sources/Settings/ContentSettings.swift:6–15`.
- Both Chats fixtures wrap their existing image as `.image(image)` in the
  `InstantPage` media dictionary. This matches `EngineMedia.image(TelegramMediaImage)`
  and the public `[EngineMedia.Id: EngineMedia]` page initializer
  (`TelegramEngine/Messages/Media.swift:9–12`; `SyncCore/SyncCore_InstantPage.swift:1628–1637`).

Declaration paths above are under `telegram-ios/submodules/`; `SyncCore/*` and
`TelegramEngine/*` are under `TelegramCore/Sources/`.

## Input and postimage SHA-256

Raw file bytes, currently LF. Paths are relative to `telegram-ios/submodules/`.
Postimages describe the prepared working-tree files.

| Test path | Input SHA-256 | Postimage SHA-256 |
| --- | --- | --- |
| `TelegramStringFormatting/Tests/AppearancePresenceTests.swift` | `1c104dad794ebb3c7d960fd64df8236a6865d209656dbb5a8a6be722e248958b` | `b29137fb7620976c91f84ebabb91cce403665b802df8ffb187fb1f14682053fb` |
| `TelegramUI/Tests/FeedTests/FeedFollowupTests.swift` | `0c14ca304a18ba78b6e509476f4163417515f4d759314f07b7e9f4c9e82af3cb` | `e91729e54d31fed86952f1eaa589a5821ba6e30ba7ddec30ab4f5cbe938af863` |
| `TelegramUI/Tests/FeedTests/FeedRemediationNativeTests.swift` | `dc02932ae314cf889b1fd5878a83825c566b558c4b20089bea795f629b9de790` | `8e6b10fb854e19b737fc51c935fd3cccf5ff7fbb439c0d23d6087298bbbcd368` |
| `TelegramUI/Tests/Chats/ChatMediaScheduleProducerTests.swift` | `dd0f8ad5a3fb28b6cff5d7c20253c327d556a6b7a1879b2fd7b22efa5ec49d22` | `bd1f12437bcc0877b89cabd4402e902dd9ec8c8dc51a90a1840eff381688eec9` |
| `TelegramUI/Tests/Chats/ChatSoundProducerTests.swift` | `7fe2940d63a593c49f008060a4a338b78891f0f795e8d7a3152e8a128b62cc5a` | `a4c265350594db6a0cbc2e6410dfb9e1395436634a1cd5ba77a0b8e25d893203` |

## Source checks and native handoff

- **PASS:** scoped `git diff --check` for the five test paths.
- **PASS:** inline Python source audit against the input commit and actual native
  declarations, **0.268 seconds**. It checked all 24 constructor arguments, canonical
  settings data, presence payloads and the native page/image types.
- **PASS:** all **23 test identifiers** and **147 XCTest call sites** retained;
  assertion text matches after accounting for the fresh settings binding. Deadline
  and import text, Feed ownership/consumer bodies and both Chat producer bodies
  were checked against the input. Each Chat diff is solely its dictionary wrapper.
- Every verification command used a **30-second timeout**.
- **BUILD dependency handoff:** no new edge is needed. The three existing test
  libraries already depend on `//submodules/TelegramCore:TelegramCore`, which
  exposes the public constructor and types used here.
- **Native pending:** Apple compilation and execution of
  `//submodules/TelegramStringFormatting:ExteralessAppearancePresenceTests`,
  `//submodules/TelegramUI:ExteralessFeedTests` and
  `//submodules/TelegramUI:ExteralessChatMediaTests`. The Windows source audit is
  not an Apple compiler or XCTest result.
