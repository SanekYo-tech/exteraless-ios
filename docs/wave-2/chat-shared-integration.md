# Chat shared integration — coordinator receipt

Applied against the current working tree after the frozen Chat handoff:

- `AccountContext/Sources/AccountContext.swift`: optional
  `ChatSendMessageActionSheetControllerSendParameters.notificationOverride`.
- `ChatControllerInteraction.swift`: `sendCurrentMessage` carries `Bool?`.
- `TelegramUI/Sources/ChatController.swift`: recording resolves an absent choice
  through the current default; text/media/inline paths preserve explicit audible
  `false`. `transformEnqueueMessages` applies `withNotificationOverride` before
  its existing paid/send-as/effect/scheduling attributes. Scheduling no longer
  removes an explicit audible override.
- `TelegramUI/Sources/AccountContext.swift`: `requestCall` goes through the existing
  native confirmation helper before its original call-manager implementation.
- `PeerInfoData.swift`: chat-origin call/video-call and broadcast search button
  visibility now consume their Chat settings. Normal profile entry stays native.

PostboxImportCheck and scoped `git diff --check` passed. These are source checks;
Swift/iOS typecheck and recorded UI acceptance have not run for this composition.

Remaining portions have explicit owners:

| Portion | Owner |
|---|---|
| AppDelegate URL ingress, Share text cleaning/rules bootstrap | App integrator |
| Chat context/reaction menu visibility and AI translation-sheet entry | Native AI remediator, composing with AF01–06 |
| Source-defined legacy media aliases in Cloud import | Cloud owner, composing with CA01/02 |
| Resolved TL `silent=false` attribute | TL owner in the common native media pipeline |

`chat-phase2-shared.patch` and `chat-media-shared.patch` are historical insertion
references. Do not apply all of them again; the sections above are already present.
