# UIKit Feed fixture resource ID — 43788169856 / d296e456

The full debug simulator graph passed aquery after the Postbox visibility fix.
Compilation reported one source diagnostic in this pass:
`ExteralessFeedOfflineFixture.swift:50`, `MediaResourceId` is not
`EngineMediaResource.Id`.

The fixture now uses the existing public `EngineMediaResource.Id(resource.id)`
initializer. It preserves the same string representation, owned local PNG and
synchronous cache write. The isolated-account admission and30-second fixture
permit remain intact. No new network operation or renderer is introduced.

The complete diagnostic log is retained at
`build/artifacts/client-ui-43788169856/build/build.log`. Subsequent dependent
Swift modules, native tests and recorded frames still need the next Apple pass.

## Follow-up: 43793245829 / 53cab85a

Feed compiled. This pass then reported an unused-mutation diagnostic for the Map
fixture's local weak provider witness. The fixture now holds the existing
SwiftSignalKit `Weak` container as a constant and inspects its weak value at
cleanup. Provider release and overlay/loader assertions are retained. LocationUI
already declares the SwiftSignalKit dependency; no new build edge is required.
