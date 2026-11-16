# Scoped Mac Core/Hooks acceptance — 43786995069

Run43786995069 / `5fa35f34aebd578cfc4578abfa45abf358b9a070` is globally
**FAILED**. Its independent Core and Hooks steps passed. Downloaded evidence is
under `build/artifacts/python-runtime-43786995069/swift-components`.

| Package | Actual passed cases | Git-verified source pins | Build / test-process seconds |
|---|---:|---:|---:|
| ExteralessCore | 722 | 282/282 | 50.695 / 9.195 |
| PluginHooks | 30 | 15/15 | 16.663 / 2.147 |

Every source hash was compared against the named commit's Git blob. Counts were
cross-checked against the individual passed XCTest events and zero-failure suite
summary, not inferred from the number of authored test methods.

SHA-256:
- Core report: `d7576ad882fa83626e1b8afc30ff6fbdd2cf7bde31262a0adea085dd01da827e`.
- Core native log: `4af815b99366cab8af595edbe23e8b97a944c67d08f878834b09f4f9c2173128`.
- Hooks report: `7456c4e7aab55239581d1492ee840c01d2def0b64e5037c5474dde3de6b2167c`.
- Hooks native log: `30a7cfc4fad46574a27007b6c4461850630f912bdeb279483dd2590b180e00c5`.

Host compilation failed on Darwin `kevent` name resolution. Listener readiness
and the standalone UI fixture also failed; HNS/five-child acceptance and iOS
runtime probes were not reached. This receipt establishes only the two passed
Mac component scopes, with no UIKit, whole-runtime or production-network claim.
