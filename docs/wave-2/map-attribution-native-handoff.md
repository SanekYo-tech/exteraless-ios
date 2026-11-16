# Map attribution — twentieth recorded scenario

Status: **implemented and source-preflight ready; coordinator native compilation,
execution and recorded-frame acceptance pending**. This extends the accepted
40-path SDK/Reset packet with one `map-attribution` invocation. The source-declared
native map remains **37 labels / 89 mandatory files / 92 classes / 430 methods**.
The Map fixture adds a recording case, not an XCTest method.

## Actual native entry

`LocationUI.ExteralessMapAttributionFixture.run(hostView:topPadding:inset:tileData:sourceHashes:setPalette:probe:)`
is compiled under `EXTERALESS_MAP_ATTRIBUTION_FIXTURE` in the existing debug
configuration. `ClientHarnessSession.runMapAttributionSupplement()` calls it with
the current Display navigation host, real safe-area/navigation-bar dimensions and
the existing account context's palette setter. It constructs an ordinary
`MKMapView`, the production `ExteralessLocationMapProvider`, and the platform
`MKTileOverlayRenderer`. The provider creates the one original UIButton retained
across all six palette/state observations.

The production provider receives exactly two dependencies: `policy`, defaulting
to `MapPolicy.current()`, and `tileLoader`, defaulting to
`MapProviderHTTP.shared.fetch`. Its attribution styling, native failure callback,
cache/lifetime logic and ordinary `LocationMapNode` call sites keep their existing
behavior. The fixture calls the same `update(mapType:)` / `updateLayout` APIs.
`LocationMapNode.swift` is fingerprinted as the ordinary owner; the test entry
hosts the provider directly because that node also enables live user location.

## Approved transport boundary

- Fixed, non-user WGS84 region: **0° latitude / 0° longitude**, span **0.04° × 0.04°**.
- The injected OSM loader returns only the owned PNG or `MapResourceError.unavailable`.
- **Standard public Apple/GeoServices map requests are permitted.** Their traffic
  is not intercepted or claimed to be disabled by URLProtocol/SDK controls.
- No CLLocation/CLLocationManager instances, permission requests, live user
  location, account RPCs or foreign plugins are used by this entry. The existing
  disposable host supplies the UI context. `showsUserLocation` is false and
  tracking is `.none`; observed map center/traits are checked in every state.

`Fixtures/map-attribution-grid.png` is a **1,143-byte, 256×256 RGB PNG** generated
by `Tools/map_tile_fixture.py`. SHA-256:
`5376632aa16c5f4f327c0c147e53871df37642ed25f7905cc80663f7e9e87490`.
It is bundled as an input and matched to its compiled source hash before use.
It supplies tile data, not expected UI pixels.

The failure witness calls `loadTile` on the overlay actually installed in the
MKMapView. The result passes through `MapResourceCache`, the owned loader, the
overlay completion/error, its real `failed` callback, and the provider's
main-queue `apply()`. Distinct offscreen z19 paths `(0,0)` and `(1,0)` avoid reusing
the real negative-cache entry across palettes. No label, fallback flag or callback
is manually assigned by the fixture. Provider cleanup clears its own namespace.

## Frame expectations — established before recording

Exact order: `home`, then the following three states in **light**, then **dark**,
then `map-cleanup`.

| Probe suffix | Expected native frame |
| --- | --- |
| `osm-standard` | Real MKTileOverlayRenderer displays the owned blue/green grid and center axes. The provider button reads **© OpenStreetMap contributors**. Actual renderer construction and owned tile delivery must precede capture. |
| `satellite` | OSM overlay is removed; native map type is satellite. The same button reads **Apple Maps · Satellite** / **OSM has standard tiles only**, on two lines. Public tile arrival can vary; label/overlay acceptance does not wait on an external server. |
| `failure-fallback` | The injected error retires the real OSM overlay. Native map type is standard; the same button reads **OSM unavailable · Apple Maps fallback**. The old copyright-only label must not return after the recorded failure callback. |

In both palettes inspect the actual **10pt medium** UILabel, **two-line maximum**,
word wrapping and **4/6/4/6pt** content insets. Button x is **12pt** in the map;
y is the actual **topPadding + inset + 14pt**. Height is **24–42pt**. Local-map,
host and window CGRects are retained separately, along with native trait values,
font weight, text-fit height, direct-parent and frontmost membership. Text and
background stay together through map-type/tile repaint; no clipped glyphs,
duplicate labels, displaced axes or stale attribution are acceptable. No custom
spring/choreography is supplied. Inspect map repaint and the final settled state
at native speed and verify the clean host after removal.

Every state saves a real hierarchy PNG plus a PNG of the provider's actual
button. Cleanup adds one host PNG: **13 native artifacts**. `frame-handles.json`
links each to the MP4's **ffprobe PTS**, decoder-order frame and labelled sheet.
Failure-request, loader-unavailable, completion and fallback-observation timestamps
are separate frame brackets. PTS/frames, not a synthetic PNG or frame-index/fps
calculation, determine visual acceptance. Cite frame/PTS ranges in coordinator review.

## Workflow, budgets and identity

`evidence/supplements/map-attribution/`, batch `map-attribution-1`, runs after the
previous nineteen scenes. The complete gate requires **20 scenes / 9 distinct
fresh serial simulator UUIDs**: base **3+3+2**, Reset **3+3+3+1**, trust **1**, Map
**1**. Every batch consumes the same retained IPA, compiled source manifest,
staging identity and native-test result. The baseline `evidence/batches.json`
retains its eight original scenes.

Map keeps the **30s process cap**. Each palette has a **3.8s** segment deadline;
overall interaction is **9s**, with bounded **1.2s** native readiness/error waits
and **120ms** capture settles. The fresh Map invocation has a **150s** outer
envelope. Supplemental command envelopes including final verification total
**990s**; the job cap remains **215 minutes**. Compile once for the whole cohort.

The manifest requires **20 Map source/input pins**, including the real provider,
LocationMapNode, debug entry, dispatch/geometry capture, tile generator/resource
and Core map/cache/cancellation code. BUILD filegroups and the direct Harness →
LocationUI dependency supply the fingerprint graph; the normal app already has
that LocationUI edge. Actual aquery compiler arguments must contain the entry
define. The complete verifier rechecks Map native PNG bytes and reconstructed
ffprobe handles against the scene report and compiled source identity.

Coordinator-applied Composer math and all six Pill observer calls remain present.
The historical SDK 40-path archive and receipts remain at
`build/wave-2-dependencies/native-gate-sdk-followup-590ce05b/complete-handoff/`.
The new delta and readonly current input receipts are under
`build/wave-2-dependencies/native-gate-map-followup/`.

The subsequent SDK-only FD semantic contract and applied UIKit owner-worker join
are documented in `native-fd-platform-handoff.md`. They add no Map/layout scenes.
The first `sealed/` Map receipt is retained; the FD-inclusive receipt is separate.
