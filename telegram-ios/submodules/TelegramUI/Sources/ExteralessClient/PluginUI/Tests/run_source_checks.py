"""Bounded integration/source checks; does not execute plugins or contact CI.

Checks real composition/menu callsites and the existing module dependency graph.
These complement, and do not replace, the Swift fixture and UIKit frame checks.
"""

import ast
import hashlib
import json
from pathlib import Path
import re
import time


HERE = Path(__file__).resolve()
TG = HERE.parents[6]
REPO = TG.parent
UI = TG / "submodules/TelegramUI/Sources"
DEADLINE = time.monotonic() + 20


def read(path):
    if time.monotonic() >= DEADLINE:
        raise AssertionError("Native source checks exceeded their 20-second deadline")
    return path.read_text(encoding="utf-8")


def function(source, marker):
    start = source.index(marker)
    # This check uses only declaration boundaries; nested bodies remain included.
    next_decl = re.search(r"\n    (?:@\w+ )?(?:public |private |internal )?func ", source[start + len(marker):])
    return source[start:] if next_decl is None else source[start:start + len(marker) + next_decl.start()]


def strings(node, assignments, seen=()):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return [node.value]
    if isinstance(node, ast.Name) and node.id in assignments and node.id not in seen:
        return strings(assignments[node.id], assignments, (*seen, node.id))
    if isinstance(node, ast.Dict):
        return [s for value in node.values for s in strings(value, assignments, seen)]
    return [s for child in ast.iter_child_nodes(node) for s in strings(child, assignments, seen)]


def deps(label):
    package, _, target = label[2:].partition(":")
    target = target or package.rsplit("/", 1)[-1]
    build = TG / package / "BUILD"
    if not build.exists():
        build = TG / package / "BUILD.bazel"
    if not build.exists():
        return []  # External/generated leaf; this change adds no BUILD edges.
    tree = ast.parse(read(build), filename=str(build))
    assignments = {name.id: statement.value for statement in tree.body if isinstance(statement, ast.Assign)
                   for name in statement.targets if isinstance(name, ast.Name)}
    calls = [statement.value for statement in tree.body if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call)]
    matches = [call for call in calls if any(key.arg == "name" and isinstance(key.value, ast.Constant)
                                           and key.value.value == target for key in call.keywords)]
    # A macro-generated target inherits its package's declared production deps.
    if not matches:
        matches = [call for call in calls if not any(key.arg == "name" and isinstance(key.value, ast.Constant)
                   and "test" in str(key.value.value).lower() for key in call.keywords)]
    return sorted({value for call in matches for key in call.keywords if key.arg == "deps"
                   for value in strings(key.value, assignments) if value.startswith("//submodules/")})


def main():
    registry = read(TG / "submodules/ContextUI/Sources/ExteralessPluginMenuEntry.swift")
    assert "//submodules/AccountContext:AccountContext" in deps("//submodules/ContextUI:ContextUI")
    pending = [("//submodules/AccountContext:AccountContext", ())]
    visited = set()
    while pending:
        label, path = pending.pop()
        if label in visited:
            continue
        assert not label.startswith("//submodules/ContextUI"), ("AccountContext -> ContextUI cycle", path + (label,))
        visited.add(label)
        assert len(visited) <= 1000, "Dependency traversal exceeded its explicit bound"
        pending += [(dependency, path + (label,)) for dependency in deps(label)]
    assert "import TelegramUI" not in registry
    assert "combineLatest(items, changes)" in registry and "var result = original" in registry
    assert "NotificationCenter.default.removeObserver(observer)" in registry

    runtime = read(UI / "Exteraless/ExteralessPluginRuntime.swift")
    composition = function(runtime, "public func start()")
    for text in ("let ui = PluginUIBridgeExtension(", "let tl = PluginTLBridgeExtension(",
                 "ClientSettingsBridgeExtension", "ExteralessPluginMenuEntry.setFactory", "uiGate.bind(ui)",
                 "PluginNativeServicesBridgeExtension(", "NativeServiceOpenHooks.shared.install(provider: native)",
                 "let pills = try PluginPillBridgeExtension("):
        assert composition.index(text) < composition.index("try await host.start("), text
    for provider in ("PluginUIBridgeExtension(", "PluginTLBridgeExtension(", "PluginNativeServicesBridgeExtension(", "PluginPillBridgeExtension("):
        assert composition.count(provider) == 1, ("Provider constructed more than once", provider)
    assert "tl, native, pills," in composition
    assert "publisherSites: [.committedMessages, .mediaFetch]" in composition
    incoming = read(TG / "submodules/TelegramCore/Sources/State/AccountStateManager.swift")
    assert incoming.count("nativeServicePublishCommittedMessages(") == 1
    committed = incoming.index("nativeServicePublishCommittedMessages(")
    assert "messageIds: events.addedIncomingMessageIds" in incoming[committed:committed + 220]
    assert committed < incoming.index("var messageList:", committed)
    outgoing = read(TG / "submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift")
    assert outgoing.count("nativeServicePublishEnqueuedMessages(") == 1
    assert "return (.committed(messageIds: resultIds), ephemeralMessageIds)" in outgoing
    assert "return nativeServicePublishEnqueuedMessages(account: account, messageIds: result.messageIds) |> map { _ in result }" in outgoing
    fetch = read(TG / "submodules/TelegramCore/Sources/Network/FetchedMediaResource.swift")
    assert fetch.count("nativeServiceTrackMediaFetch(") == 1 and "signal: nativeServiceOriginalFetch()" in fetch
    assert 'appendingPathComponent("exteraless/pills/plugin-identities.json")' in composition
    assert composition.index("recoverBeforeStart(host: host, settingsDirectory: settingsDirectory)") < composition.index("try await host.start(")
    assert "services.serviceStorage.settingsDirectoryURL()" in composition
    assert re.search(r"CompositePluginBridgeExtension\(\[\s*ui,.*ClientSettingsBridgeExtension.*tl,", composition, re.S)
    assert "shouldExecute: { uiGate.permits" in composition and "guaranteed: PluginUICallbackGate.isTerminal" in composition
    assert "host.bridge.onOwnedCallback" in composition and "owner.wireToken == ownerToken" in composition
    owned = composition[composition.index("host.bridge.onOwnedCallback"):]
    assert owned.index("owner.wireToken == ownerToken") < owned.index("Task { @MainActor") < owned.index("return true")
    assert "else { return false }" in owned and "host.bridge.onCallback = {" not in composition
    assert "PluginTLObservationCodec.jsonString(event)" in runtime
    assert "PluginTLObservationCodec.hookName(value.metadata.requestName)" in runtime
    assert "tlTransforms = PluginTLTransformIntegration(host: host" in runtime
    assert function(runtime, "private func refreshSubscriptions()").index("tlTransforms?.updateSubscriptions") < function(runtime, "private func refreshSubscriptions()").index("guard let registration")
    terminate = function(runtime, "public func terminate()")
    assert terminate.index("tlTransforms?.detach()") < terminate.index("await host.stop()")
    toggle = function(runtime, "public func setEnabled(")
    assert "ToolsToggleTraceBuffer.shared.record" in toggle and "defer {" in toggle
    assert toggle.index("loadError") < toggle.index("succeeded = true")
    assert "pluginUI?.clearContext()" in function(runtime, "public func clearContext()")
    for retained in ("tlServices", "nativeServices", "pillServices", "pluginUI"):
        assert retained + "?.update(context: context)" in function(runtime, "public func update(")
        assert retained + "?.clearContext()" in function(runtime, "public func clearContext()")
        assert retained + "?.clearContext()" in terminate

    mode = function(runtime, "private func setRuntimeMode(")
    assert "beginSettingsMaintenance(timeout: 10)" in mode and "lease.finish(resume: resume)" in mode
    assert "host.stop(" not in mode and "host.start(" not in mode
    assert "store.apply(change)" in mode and 'status = "Runtime mode failed:' in mode
    assert "toolsRecoveryRequired" in function(runtime, "private func requirePluginExecution()")
    maintenance = function(runtime, "public func beginManagerAwareSettingsMaintenance(")
    assert maintenance.index("settingsMaintenanceID = id") < maintenance.index("await startup.value")
    assert "activeOperations == 0" in maintenance and "frozenSettingsLocation = try liveSettingsLocation()" in maintenance
    assert "recovered && pluginExecutionRequested && !terminating" in runtime
    settings_read = function(runtime, "public func settings(")
    captured_owner = re.search(r"let owner = (?:capturedHost\.callbackOwner\(id: id\)|read\.owner)", settings_read)
    assert captured_owner and captured_owner.start() < settings_read.index("await operationHost()")
    assert settings_read.index("await host.settingsJSON") < settings_read.index("settingsSchemaCache.record")
    assert "self.currentContext === context" in settings_read and "host.callbackOwner(id: id) == owner" in settings_read
    assert "liveSettingsLocation()" in function(runtime, "public func toolsBackupBindings(")

    message = read(UI / "Chat/ChatControllerOpenMessageContextMenu.swift")
    assert "self.exteralessAIContextItems(message: message)" in message
    wrap = message.index("actionsSignal = ExteralessPluginMenuEntry.updating")
    assert message.index("actionsSignal = .single(actions)") < wrap < message.index("items: actionsSignal, recognizer:")
    assert 'placement: "MESSAGE_CONTEXT_MENU"' in message
    peer = read(UI / "Chat/ChatControllerOpenPeer.swift")
    more = function(peer, "func openBotForumMoreMenu(")
    assert "ExteralessPluginMenuEntry.updating(" in more and "items: pluginItems" in more
    assert 'placement: "CHAT_ACTION_MENU"' in more

    bridge = read(UI / "ExteralessClient/PluginUI/PluginUIBridgeExtension.swift")
    request = read(UI / "ExteralessClient/PluginUI/PluginUIRequest.swift")
    assert "public let exportedMethods:" in bridge and "PluginUIRequest.members" in bridge
    members = set(re.findall(r'"([A-Za-z]+)"', request[request.index("static let members:"):request.index("static func claimed")]))
    handled = set(re.findall(r'"([A-Za-z]+)"', function(bridge, "private func call(") + function(bridge, "public func dispatch(")))
    assert members <= handled, ("Advertised unimplemented UI members", members - handled)
    assert '"ownerToken"' in request and '"value"' in request
    assert "PluginUIRequestOrigin(request)" in bridge and "current?.wireToken" in bridge
    assert "admission: { try self.validateOrigin(origin, owner: owner, execution: execution) }" in bridge
    assert bridge.count("admission: { try self.validateNewLease(origin, owner: acceptedOwner, execution: execution) }") == 3
    assert "self.owner(pluginId)" not in bridge
    cleanup_admission = function(bridge, "private func cleanup(")
    assert "origin.validate(currentToken: owner.wireToken)" in cleanup_admission
    assert "self.captureOwner" not in cleanup_admission and "self.validateOrigin" not in cleanup_admission
    assert "return self.callback(delivery.owner" in bridge
    assert "[Int64]) -> Bool" in bridge
    assert "self.releaseQueue.retire(retirement)" in bridge
    cleanup = read(UI / "ExteralessClient/PluginUI/PluginUIReleaseQueue.swift")
    assert "guard self.callback(retirement.deliveries[batch.nextDelivery])" in cleanup
    assert cleanup.index("batch.nextDelivery += 1") < cleanup.index("self.release(owner, retirement.handles)")
    assert "guard admitted else" in cleanup and "self.scheduleRetry()" in cleanup
    lifecycle = read(UI / "ExteralessClient/PluginUI/PluginUILifecycle.swift")
    assert "remaining.count + retiringCount" in lifecycle and "func completeRetirement" in lifecycle
    assert "Owner callback cleanup is awaiting FIFO admission" in lifecycle
    assert 'reason: "accountChanged", notify: false' in lifecycle and "closedOnly" not in lifecycle
    assert bridge.count("NativeServiceOpenHooks.shared.interceptURL") == 2
    assert "self.canAct(id: id, revision: revision)" in function(bridge, "private func openLink(")

    settings = read(UI / "Exteraless/PluginSettingsController.swift")
    assert "PluginUISettingsRefresh.observe" in settings and "pendingExternalReload" in settings
    assert "externalReloadScheduled" in settings and "self.scopeIsCurrent()" in settings
    assert "PluginUISettingsRowIcon.apply" in settings
    assert "loadPluginSettings(actions: actions, id: id, scope: scope, read: read)" in settings
    assert "public func exteralessPluginSettingsController(" in settings

    manager = read(UI / "Exteraless/PluginManagerController.swift")
    assert 'id: "ai-review"' in manager and "ExteralessAIEntry.reviewPlugin?" in manager
    assert "presentation.precedes" in manager and "compactView == true" in manager
    assert "controls.pin" in manager and "controls.muteWarning" in manager and "controls.reload" in manager
    assert "scopeIsCurrent: self.actions.settingsScope?(id)" in manager
    assert "public let settingsScope:" in manager
    developer = read(UI / "ExteralessClient/PluginUI/PluginDeveloperServer.swift")
    assert 'NWEndpoint.Host("127.0.0.1")' in developer and "requiredLocalEndpoint" in developer
    assert "case .ready:" in developer and "connections.count < 4" in developer
    assert "self.currentSession?.cancel()" in developer and "session.isActive" in developer
    assert "host.readPluginMetadata(sourceURL: file)" in runtime and "metadata.id == upload.pluginId" in runtime
    assert "host.installPlugin(sourceURL: file, metadata: metadata)" in runtime

    inventory_path = REPO / "docs/parity/client-features.json"
    inventory = json.loads(read(inventory_path))
    fragment = json.loads(read(REPO / "docs/wave-2/runtime-parity.json"))
    assignment = json.loads(read(REPO / "docs/parity/remaining-ownership.json"))
    expected = next(value["feature_ids"] for value in assignment["unfragmented_packages"] if value["id"] == "R-runtime")
    inventory_container_matches = fragment["source_inventory_sha256"] == hashlib.sha256(inventory_path.read_bytes()).hexdigest()
    assert [feature["id"] for feature in fragment["features"]] == expected and len(expected) == 16
    originals = {feature["id"]: feature for feature in inventory["features"]}
    for feature in fragment["features"]:
        original = originals[feature["id"]]
        assert feature["kind"] == original["kind"] and feature["implementation"]["ported"] is False
        for key in ("symbol", "file", "line", "type", "default", "behavior", "references"):
            assert feature["android"][key] == original["android"].get(key, {}), (feature["id"], key)
        for site in feature["ios"]["implementation_callsites"]:
            assert site["symbol"] in read(REPO / site["path"]), site

    owned_files = list((UI / "ExteralessClient/PluginUI").glob("*.swift")) + [
        UI / "Exteraless/ExteralessPluginRuntime.swift", UI / "Exteraless/PluginSettingsController.swift",
        UI / "Exteraless/PluginManagerController.swift",
        TG / "submodules/ContextUI/Sources/ExteralessPluginMenuEntry.swift"]
    for path in owned_files:
        source = read(path)
        assert not re.search(r"^\s*import\s+(Postbox|TelegramApi)\b", source, re.M), path
        assert ".postbox" not in source, path
        assert "PyGILState_Ensure" not in source and "UnsafePointer" not in source, path
    print(f"PluginUI native source checks passed: {len(visited)} dependency targets; four providers, C epoch/FIFO, modes/Tools, live menu hooks, scoped refresh, 16 original runtime IDs.")
    if not inventory_container_matches:
        print("Inventory container changed since the historical receipt; all 16 R-runtime kinds/defaults/source references still match exactly.")
    print("UIKit compilation/frames and Swift fixture execution remain separate checks.")


if __name__ == "__main__":
    main()
