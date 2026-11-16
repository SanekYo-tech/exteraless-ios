"""Map source, resource and evidence rejection checks. All UI reports are synthetic."""

import binascii
import copy
import hashlib
import io
import json
from pathlib import Path
import re
import runpy
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from client_ui_harness_domains import REQUIRED_SOURCE_SUFFIXES, manifest_from_ipa
from client_ui_harness_inputs import harness_inputs
from client_ui_harness_map import (MAP_SOURCES, MAP_TILE_SOURCE, MAP_SCENARIOS, MAP_ENTRY, MAP_BOUNDARY,
    MAP_TITLES, MAP_PROBES, MAP_CLEANUP, validate_map, map_recording_evidence)
from client_ui_harness_visuals import BUILD_SELECTION, recorded_frame_index


def png(width, height):
    """A solid synthetic artifact for byte-integrity tests, never expected UIKit pixels."""
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', binascii.crc32(name + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress((b'\0' + b'\x77\x99\x88' * width) * height)) + chunk(b'IEND', b''))


class MapAttributionChecks(unittest.TestCase):
    def fixture(self):
        tile = (ROOT / MAP_TILE_SOURCE).read_bytes()
        files = {name: 'a' * 64 for name in MAP_SOURCES}
        files.update({'telegram-ios/fixture' + name: 'a' * 64 for name in REQUIRED_SOURCE_SUFFIXES})
        files[MAP_TILE_SOURCE] = hashlib.sha256(tile).hexdigest()
        manifest = {'format': 'exteraless-ui-domain-sources/1', 'files': files,
                    'sha256': hashlib.sha256(''.join(sha+'  '+name+'\n' for name,sha in sorted(files.items())).encode()).hexdigest()}
        data, entries, probes = {}, [], []
        def artifact(name, kind, width, height):
            path = 'native/' + name + '.png'
            content = png(width, height)
            data[path] = content
            entries.append({'path': path, 'kind': kind, 'width': width, 'height': height,
                            'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
            return path
        for index, name in enumerate(MAP_PROBES):
            value = {}
            if index not in (0, 7):
                number = index - 1
                palette, step = ('light', 'dark')[number // 3], tuple(MAP_TITLES)[number % 3]
                width, height = (180, 24) if step == 'osm-standard' else (240, 32)
                title = MAP_TITLES[step]
                control = {'nativeClass': 'UIButton', 'buttonType': 1, 'title': title, 'label': title, 'accessibilityLabel': title,
                    'insets': [4, 6, 4, 6], 'lines': 2, 'lineBreak': 0, 'font': 'synthetic-medium', 'fontWeight': 0.23,
                    'pointSize': 10, 'buttonFrameInMap': [12, 120, width, height], 'labelFrameInButton': [6, 4, width-12, height-8],
                    'labelFittedHeight': height-8, 'buttonFrameInHost': [12, 120, width, height],
                    'buttonFrameInWindow': [12, 120, width, height], 'mapFrameInHost': [0, 0, 402, 874],
                    'mapBounds': [0, 0, 402, 874], 'hostBounds': [0, 0, 402, 874], 'hostFrameInWindow': [0, 0, 402, 874],
                    'topPadding': 62, 'inset': 44, 'topInset': 106, 'directMapParent': True, 'directHostParent': True,
                    'frontmost': True, 'identityTransforms': True, 'inWindow': True, 'enabled': True}
                value = {'palette': palette, 'step': step, 'provider': 'ExteralessLocationMapProvider', 'mapClass': 'MKMapView',
                    'mapDark': palette == 'dark', 'buttonDark': palette == 'dark',
                    'sourceManifestSHA256': manifest['sha256'], 'mapInstance': 1, 'buttonInstance': 2,
                    'center': [0, 0], 'showsUserLocation': False, 'trackingMode': 0, 'mapType': 2 if step == 'satellite' else 0,
                    'overlayCount': 1 if step == 'osm-standard' else 0, 'loaderSuccesses': 2 + number,
                    'loaderFailures': number // 3 + (step == 'failure-fallback'), 'rendererRequests': 1 + number,
                    'tileRendererCount': 1 + number, 'configurationControl': control,
                    'nativeViewImage': artifact(name, 'live-map-hierarchy', 402, 874),
                    'nativeButtonImage': artifact(name+'-button', 'actual-provider-button-layer', width, height)}
                if step == 'osm-standard':
                    value.update(tileReplyCalls=1, tileReplySHA256=files[MAP_TILE_SOURCE], tileReplyBytes=len(tile),
                                 tileSize=[256, 256], canReplaceMapContent=True, overlayClass='LocationUI.ExteralessOSMTileOverlay')
                    events = ['standard-update', 'owned-tile-reply']
                elif step == 'satellite':
                    events = ['satellite-update']
                else:
                    value.update(tileReplyCalls=1, tileReplyError='unavailable', tileReplyBytes=0, failurePath=[number//3, 0, 19],
                        failureRoute='installed MKTileOverlay.loadTile -> owned loader -> failed -> provider.apply')
                    events = ['overlay-failure-request', 'owned-loader-unavailable', 'overlay-error-completion', 'provider-fallback-observed']
                value['events'] = [{'name': event, 'wallTime': 100 + index - 0.5 + i * 0.05} for i,event in enumerate(events)]
            elif index == 7:
                value = {'nativeFixtureReturned': True, 'firstResponder': False, 'cleanup': dict(MAP_CLEANUP),
                         'nativeViewImage': artifact(name, 'live-view-layer', 402, 874)}
            probes.append({'name': name, 'semantic': value, 'dark': name.startswith('map-dark-'), 'wallTime': 100+index,
                           'scale': 3, 'elements': [{'class': 'synthetic'}], 'controllers': ['synthetic-host']})
        final = {'fixture': MAP_ENTRY, 'completed': True, 'networkBoundary': dict(MAP_BOUNDARY),
            'requestedRegion': [0, 0, 0.04, 0.04], 'sources': {name:files[name] for name in MAP_SOURCES},
            'tileSource': MAP_TILE_SOURCE, 'tileSHA256': files[MAP_TILE_SOURCE], 'tileBytes': len(tile),
            'segmentDeadlineSeconds': 3.8, 'interactionDeadlineSeconds': 9, 'seconds': 3,
            'segments': [{'palette': 'light', 'seconds': 1}, {'palette': 'dark', 'seconds': 1}],
            'cleanup': dict(MAP_CLEANUP), 'loaderFailures': 2, 'loaderSuccesses': 8, 'invalidRequests': 0}
        return ({'format': 'exteraless-client-ui-harness/1', 'runId': 'synthetic-map', 'scenario': 'map-attribution',
                 'phase': 'completed', 'semanticPassed': True, 'unexpectedServices': [],
                 'visualReview': 'pending-recorded-frame-review', 'pythonRequested': False, 'probes': probes,
                 'facts': {'domainSources': manifest, 'mapAttribution': final, 'buildSelection': dict(BUILD_SELECTION),
                           'visualArtifacts': entries}}, data)

    def test_all_six_states_require_actual_style_geometry_callbacks_and_approved_boundary(self):
        original, _ = self.fixture()
        validate_map(original, 'map-attribution')
        for mutation in ('label', 'font', 'insets', 'clipping', 'parent-axis', 'old-button', 'map-subclass',
                         'palette', 'native-traits', 'fallback-without-loader', 'callback-order', 'source', 'asset', 'location',
                         'offline-claim', 'missing-png', 'segment-deadline', 'cleanup'):
            bad = copy.deepcopy(original)
            value = bad['probes'][3]['semantic']
            final = bad['facts']['mapAttribution']
            if mutation == 'label': value['configurationControl']['label'] = 'OSM unavailable'
            elif mutation == 'font': value['configurationControl']['pointSize'] = 17
            elif mutation == 'insets': value['configurationControl']['insets'] = [0, 0, 0, 0]
            elif mutation == 'clipping': value['configurationControl']['labelFrameInButton'][2] = 400
            elif mutation == 'parent-axis': value['configurationControl']['buttonFrameInHost'][1] += 20
            elif mutation == 'old-button': value['buttonInstance'] = 3
            elif mutation == 'map-subclass': value['mapClass'] = 'FakeMKMapView'
            elif mutation == 'palette': bad['probes'][4]['dark'] = False
            elif mutation == 'native-traits': bad['probes'][4]['semantic']['mapDark'] = False
            elif mutation == 'fallback-without-loader': value['loaderFailures'] = 0
            elif mutation == 'callback-order': value['events'][1]['wallTime'] = value['events'][2]['wallTime'] + 1
            elif mutation == 'source': final['sources'].pop(MAP_SOURCES[2])
            elif mutation == 'asset': value = bad['probes'][1]['semantic']; value['tileReplySHA256'] = '0' * 64
            elif mutation == 'location': value['showsUserLocation'] = True
            elif mutation == 'offline-claim': final['networkBoundary'] = {'NetworkDisabled': True}
            elif mutation == 'missing-png': value.pop('nativeButtonImage')
            elif mutation == 'segment-deadline': final['segments'][0]['seconds'] = 4.01
            else: final['cleanup']['providerReleased'] = False
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                validate_map(bad, 'map-attribution')

    def test_owned_input_is_generated_decodable_png_and_bundled_bytes_are_sealed(self):
        path = ROOT / MAP_TILE_SOURCE
        generator = runpy.run_path(str(ROOT / 'telegram-ios/Tests/ExteralessHarness/Tools/map_tile_fixture.py'))
        data = path.read_bytes()
        self.assertEqual(data, generator['tile_png']())
        self.assertLess(len(data), 16384)
        self.assertEqual(struct.unpack('>II', data[16:24]), (256, 256))
        offset, compressed = 8, b''
        while offset < len(data):
            size = struct.unpack('>I', data[offset:offset+4])[0]
            kind, payload = data[offset+4:offset+8], data[offset+8:offset+8+size]
            self.assertEqual(binascii.crc32(kind + payload) & 0xffffffff, struct.unpack('>I', data[offset+8+size:offset+12+size])[0])
            if kind == b'IDAT': compressed += payload
            offset += 12 + size
        raw = zlib.decompress(compressed)
        self.assertEqual(len(raw), 256 * (256 * 3 + 1))
        state, _ = self.fixture()
        for corrupt in (False, True):
            archive_bytes = io.BytesIO()
            with zipfile.ZipFile(archive_bytes, 'w') as archive:
                archive.writestr('app/client-ui-domain-sources.json', json.dumps(state['facts']['domainSources']))
                archive.writestr('app/map-attribution-grid.png', data[:-1] + b'x' if corrupt else data)
            with zipfile.ZipFile(archive_bytes) as archive:
                if corrupt:
                    with self.assertRaisesRegex(ValueError, 'Bundled Map tile differs'):
                        manifest_from_ipa(archive, 'app', MAP_SCENARIOS)
                else:
                    manifest_from_ipa(archive, 'app', MAP_SCENARIOS)

    def test_source_graph_covers_actual_provider_owner_factory_and_fixture_input(self):
        fixture = ROOT / 'telegram-ios/submodules/LocationUI/Sources/Tests/ExteralessMapAttributionFixture.swift'
        text = fixture.read_text(encoding='utf-8')
        block = re.search(r'public static let requiredSources = \[(.*?)\n    \]', text, re.S)[1]
        self.assertEqual(tuple(re.findall(r'"([^"]+)"', block)), MAP_SOURCES)
        route = json.loads((ROOT / 'docs/wave-2/map-attribution-owned-route.json').read_text(encoding='utf-8'))
        self.assertEqual(tuple(route['required_source_pins']), MAP_SOURCES)
        self.assertEqual(route['approved_network_boundary'], MAP_BOUNDARY)
        self.assertEqual(route['tile_input']['sha256'], hashlib.sha256((ROOT / MAP_TILE_SOURCE).read_bytes()).hexdigest())
        manifest = harness_inputs(ROOT / 'telegram-ios', source_checkout=True)['domain_sources']
        self.assertTrue(set(MAP_SOURCES) <= manifest['files'].keys())
        for name in MAP_SOURCES:
            self.assertEqual(manifest['files'][name], hashlib.sha256((ROOT / name).read_bytes()).hexdigest())

    def test_native_button_pngs_and_callback_pts_handles_cannot_be_dropped_or_replaced(self):
        state, images = self.fixture()
        timing = {'recordCommandHostWallTime': 99, 'recordStartedObservedHostWallTime': 99.05}
        info = {'frames': [{'pts_time': str(index / 10)} for index in range(91)]}
        info['frames'].insert(25, {'pts_time': '2.4'})  # Preserve duplicate PTS and decoder order.
        handles = recorded_frame_index(state, timing, info)
        self.assertEqual(handles['frames'][24]['pts'], handles['frames'][25]['pts'])
        with tempfile.TemporaryDirectory(prefix='map-evidence-') as temporary:
            folder = Path(temporary)
            for name, data in images.items():
                path = folder / name; path.parent.mkdir(exist_ok=True); path.write_bytes(data)
            (folder / 'state.json').write_text(json.dumps(state), encoding='utf-8')
            (folder / 'frame-handles.json').write_text(json.dumps(handles), encoding='utf-8')
            self.assertEqual(map_recording_evidence(folder, state, handles)['nativePNGCount'], 13)
            broken = copy.deepcopy(handles)
            broken['probes'][1].pop('nativeButtonImage')
            with self.assertRaisesRegex(ValueError, 'native PNG/recorded PTS'):
                map_recording_evidence(folder, state, broken)
            name = state['probes'][1]['semantic']['nativeButtonImage']
            (folder / name).write_bytes(images[name][:-1] + b'x')
            with self.assertRaisesRegex(ValueError, 'PNG byte/geometry'):
                map_recording_evidence(folder, state, handles)


if __name__ == '__main__':
    unittest.main()
