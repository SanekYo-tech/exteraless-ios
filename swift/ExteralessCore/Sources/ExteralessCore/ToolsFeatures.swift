import Foundation

public enum ToolsFeatures {
    /// Only definitions with real consumers belong here. Nothing Glyph, Android
    /// Camera1/2/X selectors and compatibility-storage fields are not iOS toggles.
    public static let definitions: [ClientSettingDefinition] = [
        .init(key: "tools.customSavePath", title: "Folder inside Files destination", section: "Downloads", defaultValue: .string("exteraless"),
              explanation: "A single folder name inside the selected Files destination. Empty uses that destination directly.", androidSymbols: ["NekoConfig.customSavePath"]),
        .init(key: "tools.saveToChatSubfolder", title: "Save into per-chat folders", section: "Downloads", defaultValue: .bool(false),
              explanation: "Creates stable account/chat-ID subfolders in the selected Files destination, adapting Android's per-chat public-storage folders.", androidSymbols: ["NaConfig.saveToChatSubfolder", "MediaController.saveFileInternal"]),
        .init(key: "tools.downloadSpeedBoost", title: "Download request budget", section: "Downloads",
              defaultValue: .integer(0), options: [.init(value: .integer(0), title: "Native iOS"),
                  .init(value: .integer(1), title: "Larger · 512 KiB / 8"), .init(value: .integer(2), title: "Maximum · 1 MiB / 12")],
              explanation: "Applies to new large, unencrypted Telegram downloads. Native story/small-file handling and transport limits are retained; this does not promise a particular speed.",
              androidSymbols: ["GeneralConfig.downloadSpeedBoost", "FileLoadOperation.updateParams"]),
        .init(key: "tools.quickToggles", title: "Home-screen quick toggles", section: "Tools",
              defaultValue: .bool(false), explanation: "Show Ghost mode and Plugin safe mode in the app icon's quick actions. Search and Compose remain available.",
              androidSymbols: ["QuickToggleActivity.ACTION_GHOST_MODE", "QuickToggleActivity.ACTION_SAFE_MODE"]),
        .init(key: "tools.crashReports", title: "Keep local system diagnostics", section: "Tools",
              defaultValue: .bool(false), explanation: "Cache system-delivered MetricKit crash and energy reports for manual export. iOS adaptation of crash reporting; no automatic upload.",
              androidSymbols: ["GeneralConfig.crashReports", "CrashLog"]),
        .init(key: "tools.autoUpdateChannel", title: "Update channel", section: "Updates",
              defaultValue: .integer(0), options: [
                .init(value: .integer(0), title: "Manual checks"),
                .init(value: .integer(1), title: "Stable"),
                .init(value: .integer(2), title: "Include prereleases")
              ], explanation: "Public GitHub Releases. Automatic checks run at most once every six hours while the app is active. IPA signing and installation are manual.",
              androidSymbols: ["GitHubUpdater.check", "NaConfig.autoUpdateChannel"]),
        .init(key: "tools.cameraMirrorMode", title: "Mirror front camera", section: "Camera",
              defaultValue: .bool(true), explanation: "Applies to new Telegram camera sessions.",
              androidSymbols: ["ChatsConfig.cameraMirrorMode", "CameraXSession"]),
        .init(key: "tools.startWithWideAngleCamera", title: "Start with ultrawide lens", section: "Camera",
              defaultValue: .bool(false), explanation: "Uses the real minimum zoom of a supported rear virtual camera. Single-lens and simultaneous dual-camera sessions keep their native lens.",
              androidSymbols: ["ChatsConfig.startWithWideAngleCamera", "InstantCameraZoomSlider"]),
        .init(key: "tools.cameraStabilization", title: "Camera stabilization", section: "Camera",
              defaultValue: .bool(false), explanation: "Requests standard stabilization when the active camera format supports it. Applies to new sessions.",
              androidSymbols: ["ChatsConfig.cameraStabilization", "CameraXSession"]),
        .init(key: "tools.extendedFramesPerSecond", title: "Higher camera frame rate", section: "Camera",
              defaultValue: .bool(false), explanation: "Up to 60 FPS when the active format and single-camera session support it. Multi-camera sessions retain their hardware budget.",
              androidSymbols: ["ChatsConfig.extendedFramesPerSecond", "CameraXSession"]),
        .init(key: "tools.zoomSlider", title: "Camera zoom controls", section: "Camera",
              defaultValue: .bool(true), explanation: "Lens stops and a continuous zoom slider in the Telegram camera, using the active device's real zoom range.",
              androidSymbols: ["ChatsConfig.zoomSlider", "InstantCameraZoomSlider", "CameraLensStops"]),
        .init(key: "tools.staticZoom", title: "Keep video-message zoom", section: "Camera",
              defaultValue: .bool(false), explanation: "Retain the zoom after releasing a pinch gesture in the video-message camera.",
              androidSymbols: ["ChatsConfig.staticZoom"]),
        .init(key: "tools.rememberLastUsedCamera", title: "Remember video-message camera", section: "Camera",
              defaultValue: .bool(false), explanation: "Reopen video-message recording with the last front or rear camera.",
              androidSymbols: ["ChatsConfig.rememberLastUsedCamera"]),
        .init(key: "tools.flashWarmth", title: "Video-message flash warmth", section: "Camera",
              defaultValue: .integer(50), minimum: 0, maximum: 100, step: 1,
              explanation: "Default screen flash: blue at 0, white at 50, warm at 100.", androidSymbols: ["ChatsConfig.flashWarmth", "FlashViews.getColor"]),
        .init(key: "tools.flashIntensity", title: "Video-message flash intensity", section: "Camera",
              defaultValue: .integer(100), minimum: 0, maximum: 100, step: 1,
              explanation: "Screen brightness and flash opacity during front-camera recording.", androidSymbols: ["ChatsConfig.flashIntensity"])
    ]
}

public enum ToolsCameraPolicy {
    public static func flashColor(warmth: Int) -> (red: Double, green: Double, blue: Double) {
        let value = Double(min(100, max(0, warmth))) / 100
        let from: (Double, Double, Double) = value < 0.5 ? (140.0 / 255, 223.0 / 255, 1) : (1, 1, 1)
        let to: (Double, Double, Double) = value < 0.5 ? (1, 1, 1) : (254.0 / 255, 238.0 / 255, 140.0 / 255)
        let progress = value < 0.5 ? value * 2 : (value - 0.5) * 2
        return (from.0 + (to.0 - from.0) * progress, from.1 + (to.1 - from.1) * progress, from.2 + (to.2 - from.2) * progress)
    }

    public static func frameRate(requested: Double, supported: ClosedRange<Double>, extended: Bool, multiCamera: Bool) -> Double {
        guard requested.isFinite, supported.lowerBound.isFinite, supported.upperBound.isFinite,
              supported.lowerBound > 0 else { return 30 }
        let preferred = extended && !multiCamera ? max(requested, 60) : requested
        return min(supported.upperBound, max(supported.lowerBound, preferred))
    }

    public static func zoom(_ value: Double, minimum: Double, maximum: Double) -> Double {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return 1 }
        return min(maximum, max(minimum, value.isFinite ? value : minimum))
    }

    public static func lensStops(minimum: Double, maximum: Double, optical: [Double]) -> [Double] {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return [] }
        var values = [minimum, zoom(1, minimum: minimum, maximum: maximum)]
        values.append(contentsOf: optical.filter { $0.isFinite && $0 >= minimum && $0 <= maximum })
        var result: [Double] = []
        for value in values.sorted() where result.last.map({ abs($0 - value) > 0.0001 }) ?? true {
            result.append(value)
        }
        return result
    }
}
