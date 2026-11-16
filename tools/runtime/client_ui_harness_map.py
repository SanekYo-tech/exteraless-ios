"""Actual-provider Map attribution evidence and its explicitly approved boundary."""

import hashlib
import json
import math
from pathlib import Path
import re
import struct

MAP_SCENARIOS = ('map-attribution',)
MAP_BATCH = ('map-attribution', 'map-attribution-1', MAP_SCENARIOS)
MAP_ENTRY = 'ExteralessMapAttributionFixture.run'
MAP_TILE_SOURCE = 'telegram-ios/Tests/ExteralessHarness/Fixtures/map-attribution-grid.png'
MAP_SOURCES = (
    'telegram-ios/submodules/LocationUI/BUILD',
    'telegram-ios/submodules/LocationUI/Sources/ExteralessLocationMapProvider.swift',
    'telegram-ios/submodules/LocationUI/Sources/LocationMapNode.swift',
    'telegram-ios/submodules/LocationUI/Sources/Tests/ExteralessMapAttributionFixture.swift',
    'telegram-ios/Tests/ExteralessHarness/BUILD',
    'telegram-ios/Tests/ExteralessHarness/Info.plist',
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenario.swift',
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenarios.swift',
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessApplication.swift',
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessMapAttribution.swift',
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessVisualArtifacts.swift',
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessDomainEvidence.swift',
    'telegram-ios/Tests/ExteralessHarness/Tools/map_tile_fixture.py',
    MAP_TILE_SOURCE,
    'swift/ExteralessCore/BUILD.bazel',
    'swift/ExteralessCore/Sources/ExteralessCore/MapPolicy.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/MapPolicyRuntime.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/MapProviderHTTP.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/MapResourceCache.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/NetworkResolverHTTP.swift',
)
MAP_BOUNDARY = {
    'osmTransport': 'injected owned 256px PNG or MapResourceError.unavailable only',
    'mapKitTransport': 'standard public Apple/GeoServices map requests permitted',
    'mapKitTrafficMeasurement': 'not intercepted; no total-egress-isolation claim',
    'locationPermissions': 'not requested', 'liveUserLocation': False,
    'accountRPC': 'not invoked by this fixture', 'foreignPlugins': 'not loaded',
}
MAP_TITLES = {
    'osm-standard': '© OpenStreetMap contributors',
    'satellite': 'Apple Maps · Satellite\nOSM has standard tiles only',
    'failure-fallback': 'OSM unavailable · Apple Maps fallback',
}
MAP_PROBES = ('home',) + tuple('map-' + palette + '-' + step for palette in ('light', 'dark')
                             for step in MAP_TITLES) + ('map-cleanup',)
MAP_CLEANUP = {'providerReleased': True, 'overlayCount': 0, 'mapDetached': True,
               'buttonDetached': True, 'delegateDetached': True, 'loaderClosed': True}


def require(value, message):
    if not value:
        raise ValueError(message)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def check_map_sources(manifest):
    missing = set(MAP_SOURCES) - manifest.get('files', {}).keys()
    require(not missing, 'Missing compiled Map provider/fixture/asset source inputs: ' + ', '.join(sorted(missing)))


def check_map_asset(archive, app_root, manifest):
    name = app_root + '/map-attribution-grid.png'
    require(0 < archive.getinfo(name).file_size <= 16384, 'Owned Map tile has an invalid byte bound')
    data = archive.read(name)
    require(data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) >= 24
            and struct.unpack('>II', data[16:24]) == (256, 256), 'Owned Map input must be a real 256px PNG')
    require(hashlib.sha256(data).hexdigest() == manifest['files'].get(MAP_TILE_SOURCE),
            'Bundled Map tile differs from its compiled source fingerprint')


def frame(value, name):
    result = value.get(name)
    require(isinstance(result, list) and len(result) == 4 and all(finite(item) for item in result)
            and result[2] > 0 and result[3] > 0, 'Missing/invalid actual UIKit frame: ' + name)
    return result


def contains(outer, inner, tolerance=0.5):
    x, y, width, height = outer
    a, b, w, h = inner
    return x - tolerance <= a and y - tolerance <= b and a + w <= x + width + tolerance and b + h <= y + height + tolerance


def validate_control(value, title):
    require(value.get('nativeClass') == 'UIButton' and value.get('buttonType') == 1
            and value.get('title') == value.get('label') == value.get('accessibilityLabel') == title,
            'Map attribution must be the actual configured UIButton and its rendered UILabel')
    require(value.get('insets') == [4, 6, 4, 6] and value.get('lines') == 2 and value.get('lineBreak') == 0
            and finite(value.get('pointSize')) and abs(value['pointSize'] - 10) < 0.01
            and finite(value.get('fontWeight')) and abs(value['fontWeight'] - 0.23) < 0.02 and value.get('font'),
            'Map attribution font/wrapping/content-inset evidence differs')
    require(all(value.get(name) is True for name in ('directMapParent', 'directHostParent', 'frontmost',
            'identityTransforms', 'inWindow', 'enabled')), 'Map attribution is absent, detached or behind its native map')
    button, label, map_bounds, map_host, host = (frame(value, name) for name in (
        'buttonFrameInMap', 'labelFrameInButton', 'mapBounds', 'mapFrameInHost', 'hostBounds'))
    converted = frame(value, 'buttonFrameInHost')
    global_button = frame(value, 'buttonFrameInWindow')
    global_host = frame(value, 'hostFrameInWindow')
    top, inset, total = (value.get(name) for name in ('topPadding', 'inset', 'topInset'))
    require(all(finite(item) and item >= 0 for item in (top, inset, total)) and abs(top + inset - total) < 0.01,
            'Map layout did not retain its actual parent padding/inset')
    require(abs(button[0] - 12) < 0.5 and abs(button[1] - total - 14) < 0.5
            and 24 <= button[3] <= 42 and button[2] <= max(40, map_bounds[2] - 100) + 0.5,
            'Map attribution moved off the production layout axes')
    require(contains(map_bounds, button) and contains([0, 0, button[2], button[3]], label)
            and contains(host, map_host) and contains(global_host, global_button), 'Native Map attribution label/frame is clipped')
    require(all(abs(a - b) <= 0.5 for a, b in zip(converted, [
        map_host[0] + button[0] - map_bounds[0], map_host[1] + button[1] - map_bounds[1], button[2], button[3]])),
        'Map/local/host coordinates were mixed')
    require(finite(value.get('labelFittedHeight')) and 0 < value['labelFittedHeight'] <= label[3] + 1,
            'Native Map text does not fit its actual UILabel')


def validate_map(state, scenario):
    from client_ui_harness_domains import check_manifest
    from client_ui_harness_visuals import BUILD_SELECTION, artifact_entries
    require(scenario in MAP_SCENARIOS, 'Unknown Map witness')
    probes = state.get('probes', [])
    require(tuple(probe.get('name') for probe in probes) == MAP_PROBES, 'Missing/reordered native Map palette/state probes')
    facts = state.get('facts', {})
    manifest = check_manifest(facts.get('domainSources', {}))
    check_map_sources(manifest)
    require(state.get('pythonRequested') is False and facts.get('buildSelection') == BUILD_SELECTION,
            'Map witness is not the native same-app fixture')
    final = facts.get('mapAttribution', {})
    require(final.get('fixture') == MAP_ENTRY and final.get('completed') is True
            and final.get('networkBoundary') == MAP_BOUNDARY and final.get('requestedRegion') == [0, 0, 0.04, 0.04],
            'Map entry, fixed non-user region or approved network boundary differs')
    require(final.get('sources') == {name: manifest['files'][name] for name in MAP_SOURCES}, 'Map source receipt differs from the compiled manifest')
    require(final.get('tileSource') == MAP_TILE_SOURCE and final.get('tileSHA256') == manifest['files'][MAP_TILE_SOURCE]
            and type(final.get('tileBytes')) is int and 0 < final['tileBytes'] <= 16384, 'Map did not use the sealed owned tile input')
    require(final.get('segmentDeadlineSeconds') == 3.8 and final.get('interactionDeadlineSeconds') == 9
            and finite(final.get('seconds')) and 0 < final['seconds'] < 9, 'Map fixture exceeded its finite interaction bound')
    segments = final.get('segments', [])
    require([item.get('palette') for item in segments] == ['light', 'dark'] and all(
        finite(item.get('seconds')) and 0 < item['seconds'] < 3.8 for item in segments), 'Map palette segments must each finish below four seconds')
    require(final.get('cleanup') == MAP_CLEANUP and final.get('loaderFailures') == 2
            and final.get('invalidRequests') == 0 and type(final.get('loaderSuccesses')) is int and final['loaderSuccesses'] >= 2,
            'Map real-loader sequence/provider cleanup did not complete')
    images = {item['path']: item for item in artifact_entries(state)}
    used = set()
    identities = None
    previous = {'loaderSuccesses': 0, 'rendererRequests': 0, 'tileRendererCount': 0}
    for index, probe in enumerate(probes[1:-1]):
        palette, step = ('light', 'dark')[index // 3], tuple(MAP_TITLES)[index % 3]
        value = probe.get('semantic', {})
        require(value.get('palette') == palette and value.get('step') == step and probe.get('dark') is (palette == 'dark'),
                'Map witness palette/state identity differs')
        require(value.get('mapDark') is (palette == 'dark') and value.get('buttonDark') is (palette == 'dark'),
                'Actual Map/button UIKit traits did not reach the requested palette')
        require(value.get('provider') == 'ExteralessLocationMapProvider' and value.get('mapClass') == 'MKMapView'
                and value.get('sourceManifestSHA256') == manifest['sha256'], 'Map witness substituted a provider/map or stale source')
        current_ids = value.get('mapInstance'), value.get('buttonInstance')
        require(all(type(item) is int and item > 0 for item in current_ids) and current_ids[0] != current_ids[1], 'Missing actual Map/button identities')
        identities = identities or current_ids
        require(current_ids == identities, 'Palette/state changes replaced the actual provider button or MKMapView')
        center = value.get('center', [])
        require(len(center) == 2 and all(finite(item) and abs(item) < 1e-5 for item in center)
                and value.get('showsUserLocation') is False and value.get('trackingMode') == 0,
                'Map left the fixed neutral region or enabled user tracking')
        require(value.get('mapType') == (2 if step == 'satellite' else 0)
                and value.get('overlayCount') == (1 if step == 'osm-standard' else 0), 'Map state did not use the actual overlay/native fallback')
        require(value.get('loaderFailures') == index // 3 + (1 if step == 'failure-fallback' else 0), 'Map fallback bypassed/duplicated loader failure')
        for name in previous:
            require(type(value.get(name)) is int and value[name] >= max(1, previous[name]), 'Missing/non-monotonic actual Map renderer/loader counters')
            if step == 'osm-standard':
                require(value[name] > previous[name], 'OSM palette never reached its real renderer and injected loader')
            previous[name] = value[name]
        control = value.get('configurationControl', {})
        validate_control(control, MAP_TITLES[step])
        for name, kind in (('nativeViewImage', 'live-map-hierarchy'), ('nativeButtonImage', 'actual-provider-button-layer')):
            handle = value.get(name)
            require(handle in images and handle not in used and images[handle].get('kind') == kind,
                    'Map witness needs its own real native hierarchy/button PNG')
            used.add(handle)
        button_image = images[value['nativeButtonImage']]
        require(abs(button_image['width'] - control['buttonFrameInMap'][2]) <= 1
                and abs(button_image['height'] - control['buttonFrameInMap'][3]) <= 1, 'Map button PNG is not its actual control bounds')
        if step == 'osm-standard':
            require(value.get('tileReplyCalls') == 1 and value.get('tileReplySHA256') == final['tileSHA256']
                    and value.get('tileReplyBytes') == final['tileBytes'] and value.get('tileSize') == [256, 256]
                    and value.get('canReplaceMapContent') is True and 'ExteralessOSMTileOverlay' in value.get('overlayClass', ''),
                    'Actual OSM overlay did not return the owned tile through its override')
            event_names = ['standard-update', 'owned-tile-reply']
        elif step == 'satellite':
            event_names = ['satellite-update']
        else:
            require(value.get('tileReplyCalls') == 1 and value.get('tileReplyError') == 'unavailable' and value.get('tileReplyBytes') == 0
                    and value.get('failurePath') == [index // 3, 0, 19]
                    and value.get('failureRoute') == 'installed MKTileOverlay.loadTile -> owned loader -> failed -> provider.apply',
                    'Fallback label was not reached through the actual overlay error callback')
            event_names = ['overlay-failure-request', 'owned-loader-unavailable', 'overlay-error-completion', 'provider-fallback-observed']
        events = value.get('events', [])
        require([event.get('name') for event in events] == event_names, 'Map callback trace is missing/reordered')
        times = [event.get('wallTime') for event in events] + [probe.get('wallTime')]
        require(all(finite(item) for item in times) and times == sorted(times), 'Map callback events do not bracket the recorded probe')
    cleanup = probes[-1].get('semantic', {})
    require(cleanup.get('nativeFixtureReturned') is True and cleanup.get('firstResponder') is False
            and cleanup.get('cleanup') == MAP_CLEANUP and cleanup.get('nativeViewImage') in images,
            'Map cleanup lacks the returned native host capture')
    used.add(cleanup['nativeViewImage'])
    require(used == images.keys() and len(used) == 13, 'Map native PNG set is incomplete or contains substituted extra images')


def map_recording_evidence(folder, state, handles):
    """Bind the recorded frame references and real native PNG bytes to this scene."""
    from client_ui_harness_visuals import artifact_entries
    folder = Path(folder)
    validate_map(state, 'map-attribution')
    for entry in artifact_entries(state):
        path = folder / entry['path']
        require(not path.is_symlink() and not path.parent.is_symlink() and path.is_file(), 'Missing/indirect Map native PNG')
        require(path.stat().st_size == entry['bytes'], 'Map PNG size changed after capture')
        data = path.read_bytes()
        require(data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) >= 24
                and struct.unpack('>II', data[16:24]) == (entry['width'], entry['height'])
                and hashlib.sha256(data).hexdigest() == entry['sha256'], 'Map native PNG byte/geometry identity differs')
    require(tuple(item.get('name') for item in handles.get('probes', [])) == MAP_PROBES
            and handles.get('sourceManifestSHA256') == state['facts']['domainSources']['sha256'], 'Map PTS handles differ from the native probes')
    for probe, handle in zip(state['probes'][1:-1], handles['probes'][1:-1]):
        require(handle.get('nativeViewImage') == probe['semantic']['nativeViewImage']
                and handle.get('nativeButtonImage') == probe['semantic']['nativeButtonImage']
                and handle.get('candidateFrameIndices'), 'Map capture lacks native PNG/recorded PTS references')
    digest = lambda path: hashlib.sha256((folder / path).read_bytes()).hexdigest()
    return {'nativeEntry': MAP_ENTRY, 'networkBoundary': MAP_BOUNDARY, 'stateSha256': digest('state.json'),
            'frameHandlesSha256': digest('frame-handles.json'), 'tileSHA256': state['facts']['mapAttribution']['tileSHA256'],
            'nativePNGCount': 13, 'paletteStateCount': 6, 'sourceManifestSHA256': state['facts']['domainSources']['sha256']}


def check_map_recording_summary(recording, sources):
    evidence = recording.get('mapEvidence', {})
    require(recording.get('timestampSource') == 'ffprobe' and evidence.get('nativeEntry') == MAP_ENTRY
            and evidence.get('networkBoundary') == MAP_BOUNDARY and evidence.get('nativePNGCount') == 13
            and evidence.get('paletteStateCount') == 6 and evidence.get('tileSHA256') == sources['files'][MAP_TILE_SOURCE]
            and evidence.get('sourceManifestSHA256') == sources['sha256'], 'Map recording has no bound native/PTS/approved-boundary evidence')
    require(all(isinstance(evidence.get(key), str) and re.fullmatch(r'[0-9a-f]{64}', evidence[key])
                for key in ('stateSha256', 'frameHandlesSha256')), 'Map state/PTS hashes are missing')


def verify_map_recording(folder, sources, recording):
    from client_ui_harness import validate_state
    from client_ui_harness_visuals import recorded_frame_index
    folder = Path(folder)
    read = lambda name: json.loads((folder / name).read_text(encoding='utf-8'))
    state, handles = read('state.json'), read('frame-handles.json')
    validate_state(state, 'map-attribution', state['runId'])
    require(state['facts']['domainSources'] == sources, 'Map recording source manifest differs from the retained build')
    require(handles == recorded_frame_index(state, read('timing.json'), read('ffprobe.json')), 'Map ffprobe PTS index was altered')
    require(all((folder / item[key]).is_file() for item in handles['frames'] for key in ('frame', 'sheet')), 'Map recorded frame/sheet is missing')
    require(map_recording_evidence(folder, state, handles) == recording.get('mapEvidence'), 'Map native receipt differs from the recorded batch')
    require(hashlib.sha256((folder / 'recording.mp4').read_bytes()).hexdigest() == recording.get('recordingSha256'), 'Map video changed after frame extraction')
