# TLN-02 — legacy text-service ancestry

The coordinator applied the legacy native text-route fix from
`reviews/tl-network.md`. **All three new Host tests passed** in Compat
`43703427760 / c7ef25ed` (150 Host / 24 Hooks passed). The run's Core step retains
one unrelated Cloud retry failure. Apple/native-CPython execution remains pending.

- `BridgeServices.sendMessage` captures the actual owner-worker TL scope before
  calling a platform service. It matches the C-owned plugin ID and immutable
  owner token. A mismatched, expired or depth-limited scope rejects scheduling;
  plugin-supplied origin fields are never read.
- `PluginTextMessageRequest.origin` is an immutable native value carried across
  the main-actor and EngineData hops. Calls outside a hook retain nil ancestry.
- `TelegramPluginServices` sends through `exteralessTLSendText`, preserving its
  existing cached-peer, account, restriction and paid-message checks. The Core
  pipeline attaches native correlations before an outgoing RPC can start and
  reuses native enqueue/Updates handling. The absent legacy silent parameter
  still follows `chats.silentMessageByDefault`.
- Native errors/empty IDs are failures in the existing service log; successful
  scheduling continues to return a request ticket, not a server message ID.

`PluginTextOriginTests.swift` adds three bounded tests: real Host mailbox scope →
BridgeServices → recorded native request → delayed child fanout (`alpha` skipped,
`beta` called); unrelated sends still run both hooks; forged origin/token, closed
scope and the 32-ancestor limit cannot start a new root or schedule an effect.
The engine in these tests is explicitly the existing recording FakeEngine.

Remaining linked gate: TLN-05's provisional-to-commit-owned correlation lifetime is
being fixed in the shared Core text/media pipeline by its TL owner. This route
uses that pipeline and does not create another correlation registry. Apple
typecheck, native canned enqueue/cancellation tests and current real-CPython SDK
execution are required before independent closure.
