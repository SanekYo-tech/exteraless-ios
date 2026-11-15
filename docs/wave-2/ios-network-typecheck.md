# iOS resolver/privacy typecheck remediation

Full iOS build `43740868881` failed at commit
`fac6cf26be9f622dc1c5eec8cf7cf165fff6200c`. Evidence:
`C:\Users\sasha\AppData\Local\Temp\opencode\ipa-fac6cf26-failed.log`.
These fixes are uncommitted on entry HEAD
`16c23a99449eba704885a83982e35a079054f815`.

## Six diagnostics, five line replacements

- `ExteralessNetworkResolverRuntime.swift:37`,
  `ExteralessResolverTLSConnector.swift:42`, and
  `ExteralessResolverTcpConnectionInterface.swift:68` use the imported
  `NSNotification.Name.MTAppNetworkResolverDidChange` constant.
- `ExteralessResolverTcpConnectionInterface.swift:92` explicitly captures `[self]`
  in the already-strong queued startup closure, addressing the nested weak-capture
  diagnostics at lines 96 and 99.
- `ExteralessPrivacyPolicy.swift:223` explicitly captures `[network]` in the
  already-strong request closure, addressing the weak submit capture at line 227.

Observer-token storage/removal, weak inner captures, cancellation/disposal,
shutdown, and late-callback/account guards retain their existing contracts.
All other production body text in these four files matches the failing SHA.
The public MtProtoKit `NSNotificationName` declaration also matches that SHA.

## Fixed paths and source SHA-256

Repository-relative paths; hashes cover the UTF-8/LF working-tree files:

```text
74056ba7111cf42222993d16e5576b2708ce39d468950ebe5940854026ed8603  telegram-ios/submodules/TelegramCore/Sources/ExteralessNetwork/ExteralessNetworkResolverRuntime.swift
e005c6088bff0f30990affe95553740c6ff08888dceb6d6ab788f301ff6f9903  telegram-ios/submodules/TelegramCore/Sources/ExteralessNetwork/ExteralessResolverTLSConnector.swift
7310bed52d5ce9e16053fba74f8b256ade3f2c0aad57a2544d1f6e31a8ecaf07  telegram-ios/submodules/TelegramCore/Sources/ExteralessNetwork/ExteralessResolverTcpConnectionInterface.swift
d1f7edce90b013535eefb349645183529b1f63d4773db0434571be73de5345f3  telegram-ios/submodules/TelegramCore/Sources/State/ExteralessPrivacyPolicy.swift
```

## Verification

Scoped `git diff --check` passed; source diff and unchanged header were reviewed
against the failing commit. **Native iOS compile/typecheck remains pending.**
This Windows host has no `swiftc` on PATH; the checks above are source-level only.
