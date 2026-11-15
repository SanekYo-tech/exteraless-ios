# SDK-05 — global manager writer authority

The coordinator replaced the per-plugin `setPinnedPlugins` write loop with one
`PluginManagerPreferenceChange.pinnedSet(wanted:installed:)` transaction. It updates
the currently installed IDs together and preserves uninstalled preference entries,
matching the former operation's scope. Other manager fields remain in that same
persisted document.

`PluginConfigAuthority` is an immutable Sendable capability carrying the live
owner/permission check. Runtime forwards it through the detached writer. The real
`PluginManagerPreferences.apply` checks it immediately before atomic publication,
under the writer lock. Expired queued work writes nothing; one already-admitted
complete write may finish. Developer/compact SDK writes use the same boundary.
Native master/safe-mode maintenance retains its existing admitted-operation policy.

Three bounded `PluginManagerAuthorityTests.swift` fixtures exercise the actual
writer: revoked two-ID set preserves bytes/presence, one admitted set updates both
IDs despite subsequent revocation, and queued pin/compact/developer writes reject
an authority revoked before execution. No Host, account, Keychain or network runs.
Compile with the existing shipping preferences/model sources in NativeUIContracts.
Swift/native test execution remains pending.

The native Config provider's apply closure now receives `PluginConfigAuthority`;
custom fixture adapters call `authority.isCurrent()`. The JSON/SDK API and its
queued-operation receipt are unchanged.
