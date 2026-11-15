"""Check the applied HNS follow-up postimage, not historical patch preimages.

Shared Runtime/harness files are checked by scoped source regions. No native
execution, review-pass claim, file mutation, network or account work occurs.
"""

import ast
from pathlib import Path
import re
import time

from plugin_ui_postimage import HARNESS, RUNTIME, region_text, verify_postimage


UI = Path(__file__).resolve().parent.parent
REPO = UI.parents[5]
DEADLINE = time.monotonic() + 20


def read(path):
    assert time.monotonic() < DEADLINE, "HNS source preflight exceeded 20 seconds"
    return Path(path).read_text(encoding="utf-8")


def body(source, marker):
    start = source.index(marker)
    next_method = re.search(r"\n    (?:@\w+ )?(?:(?:public|private|internal|static|override) )*func ", source[start + len(marker):])
    return source[start:] if next_method is None else source[start:start + len(marker) + next_method.start()]


def main():
    postimage = verify_postimage(REPO)
    runtime = read(REPO / RUNTIME)
    harness = read(REPO / HARNESS)
    bridge = read(UI / "PluginUIBridgeExtension.swift")
    lifecycle = read(UI / "PluginUILifecycle.swift")
    controller = read(UI.parent.parent / "Exteraless/PluginSettingsController.swift")
    authority = read(UI / "PluginUISettingsActionAuthority.swift")
    execution = read(UI / "PluginUISettingsActionInvocation.swift")
    gate = read(UI / "PluginUISettingsActionGate.swift")
    effects = read(UI / "PluginUIRetainedEffect.swift")
    reads = read(UI / "PluginUISettingsReadInvocation.swift")
    fixture = read(UI / "Tests/PluginUIRemediationFixture.swift")
    schema = read(UI / "PluginUIUnprovenSchemaCache.swift")

    # HNS-02: cleanup is dispatched before active-owner acquisition and only the
    # stored owner is used to authorize the store's locked revocation operation.
    dispatch = body(bridge, "public func dispatch(")
    assert dispatch.index("self.cleanup(") < dispatch.index("self.owner(pluginId, origin: origin)")
    assert dispatch.index("self.cleanup(") < dispatch.index("PluginNativeCallLease")
    cleanup = body(bridge, "private func cleanup(")
    assert "self.leases.revoke" in cleanup and "origin.validate(currentToken: owner.wireToken)" in cleanup
    assert "captureOwner" not in cleanup and "requireOwner" not in cleanup and "validateOrigin" not in cleanup
    revoke = body(lifecycle, "func revoke(")
    assert "self.locked" in revoke and "try validateOwner(entry.owner)" in revoke
    assert revoke.index("try validateOwner(entry.owner)") < revoke.index('entry.state.phase = .dismissing')
    assert "historyOwners" in revoke and "self.retiring[id]" in revoke

    # HNS-05: synchronous aggregate reservation, retained through both native URL
    # barrier ownership and UIApplication completion. Revocation never refunds it.
    effects_route = body(bridge, "private func call(").split('case "addToClipboard", "openURL":', 1)[1]
    assert effects_route.index("self.retainedEffect(") < effects_route.index("DispatchQueue.main.async")
    assert "text.utf8.count + (url?.absoluteString.utf8.count ?? 0)" in effects_route
    assert "completionHandler: { _ in effect.finish() }" in effects_route
    assert "NativeServiceOpenHooks.shared.interceptURL" in effects_route
    assert "PluginNativeEffectBudget.Ticket" in effects and "budget.reserve(pluginId: pluginId, bytes: bytes)" in effects
    assert "effectBudget.cancel" not in bridge and "ticket.cancel" not in effects

    # F01 checks the actual UI consumer, not just Host's common constructor.
    assert effects.index("PluginNativeCallLease(isCurrent: isCurrent)") < effects.index("budget.reserve(")
    assert "self.nativeLease.isCurrent" in effects and "try nativeLease.check()" in effects
    common = read(REPO / "swift/PluginHost/Sources/PluginHost/PluginServiceModels.swift")
    assert "let execution = PluginNativeExecutionContext.captureGuard()" in common
    retained = body(bridge, "private func retainedEffect(")
    assert "execution.isCurrent && self.isCurrent(owner: owner, scope: scope)" in retained
    update_request = body(bridge, "private func call(").split('case "uiUpdate":', 1)[1].split('case "uiState":', 1)[0]
    assert "self.leases.update(" not in update_request and "self.applyUpdate(" in update_request
    assert "PluginUIJSON.object(candidate.raw).encoded().utf8.count" in update_request
    update_commit = body(bridge, "private func applyUpdate(")
    assert update_commit.index("effect.permitsExecution") < update_commit.index("self.leases.update(") < update_commit.index("self.applyLatest(")
    assert "execution: execution" in update_commit and "expectedScope: scope" in update_commit
    present = body(bridge, "private func presentPending(")
    assert "reason: \"executionRevoked\", notify: false" in present
    assert present.count("self.requireNativeEffect(effect)") >= 5
    assert "presentShare(model, entry: entry, presenter: presenter, effect: effect)" in present
    registration = body(bridge, "private func call(").split('case "menuRegister":', 1)[1].split('case "uiActiveFragment":', 1)[0]
    assert "expectedScope: scope" in registration and "validateNewLease(origin, owner: acceptedOwner, execution: execution)" in registration
    assert registration.index("self.leases.registerMenu") < registration.index("self.notifyMenuChanges()")
    assert "try execution.check()" in body(bridge, "private func validateOrigin(")
    batch = body(fixture, "private static func batchConsumer(")
    assert "HNSSettingsEngine(onScript:" in batch and "let effect = try PluginUIRetainedEffect(" in batch
    assert 'case "success":' in batch and "waiting.cancel() // Completing successfully is not revocation" in batch
    assert 'betaGate.wait(timeout: .now() + 3)' in batch and 'outcome == "deferredTimeout"' in batch
    assert "model.title == (outcome == \"success\" ? \"batch\" : \"original\")" in batch

    # HNS-04: UI captures before its Task and Host receives no recaptured owner.
    assert controller.count("invocation = try capturePluginSettingsAction(self.actionScope)") == 4
    assert controller.count("invocation: invocation, mutation:") == 4
    assert controller.count("self.actionScope?.setVisible(false)") == 3
    assert controller.count("self.actionScope?.close()") >= 3
    assert "PluginUISettingsActionExecution.withInvocation(invocation, operation: mutation)" in controller
    mutation = body(controller, "private func mutatePluginSettings(")
    assert mutation.index("guard invocation.isCurrent") < mutation.index("loadPluginSettings(actions:")
    assert "if case .superseded = error { throw error }" in mutation
    assert "@TaskLocal public static var current:" in execution and "onCancel: { invocation.cancel() }" in execution
    worker_guard = body(gate, "fileprivate func permits(")
    assert "self.lock.lock()" in worker_guard
    for forbidden in ("UIKit", "DispatchQueue.main", "MainActor", "AccountContext"):
        assert forbidden not in worker_guard
    update = body(runtime, "public func update(context:")
    assert update.index("prepareContextChange(to: context)") < update.index("services.update(context: context)")
    assert "self.accountGate.clear()" in authority
    for marker in ("public func updateSetting(", "public func click("):
        method = body(runtime, marker)
        assert method.index("PluginUISettingsActionExecution.require(pluginId: id)") < method.index("await operationHost()")
        assert "expectedOwner: invocation.owner, account: invocation.account" in method
        assert "shouldExecute: { invocation.isCurrent }" in method
        assert "callbackOwner(" not in method and "invalidateSettingsSchema(id: id)" in method

    # F02: first appearance can read before controls exist; ordinary publish
    # changes only action revisions and leaves its successful read guard alive.
    assert controller.count("self.actionScope?.beginAppearance()") == 3
    assert controller.count("read = try capturePluginSettingsRead(self.actionScope)") == 2
    assert "let read = try capturePluginSettingsRead(actionScope)" in mutation
    assert "PluginUISettingsReadExecution.withInvocation(read)" in controller
    assert "guard read.isCurrent" in controller and "read: read" in controller
    assert "readRevision" not in body(gate, "func publish()")
    assert "readRevision" not in body(gate, "func invalidateActions()")
    assert "self.ready" not in body(gate, "func captureRead()")
    assert "@TaskLocal public static var current:" in reads and "onCancel: { invocation.cancel() }" in reads
    runtime_read = body(runtime, "public func settings(")
    assert runtime_read.index("PluginUISettingsReadExecution.require(pluginId: id)") < runtime_read.index("await operationHost()")
    assert "let owner = read.owner" in runtime_read and "let account = read.account" in runtime_read
    assert "settingsJSON(id: id, account: account, expectedOwner: owner," in runtime_read and "shouldExecute: { read.isCurrent }" in runtime_read
    assert runtime_read.index("guard read.isCurrent, self.host === host") > runtime_read.index("await host.settingsJSON")
    assert "isCurrent authority: PluginConfigAuthority" in runtime and ".pinnedSet(wanted: wanted" in runtime
    harness_read = region_text(harness, {"id": "harness.settings-read", "start": "            settings: { id in\n", "end": "            updateSetting:"})
    assert harness_read.index("PluginUISettingsReadExecution.require(pluginId: id)") < harness_read.index("await host.settingsJSON")
    assert "account: read.account, expectedOwner: read.owner" in harness_read and "shouldExecute: { read.isCurrent }" in harness_read
    assert harness_read.index("guard read.isCurrent") > harness_read.index("await host.settingsJSON")
    assert "private static func queuedSettingsRead(change:" in fixture

    # Coordinator's TL F01 join forwards its mandatory fifth execution predicate.
    tl_binding = region_text(runtime, {"id": "runtime.tl-binding", "start": "                let tl = PluginTLBridgeExtension(\n", "end": "                if let context = self.currentContext { tl.update(context: context) }"})
    assert "callback: { callbacks.callback($0, $1, $2, $3, shouldExecute: $4) }" in tl_binding
    assert "release: { callbacks.release($0, $1) }" in tl_binding

    # TBF-06: construction/inspection must succeed before the tested restore, whose
    # rejection is specifically the native schema-authority boundary.
    dynamic = body(fixture, "private static func dynamicSchemasNeverAuthorize()")
    assert 'createdAt: "2026-11-15T00:00:00Z"' in dynamic and 'createdAt: "fixture"' not in dynamic
    assert dynamic.index("let archive = try ToolsBackupArchive.encode(payload)") < dynamic.index("ToolsBackupRestorer().restore(")
    assert 'error == .invalidArchive("Plugin backup requires current native schema evidence.")' in dynamic

    # HNS-01: current SDK output is unproven, not an invented immutable grant.
    assert "evidence: nil" in schema and "validity: nil" in schema
    assert ".nativeImmutable" not in schema
    assert "settingsSchemaCache = PluginUIUnprovenSchemaCache()" in runtime
    assert "settingsSchemaCache.recordDynamic(" in runtime
    maintenance = body(runtime, "public func beginManagerAwareSettingsMaintenance(")
    assert maintenance.index("settingsSchemaCache.clear()") < maintenance.index("await host.beginSettingsMaintenance")
    assert maintenance.index("await host.beginSettingsMaintenance") < maintenance.index("frozenSettingsLocation = try liveSettingsLocation()")
    assert "acquired.finish(resume: false)" in maintenance
    for preserved in ("PluginConfigBridgeExtension(", "publisherSites: [.committedMessages, .mediaFetch]",
                      "tlOrigin: tlOrigin", "tl, native, pills,", "ToolsToggleTraceBuffer.shared.record"):
        assert preserved in runtime

    for path in [UI / "Tests/run_remediation_fixture.py", UI / "Tests/plugin_ui_postimage.py", Path(__file__)]:
        ast.parse(read(path), filename=str(path))
    for path in UI.glob("PluginUI*swift"):
        source = read(path)
        assert not re.search(r"^\s*import\s+(Postbox|TelegramApi)\b", source, re.M), path
    print(f"PASS: applied HNS-F01/F02/TBF-06 postimage; {len(postimage['regions'])} composition regions and {len(postimage['files'])} UI/helper/fixture source pins.")
    print("Runtime/harness reads and TL fifth-argument forwarding are applied. Mac execution of all 23 scenarios remains a separate gate after SDK final source.")


if __name__ == "__main__":
    main()
