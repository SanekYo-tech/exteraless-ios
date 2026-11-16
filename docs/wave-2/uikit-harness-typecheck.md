# UIKit Harness typecheck — 43801470131 / 039fc5da

Main TelegramUI compiled. The app/Harness graph then found four diagnostics in
the standalone Harness and one separate TelegramUI link symbol.

- Composer imports Postbox for its actual `RenderedPeer`; the direct dependency
  and scoped test-client visibility are already declared.
- Feed reads the public `EngineMediaResource.ResourceData.isComplete` property.
  Explicit native data, message-array and projection-dictionary types keep the
  subsequent key-path/group predicates in their real Engine type context.

Owned Postbox writes, local resource bytes, six-message count, namespace-exclusion
sentinel and peer/group/revision assertions are preserved. No fixture renderer or
native projection is replaced. The independent `writeSettings` link investigation
is recorded separately; the next Apple pass must compile and execute the Harness.
