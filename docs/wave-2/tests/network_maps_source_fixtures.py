"""Bounded, local-only source/receipt checks; NOT a Swift execution substitute.

Run: python docs/wave-2/tests/network_maps_source_fixtures.py
Reads original and applied source, validating only reserved patch anchors in memory.
"""
from pathlib import Path
import hashlib
import json
import re
import struct
import unittest

ROOT = Path(__file__).resolve().parents[3]
CORE = ROOT / "swift/ExteralessCore/Sources/ExteralessCore"
ANDROID = ROOT / "third_party/exteraless-android/TMessagesProj/src/main"
HANDOFF = ROOT / "docs/wave-2"


def patch_sections(path):
    target = None
    old, new = [], []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("*** Update File:") or line.startswith("@@") or line == "*** End Patch":
            if old or new:
                yield target, "\n".join(old) + "\n", "\n".join(new) + "\n"
            old, new = [], []
        if line.startswith("*** Update File:"):
            target = line.removeprefix("*** Update File: ")
        elif line.startswith(" "):
            old.append(line[1:]); new.append(line[1:])
        elif line.startswith("-"):
            old.append(line[1:])
        elif line.startswith("+"):
            new.append(line[1:])


class NetworkMapsSourceFixtures(unittest.TestCase):
    def test_applied_source_pins_use_inventory_raw_byte_contract(self):
        pins = json.loads((HANDOFF / "network-maps-native-pins.json").read_text(encoding="utf-8"))
        for name, pin in pins["files"].items():
            raw = (ROOT / name).read_bytes()
            self.assertEqual(len(raw), pin["bytes"], name)
            self.assertEqual(hashlib.sha256(raw).hexdigest(), pin["sha256"], name)

    def test_exact_six_ids_join_original_inventory(self):
        ownership = json.loads((ROOT / "docs/parity/remaining-ownership.json").read_text(encoding="utf-8"))
        expected = {i for p in ownership["unfragmented_packages"] if p["id"] in {"P-network-resolver", "P-maps"} for i in p["feature_ids"]}
        fragment = json.loads((HANDOFF / "network-maps-parity.json").read_text(encoding="utf-8"))
        self.assertEqual(len(fragment["features"]), 6)
        self.assertEqual({f["id"] for f in fragment["features"]}, expected)
        for feature in fragment["features"]:
            self.assertFalse(feature["implementation"]["ported"])
            self.assertTrue(feature["android_evidence"]["consumers"])
            self.assertTrue(feature["ios"]["implementation_callsites"])
            for point in feature["ios"]["implementation_callsites"]:
                self.assertTrue((ROOT / point["path"]).is_file(), point)

    def test_original_url_pins_ids_and_actual_kotlin_search(self):
        original = (ANDROID / "java/tw/nekomimi/nekogram/utils/DnsFactory.kt").read_text(encoding="utf-8")
        block = original.split("DEFAULT_DOH_PROVIDERS = arrayOf(", 1)[1].split("\n    )", 1)[0]
        pins = re.findall(r'"(https://[^"\n]+)"', block)
        self.assertEqual(len(pins), 6)
        native = (CORE / "NetworkResolverPolicy.swift").read_text(encoding="utf-8")
        for pin in pins:
            self.assertIn('"' + pin + '"', native)
        config = (ANDROID / "java/tw/nekomimi/nekogram/NekoConfig.java").read_text(encoding="utf-8")
        for symbol, value in [("DEFAULT", 0), ("NAX", 1), ("SYSTEM", 2), ("CUSTOM_DOH", 3)]:
            self.assertRegex(config, rf"DNS_TYPE_{symbol}\s*=\s*{value};")
        symbols = re.compile(r"\b(dnsType|customDoH|useIPv6|mapDriftingFixForGoogleMaps|mapPreviewProvider|useOSMDroidMap)\b")
        matches = [str(path.relative_to(ANDROID)) for path in (ANDROID / "kotlin").rglob("*.kt") if symbols.search(path.read_text(encoding="utf-8"))]
        self.assertEqual(matches, [])

    def test_pending_hunks_match_unique_current_contexts_without_writes(self):
        virtual = {}
        for name in ["network-maps-integration.patch", "network-maps-network-hunk.patch"]:
            for target, old, new in patch_sections(HANDOFF / name):
                text = virtual.get(target)
                if text is None:
                    text = (ROOT / target).read_text(encoding="utf-8")
                self.assertEqual(text.count(old), 1, f"{name}: ambiguous/missing context in {target}: {old[:150]!r}")
                virtual[target] = text.replace(old, new, 1)
        self.assertEqual(set(virtual), {
            "telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift",
        })
        network = virtual["telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift"]
        self.assertIn("ExteralessNetworkResolverRuntime.shared.makeConnection", network)
        self.assertIn("ExteralessNetworkBackupDNS.backupSignal", network)

    def test_applied_native_and_rust_connection_paths_and_byte_counts(self):
        native = ROOT / "telegram-ios/submodules/MtProtoKit"
        tcp = (native / "Sources/MTTcpConnection.m").read_text(encoding="utf-8")
        self.assertIn("isHostname && !interfaceResolvesHostnames", tcp)
        self.assertIn("- (bool)resolvesHostnames;", (native / "PublicHeaders/MtProtoKit/MTContext.h").read_text(encoding="utf-8"))
        dns_section = tcp.split("NSString *addressIp = _scheme.address.ip;", 1)[1].split("__weak MTTcpConnection", 1)[0]
        web_branch = dns_section.split("if (_isWebProxy)", 1)[1].split("else if (_socksIp", 1)[0]
        self.assertNotRegex(web_branch, r"(?m)^\s*resolveSignal\s*=")
        backup = (native / "Sources/MTBackupAddressSignals.m").read_text(encoding="utf-8")
        self.assertIn("primarySource ?: [self fetchBackupIpsResolveGoogle", backup)
        self.assertIn("familyPreference", (native / "Sources/MTContext.m").read_text(encoding="utf-8"))
        self.assertIn("then:firstTcp6Match", (native / "Sources/MTDiscoverConnectionSignals.m").read_text(encoding="utf-8"))

        rust = ROOT / "telegram-ios/third-party/mtproto-engine/crates/mtproto-engine/src"
        resolver = (rust / "resolver.rs").read_text(encoding="utf-8")
        worker = (rust / "worker.rs").read_text(encoding="utf-8")
        session = (rust / "session_runtime.rs").read_text(encoding="utf-8")
        self.assertIn("MTAppNetworkResolve(", resolver)
        self.assertIn("count as usize > output.len()", resolver)
        self.assertIn("pending.epoch == epoch && pending.id == lookup_id", worker)
        self.assertIn("pending.cancelled.store(true, Ordering::Release)", worker)
        self.assertIn("on_resolved_until", worker)
        self.assertIn("cache_expires_at", worker)
        self.assertNotIn("crate::resolver::cache_lifetime(", session, "Native Swift cache reads must stay off the reactor")
        self.assertIn("MAX_DNS_CACHE: usize = 128", session)
        self.assertIn("app_resolver_zero_ttl_is_one_use_for_tcp_and_http", session)
        self.assertIn("app_resolver_epoch_discards_cache_but_wakes_matching_waiter", session)
        stream = (ROOT / "telegram-ios/submodules/MTProtoRustEngine/Sources/MTProtoRustEngine/RustStreamHost.swift").read_text(encoding="utf-8")
        self.assertIn("ExteralessResolverTLSConnector.connect", stream)
        self.assertIn("appConnectorGenerations[stream] == generation", stream)
        self.assertNotIn("complete(true)", stream)
        self.assertNotIn("CFErrorCopyDescription", stream)
        self.assertIn("mt_stream_sent(self.engine, stream, count)", stream)
        self.assertIn("length: bytes.count", stream)
        self.assertIn("sec_protocol_options_set_tls_server_name(security, serverName)", stream)

    def test_applied_map_physical_scopes_and_actions(self):
        bubble = (ROOT / "telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageMapBubbleContentNode/Sources/ChatMessageMapBubbleContentNode.swift").read_text(encoding="utf-8")
        article = (ROOT / "telegram-ios/submodules/InstantPageUI/Sources/InstantPageImageNode.swift").read_text(encoding="utf-8")
        navigation = (ROOT / "telegram-ios/submodules/OpenInExternalAppUI/Sources/OpenInOptions.swift").read_text(encoding="utf-8")
        self.assertIn("Namespaces.Peer.SecretChat ? .secretChat : .cloudMessage", bubble)
        self.assertIn("scope: .instantPage", article)
        self.assertIn("exteralessGoogleMapCoordinate(latitude: lat, longitude: lon)", navigation)
        self.assertIn("exteralessOpenStreetMapOption(latitude: lat, longitude: lon)", navigation)
        for source in [bubble, article, navigation]:
            self.assertNotIn("import Postbox", source)
        resources = (ROOT / "telegram-ios/submodules/LocationResources/Sources/MapResources.swift").read_text(encoding="utf-8")
        self.assertIn("exteralessMapSnapshotData(accountId: engine.account.id.int64", resources)
        node = (ROOT / "telegram-ios/submodules/LocationUI/Sources/LocationMapNode.swift").read_text(encoding="utf-8")
        self.assertIn("ExteralessLocationMapProvider(mapView: mapView)", node)
        self.assertIn("MKTileOverlayRenderer(tileOverlay: tiles)", node)

    def test_invalid_custom_startup_never_silently_selects_public_dns(self):
        core = (CORE / "NetworkResolver.swift").read_text(encoding="utf-8")
        policy = (CORE / "NetworkResolverPolicy.swift").read_text(encoding="utf-8")
        native = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessNetwork"
        runtime = (native / "ExteralessNetworkResolverRuntime.swift").read_text(encoding="utf-8")
        backup = (native / "ExteralessNetworkBackupDNS.swift").read_text(encoding="utf-8")
        self.assertIn("public func rejectConfiguration", core)
        self.assertIn("if let error = self.blockedConfiguration", core)
        self.assertIn("if !hasValidConfiguration", runtime)
        self.assertIn("resolver.rejectConfiguration", runtime)
        self.assertIn("snapshot.lastError == nil", policy)
        self.assertIn('settings.value("network.customDoH")', policy)
        self.assertIn("state.blockedConfiguration == nil else { return MTSignal.complete() }", backup)
        self.assertIn("testRejectedInitialCustomConfigurationDoesNotFallBackToPublicDNS", (ROOT / "swift/ExteralessCore/Tests/ExteralessCoreTests/NetworkResolverLifecycleTests.swift").read_text(encoding="utf-8"))

    def test_applied_passive_rtt_uses_matched_event_and_real_wrappers(self):
        rust = ROOT / "telegram-ios/submodules/MTProtoRustEngine/Sources/MTProtoRustEngine"
        ffi = (ROOT / "telegram-ios/third-party/mtproto-engine/crates/mtproto-ffi/src/lib.rs").read_text(encoding="utf-8")
        self.assertIn("let mut event = blank(17);", ffi)
        self.assertIn("event.value1 = rtt;", ffi)
        session = (rust / "RustNetworkSession.swift").read_text(encoding="utf-8")
        projection = (rust / "RustPassivePingState.swift").read_text(encoding="utf-8")
        self.assertIn("RustEngineEventHandler, ExteralessPillPassivePingSource", session)
        pong_branch = session.split("case .pong:", 1)[1].split("case .connectionState:", 1)[0]
        self.assertIn("exteralessPassivePing.consume(event", pong_branch)
        self.assertIn("receivedAt: Date()", pong_branch)
        self.assertIn("roundTripSeconds: event.value1, sampledAt: receivedAt", projection)
        self.assertIn("if paused { self.exteralessPassivePing.invalidate() }", session)
        self.assertIn("self.lastConnectionFlags.map(rustEngineHasAnsweredConnection) == true", session)
        for name in ["RecordingNetworkEngine.swift", "SwitchingNetworkEngine.swift"]:
            source = (ROOT / "telegram-ios/submodules/TelegramCore/Sources/Network" / name).read_text(encoding="utf-8")
            self.assertIn("NetworkEngineSession, ExteralessPillPassivePingSource", source)
            self.assertIn("source.exteralessPillPassivePingSnapshot", source)
            self.assertIn("ticket.complete", source)
        switching = (ROOT / "telegram-ios/submodules/TelegramCore/Sources/Network/SwitchingNetworkEngine.swift").read_text(encoding="utf-8")
        self.assertIn("self.state.pointee.generation == generation", switching)
        self.assertIn("self.state.pointee.passivePingEpoch == epoch", switching)
        events = (ROOT / "telegram-ios/submodules/MTProtoRustEngine/Tests/MTProtoRustEngineTests/RustPassivePingEventTests.swift").read_text(encoding="utf-8")
        wrappers = (ROOT / "telegram-ios/submodules/TelegramCore/Tests/ExteralessPassivePingForwardingTests.swift").read_text(encoding="utf-8")
        self.assertIn("var raw = MTEvent()", events)
        self.assertIn("RustEngineEvent($0)", events)
        self.assertIn("testRecordingOverSwitchingDiscardsLateOldEngineReply", wrappers)
        self.assertIn("directory: nil", wrappers)

    def test_native_boundaries_secrets_and_no_global_dns_or_permission_api(self):
        network = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessNetwork"
        for path in network.glob("*.swift"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("import UIKit", text, str(path))
            self.assertNotIn("import Python", text, str(path))
            self.assertNotIn("set_verify_block", text, str(path))
        for folder in ["Network", "Maps"]:
            for path in (ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient" / folder).glob("*.swift"):
                self.assertNotIn("import Postbox", path.read_text(encoding="utf-8"), str(path))
        for file in ["CoreNetworkFeatures.swift", "MapPolicy.swift"]:
            text = (CORE / file).read_text(encoding="utf-8")
            self.assertIn("isSecret: true", text)
            self.assertNotIn("NEDNSSettingsManager", text)
        tests = ROOT / "swift/ExteralessCore/Tests/ExteralessCoreTests/NetworkResolverHTTPTests.swift"
        self.assertIn("canInit(with request: URLRequest) -> Bool { true }", tests.read_text(encoding="utf-8"))

    def test_independent_dns_fixtures_are_well_formed_binary_literals(self):
        tests = (ROOT / "swift/ExteralessCore/Tests/ExteralessCoreTests/NetworkResolverWireTests.swift").read_text(encoding="utf-8")
        packets = [bytes.fromhex(value) for value in re.findall(r'networkMapHex\("([0-9a-f]+)"\)', tests)]
        self.assertGreaterEqual(len(packets), 8)
        a = packets[0]
        self.assertEqual(struct.unpack("!6H", a[:12]), (0x1234, 0x8180, 1, 1, 0, 0))
        self.assertEqual(a[-4:], bytes([203, 0, 113, 7]))
        self.assertEqual(len(packets[1][-16:]), 16)
        self.assertEqual(packets[1][-16:], bytes.fromhex("20010db8000000000000000000000007"))

    def test_source_coordinate_constants_and_scope_are_not_blanket_transforms(self):
        original = (ANDROID / "java/tw/nekomimi/nekogram/location/GeodeticTransform.java").read_text(encoding="utf-8")
        native = (CORE / "MapPolicy.swift").read_text(encoding="utf-8")
        for value in ["6378245.0", "0.00669342162296594323", "72.004", "137.8347", "0.8293", "55.8271"]:
            self.assertIn(value, original); self.assertIn(value, native)
        self.assertIn("coordinate.datum == .wgs84", native)
        self.assertIn("correctGoogleCoordinates, !useOpenStreetMap", native)
        self.assertIn("scope == .cloudMessage || scope == .instantPage", native)
        self.assertNotIn("bd09", native.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
