# TelegramUI native-service/privacy compiler corrections

Full app43761767575/f05473ea reached the main TelegramUI library and reported76
diagnostics. This coordinator slice addresses seven of them in five files.

- `NativeServiceAccountModel`: the shared TL peer enum also includes secret chats,
  while this facade explicitly accepts cloud user/group/channel peers and constructs
  cloud message IDs. Admission now enforces that declared domain; the defensive
  secret branch returns no cloud message ID. The separate typed TL secret-chat
  services retain their own supported routes.
- `NativeServiceControllerSnapshots.bind`: namespace selection switches on the
  actual three-case snapshot peer kind, matching the preceding conversion.
- `ExteralessPrivacyExtrasIntegration`: remove an extra closing parenthesis from
  the passcode-session controller call; authorization and invalidation remain.
- Hidden-account code deletion uses the existing generated `Common_Delete` string.
  The code-removal operation and confirmation text remain explicit.
- Hidden-code/filter editors explicitly discard the optional popped controller;
  they still pop only from their admitted success completion.

Native compilation and UIKit frames remain pending the joined compiler cohort.
