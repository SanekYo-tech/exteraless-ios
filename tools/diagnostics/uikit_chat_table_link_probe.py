#!/usr/bin/env python3
"""Compile-only Apple SDK reproducer; NOT the TelegramUI module or an app test.

The two production class files are copied exactly, after verifying frozen LF
hashes. Six deliberately minimal dependency modules replace Telegram services.
UIKit/Foundation/UniformTypeIdentifiers and the superclass's UIKit ancestry are
real. Every compiler output and Clang module cache is in a new RUNNER_TEMP tree.
"""
from pathlib import Path
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

SOURCES = {
    "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatTableController.swift":
        "738d48806e2bce59603c6c4384d5ddd98105166cf747f650668d861e519596d4",
    "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Retention/ExteralessAyuImportController.swift":
        "36f2f1b9489ed572a2af5bfc032800dad796425e38c6b11deeb44d374f79e82d",
}

# Compile-only declarations. None of these services is executed or represented
# as real AccountContext, persistence, presentation, import or signal behavior.
STUBS = {
    "SwiftSignalKit": r'''
import Foundation
public protocol Disposable { func dispose() }
public final class MetaDisposable: Disposable {
    public init() {}
    public func set(_ value: Disposable?) {}
    public func dispose() {}
}
public enum NoError {}
public final class Signal<T, E> {
    public init() {}
    public func start(next: ((T) -> Void)! = nil, error: ((E) -> Void)! = nil,
                      completed: (() -> Void)! = nil) -> Disposable { fatalError("compile-only signal") }
}
public final class Atomic<T> {
    public init(value: T) {}
    public func with<R>(_ f: (T) -> R) -> R { fatalError("compile-only atomic") }
}
precedencegroup PipeRight {
    associativity: left
    higherThan: DefaultPrecedence
}
infix operator |> : PipeRight
public func |> <T, U>(value: T, function: ((T) -> U)) -> U { function(value) }
public func deliverOnMainQueue<T, E>(_ signal: Signal<T, E>) -> Signal<T, E> { signal }
''',
    "AsyncDisplayKit": r'''
import UIKit
@MainActor open class ASDisplayNode: NSObject {
    public let view = UIView()
    public var backgroundColor: UIColor? {
        get { view.backgroundColor }
        set { view.backgroundColor = newValue }
    }
    public override init() { super.init() }
}
''',
    "Display": r'''
import Foundation
import UIKit
import AsyncDisplayKit
public protocol ContainableController: AnyObject {}
public struct StatusBarStyle { public init() {} }
public struct ThemeStatusBarStyle { public var style = StatusBarStyle() }
public struct ThemeRootController { public var statusBarStyle = ThemeStatusBarStyle() }
public struct ThemeList {
    public var blocksBackgroundColor = UIColor.black
    public var itemBlocksSeparatorColor = UIColor.gray
    public var itemAccentColor = UIColor.blue
    public var itemPrimaryTextColor = UIColor.black
    public var itemSecondaryTextColor = UIColor.gray
    public var itemBlocksBackgroundColor = UIColor.white
}
public struct PresentationTheme {
    public var rootController = ThemeRootController()
    public var list = ThemeList()
    public var overallDarkAppearance = false
}
public struct ListFontSize { public var baseDisplaySize: CGFloat = 17 }
public struct PresentationStrings { public var Common_Back = "Back" }
public struct PresentationData {
    public var theme = PresentationTheme()
    public var listsFontSize = ListFontSize()
    public var strings = PresentationStrings()
}
public struct NavigationBarPresentationData {
    public init(presentationData: PresentationData) {}
}
public struct LayoutInsetsOptions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let input = LayoutInsetsOptions(rawValue: 1)
}
public struct ContainerViewLayout {
    public var size = CGSize.zero
    public func sideInsets(forBandFrom: CGFloat, to: CGFloat) -> UIEdgeInsets { .zero }
    public func insets(options: LayoutInsetsOptions) -> UIEdgeInsets { .zero }
}
public enum ContainedViewLayoutTransition {
    case immediate
    @MainActor public func updateFrame(view: UIView, frame: CGRect) { view.frame = frame }
}
public final class StatusBar { public var statusBarStyle = StatusBarStyle() }
public final class NavigationBar {
    public func updatePresentationData(_ data: NavigationBarPresentationData,
                                      transition: ContainedViewLayoutTransition) {}
}
@objc open class ViewController: UIViewController, ContainableController {
    public struct NavigationLayout { public var navigationFrame = CGRect.zero }
    public var displayNode = ASDisplayNode()
    public var isNodeLoaded: Bool { true }
    public let statusBar = StatusBar()
    public let navigationBar: NavigationBar? = NavigationBar()
    public init(navigationBarPresentationData: NavigationBarPresentationData) {
        super.init(nibName: nil, bundle: nil)
    }
    public required init(coder: NSCoder) { fatalError("compile-only controller") }
    open func loadDisplayNode() {}
    public func displayNodeDidLoad() {}
    open func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {}
    public func navigationLayout(layout: ContainerViewLayout) -> NavigationLayout { NavigationLayout() }
    public func push(_ controller: ViewController) {}
    public func dismiss() {}
}
''',
    "TelegramPresentationData": "@_exported import Display\n",
    "TelegramCore": r'''
import Foundation
import SwiftSignalKit
public struct EnginePeer {
    public struct Id: Hashable {
        public struct Value: Hashable {
            public func _internalGetInt64Value() -> Int64 { fatalError("compile-only peer") }
        }
        public var id: Value { fatalError("compile-only peer") }
        public var namespace: Int32 { fatalError("compile-only peer") }
    }
    public var id: Id { fatalError("compile-only peer") }
}
public enum Namespaces {
    public enum Peer {
        public static let CloudUser: Int32 = 0
        public static let CloudGroup: Int32 = 1
        public static let CloudChannel: Int32 = 2
    }
}
public struct ExteralessAyuImportReceipt {
    public var importedVersions = 0
    public var duplicates = 0
    public var expired = 0
    public var otherAccounts = 0
    public var unresolvedPeers: Set<Int64> = []
    public var mediaWithoutFiles = 0
    public var importedReadDates = 0
    public var importedContentReadDates = 0
    public var importedActivities = 0
    public var importedChatDescriptors = 0
    public var auxiliaryDuplicates = 0
    public var auxiliaryExpired = 0
    public var auxiliaryUnsetDates = 0
    public var auxiliaryQuotaSkipped = 0
    public var auxiliarySelfActivities = 0
}
public enum ExteralessRetentionError: Error { case unavailable }
public enum ExteralessRetentionPresentation {
    public static func errorText(_ error: ExteralessRetentionError) -> String { fatalError("compile-only error text") }
}
public final class TelegramEngine {
    public final class Messages {
        public func importAyuDatabase(url: URL, peerMappings: [Int64: EnginePeer.Id] = [:])
            -> Signal<Result<ExteralessAyuImportReceipt, ExteralessRetentionError>, NoError> {
            fatalError("compile-only engine")
        }
    }
    public var messages: Messages { fatalError("compile-only engine") }
}
''',
    "AccountContext": r'''
import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
public protocol AccountContext: AnyObject {
    var sharedContext: SharedAccountContext { get }
    var engine: TelegramEngine { get }
}
public protocol SharedAccountContext: AnyObject {
    var currentPresentationData: Atomic<PresentationData> { get }
    var presentationData: Signal<PresentationData, NoError> { get }
    func makePeerSelectionController(_ params: PeerSelectionControllerParams) -> PeerSelectionController
}
public struct ChatListNodePeersFilter: OptionSet {
    public var rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let excludeRecent = ChatListNodePeersFilter(rawValue: 1 << 6)
    public static let doNotSearchMessages = ChatListNodePeersFilter(rawValue: 1 << 8)
}
public final class PeerSelectionControllerParams {
    public init(context: AccountContext, filter: ChatListNodePeersFilter,
                hasContactSelector: Bool, title: String?) {}
}
public protocol PeerSelectionController: ViewController {
    var peerSelected: ((EnginePeer, Int64?) -> Void)? { get set }
}
''',
}


def main():
    root = Path.cwd()
    output = Path(os.environ["PROBE_OUTPUT"])
    output.mkdir(parents=True, exist_ok=False)
    work = Path(tempfile.mkdtemp(prefix="chat-table-symbols.", dir=os.environ["RUNNER_TEMP"]))
    report = {"scope": "two exact class files + compile-only dependency stubs + real Apple SDK",
              "fullTelegramUIBuilt": False, "uikitExecuted": False, "runtimeExecuted": False,
              "sourceRevision": os.environ.get("GITHUB_SHA"), "sources": SOURCES,
              "compileLimitSeconds": 120, "commandLimitSeconds": 10,
              "work": str(work), "commands": [], "variants": {}}
    compile_seconds = 0.0

    def run(args, label, *, compile=False, data=None):
        nonlocal compile_seconds
        seconds = 120 - compile_seconds if compile else 10
        if seconds <= 0:
            raise TimeoutError("120 second total compiler budget exhausted")
        args = [str(arg) for arg in args]
        started = time.monotonic()
        proc = subprocess.Popen(args, cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, start_new_session=True)
        timed_out = False
        try:
            text, _ = proc.communicate(data, timeout=seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGKILL)
            text, _ = proc.communicate(timeout=2)
        elapsed = time.monotonic() - started
        if compile:
            compile_seconds += elapsed
        (output / (label + ".log")).write_text(text, encoding="utf-8")
        report["commands"].append({"label": label, "argv": args, "exit": proc.returncode,
                                    "seconds": elapsed, "timeout": timed_out})
        print(label, "exit", proc.returncode, "seconds", round(elapsed, 2), flush=True)
        if timed_out:
            raise TimeoutError(label)
        return proc.returncode, text

    def checked(args, label, **kwargs):
        status, text = run(args, label, **kwargs)
        if status:
            raise RuntimeError(label + " failed:\n" + text)
        return text

    try:
        report["xcode"] = checked(["xcodebuild", "-version"], "xcode").strip()
        assert report["xcode"].splitlines()[0] == "Xcode 27.1"
        report["swift"] = checked(["xcrun", "swiftc", "--version"], "swift").strip()
        sdk = checked(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], "sdk").strip()
        report["sdk"] = sdk
        originals = []
        for relative, expected in SOURCES.items():
            data = (root / relative).read_bytes().replace(b"\r\n", b"\n")
            assert hashlib.sha256(data).hexdigest() == expected, relative
            originals.append(data.decode("utf-8"))
        modules = work / "modules"
        modules.mkdir()
        flags = ["-sdk", sdk, "-target", "arm64-apple-ios15.0-simulator", "-swift-version", "5",
                 "-Onone", "-DDEBUG", "-parse-as-library", "-I", modules,
                 "-module-cache-path", work / "clang-module-cache"]
        stub_objects = []
        for name, source in STUBS.items():
            path = modules / (name + ".swift")
            path.write_text(source, encoding="utf-8")
            obj = modules / (name + ".o")
            checked(["xcrun", "swiftc", *flags, "-module-name", name,
                     "-emit-module", "-emit-module-path", modules / (name + ".swiftmodule"),
                     "-c", path, "-o", obj], "stub-" + name, compile=True)
            stub_objects.append(obj)
        needle = "    func writeSettings("
        assert originals[0].count(needle) == 1
        variants = {"baseline": needle, "final": "    final func writeSettings(",
                    "main-actor": "    @MainActor func writeSettings(",
                    "preconcurrency": "    @preconcurrency func writeSettings("}
        for variant, replacement in variants.items():
            folder = work / variant
            folder.mkdir()
            sources = [folder / Path(relative).name for relative in SOURCES]
            sources[0].write_text(originals[0].replace(needle, replacement), encoding="utf-8")
            sources[1].write_text(originals[1], encoding="utf-8")
            result = {"sources": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                      "objects": {}, "linkExit": None}
            report["variants"][variant] = result
            objects = []
            for index, source in enumerate(sources):
                primary_args = []
                for item in sources:
                    if item == source:
                        primary_args.append("-primary-file")
                    primary_args.append(item)
                obj = folder / (source.stem + ".o")
                status, _ = run(["xcrun", "swiftc", "-frontend", "-c", *flags,
                                 "-module-name", "TelegramUI", *primary_args, "-o", obj],
                                variant + "-" + source.stem, compile=True)
                if status:
                    result["compileFailure"] = source.name
                    break
                objects.append(obj)
                nm = checked(["xcrun", "nm", "-g", obj], variant + "-nm-" + source.stem)
                filtered = "\n".join(line for line in nm.splitlines() if "writeSettings" in line)
                demangled = checked(["xcrun", "swift-demangle"], variant + "-demangled-" + source.stem, data=filtered)
                symbols = [(line.split()[-2], line.split()[-1]) for line in filtered.splitlines()]
                result["objects"][source.name] = {"raw": filtered, "demangled": demangled,
                                                  "writeSettingsSymbols": symbols}
                if variant in ("baseline", "final"):
                    sil = output / (variant + "-" + source.stem + ".sil")
                    checked(["xcrun", "swiftc", "-frontend", "-emit-silgen", *flags,
                             "-module-name", "TelegramUI", *primary_args, "-o", sil],
                            variant + "-sil-" + source.stem, compile=True)
            if len(objects) != 2:
                continue
            caller = folder / "Caller.swift"
            caller.write_text("@MainActor func invokeSettings(_ controller: ExteralessChatTableController, "
                              "operation: @escaping @Sendable () throws -> Void, completion: @escaping () -> Void) {\n"
                              "    controller.writeSettings(operation, completion: completion)\n}\n", encoding="utf-8")
            caller_obj = folder / "Caller.o"
            checked(["xcrun", "swiftc", "-frontend", "-c", *flags, "-module-name", "TelegramUI",
                     *sources, "-primary-file", caller, "-o", caller_obj], variant + "-caller", compile=True)
            caller_nm = checked(["xcrun", "nm", "-g", caller_obj], variant + "-nm-caller")
            result["callerWriteSettings"] = "\n".join(line for line in caller_nm.splitlines() if "writeSettings" in line)
            status, link_text = run(["xcrun", "swiftc", "-emit-library", "-sdk", sdk,
                                     "-target", "arm64-apple-ios15.0-simulator", *stub_objects, *objects, caller_obj,
                                     "-o", folder / "libClassProbe.dylib"], variant + "-link", compile=True)
            result["linkExit"] = status
            base_symbols = result["objects"][sources[0].name]["writeSettingsSymbols"]
            child_symbols = result["objects"][sources[1].name]["writeSettingsSymbols"]
            defined = {symbol for kind, symbol in base_symbols if kind != "U"}
            result["unresolvedInheritedWriteSettings"] = [symbol for kind, symbol in child_symbols
                                                          if kind == "U" and symbol not in defined]
            result["inheritedWriteSettingsReferences"] = [symbol for kind, symbol in child_symbols if kind == "U"]
        baseline = report["variants"]["baseline"]
        final = report["variants"]["final"]
        report["crossPrimaryMismatchReproduced"] = bool(baseline.get("unresolvedInheritedWriteSettings")) and baseline["linkExit"] == 1
        report["finalHelperLinksWithoutInheritedReference"] = final["linkExit"] == 0 and not final.get("inheritedWriteSettingsReferences")
        report["status"] = "captured"
        if not (report["crossPrimaryMismatchReproduced"] and report["finalHelperLinksWithoutInheritedReference"]):
            raise RuntimeError("Expected baseline/final differential was not established; inspect the recorded matrix")
    except Exception as error:
        report["error"] = str(error)
        report["status"] = "diagnostic-incomplete"
        raise
    finally:
        report["compileSeconds"] = compile_seconds
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        (output / "stub-sources.json").write_text(json.dumps(STUBS, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({key: value for key, value in report.items() if key not in ("commands", "variants")}, indent=2))


if __name__ == "__main__":
    main()
