# TelegramUI compiler cohort — 43761767575 / f05473ea

## Follow-up: 43769738884 / 31287b92

The76 prior diagnostics passed. The next compiler result identified two sites in
`ExteralessMessageMediaActions`: legacy SwiftSignalKit Sendable metadata and the
never-mutated local weak presenter. The import now uses `@preconcurrency` for its
existing mutex-backed Atomic/Subscriber handoffs. The presenter is held by the
existing `Weak` box as a constant; its value is still resolved at presentation.
Decode cancellation and export/presentation admission retain their existing order.

## Initial coordinated slice

The full compiler reached the main TelegramUI library and reported76 source
diagnostics. The coordinated33-file correction covers actual imports/overloads,
native enum/resource types, UIKit member-name conflicts, actor/capture boundaries,
generated strings and the remaining syntax/unused-result sites.

Source handoffs:
- `ios-chat-ui-typecheck.md` —11 files;
- `ios-appearance-ui-typecheck.md` —4 files;
- `ios-ai-ui-typecheck.md` —3 files plus the matching Root conformance deletion;
- `ios-feed-player-typecheck.md` —9 files;
- `ios-native-services-privacy-typecheck.md` —5 files.

All27 delegated postimages were checked. Root and MainMenu's compiler hunks were
staged against the published base; their prepared Settings Search/Reset changes
retain their own upcoming source cohort. The SDK generator read the Git index for
this exact compiler delivery. Its59 raw pins and10 input receipts must match the
staged bytes. Config counts remain276 implemented/0 blocked/32 unsupported, with
308 API identities and508 bindings.

The next full unsigned app build must verify this source cohort. The previous
component/FD/UI receipts retain their own source identities and execution scopes.
