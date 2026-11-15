import Foundation

public enum ToolsDocumentKind: Equatable, Sendable {
    case markdown
    case code(String)
    case plainText

    public static func detect(name: String, mimeType: String? = nil) -> Self? {
        let name = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        let filenames = ["dockerfile": "docker", "makefile": "makefile", "gnumakefile": "makefile", "cmakelists.txt": "cmake",
                         ".gitignore": "git", ".gitattributes": "git", ".gitmodules": "git", ".dockerignore": "docker", ".editorconfig": "ini", ".env": "ini"]
        if let language = filenames[name] { return .code(language) }
        if name.hasPrefix("dockerfile.") { return .code("docker") }
        if name.hasPrefix("makefile.") { return .code("makefile") }
        if name.hasPrefix(".env.") { return .code("ini") }
        let ext = (name as NSString).pathExtension
        if ["md", "markdown", "txt", "text"].contains(ext) { return .markdown }
        let groups: [(String, [String])] = [
            ("plain", ["log"]), ("diff", ["diff", "patch"]), ("json", ["json", "webmanifest"]), ("json5", ["json5"]),
            ("xml", ["xml", "rss", "atom"]), ("svg", ["svg"]), ("html", ["html", "htm", "xhtml"]), ("css", ["css"]),
            ("scss", ["scss"]), ("sass", ["sass"]), ("less", ["less"]), ("javascript", ["js", "mjs", "cjs"]),
            ("jsx", ["jsx"]), ("typescript", ["ts"]), ("tsx", ["tsx"]), ("java", ["java"]), ("kotlin", ["kt", "kts"]),
            ("gradle", ["gradle"]), ("groovy", ["groovy"]), ("python", ["py", "pyw", "plugin"]),
            ("bash", ["sh", "bash", "zsh", "fish", "shell"]), ("powershell", ["ps1", "psm1", "psd1"]), ("batch", ["bat", "cmd"]),
            ("sql", ["sql"]), ("yaml", ["yaml", "yml"]), ("ini", ["ini", "toml", "properties", "props", "conf", "cfg", "config", "env", "dotenv"]),
            ("csv", ["csv", "tsv"]), ("docker", ["dockerfile"]), ("makefile", ["make", "mk", "mak"]), ("cmake", ["cmake"]),
            ("go", ["go"]), ("rust", ["rs"]), ("swift", ["swift"]), ("dart", ["dart"]), ("php", ["php", "phtml"]),
            ("ruby", ["rb", "gemspec"]), ("c", ["c"]), ("cpp", ["h", "hh", "hpp", "hxx", "cpp", "cc", "cxx"]),
            ("csharp", ["cs"]), ("fsharp", ["fs", "fsx"]), ("visual-basic", ["vb", "vba"]), ("lua", ["lua"]),
            ("perl", ["pl", "pm"]), ("r", ["r"]), ("scala", ["scala"]), ("haskell", ["hs"]), ("elixir", ["ex", "exs"]),
            ("erlang", ["erl", "hrl"]), ("protobuf", ["proto", "protobuf"]), ("graphql", ["graphql", "gql"]),
            ("glsl", ["glsl", "vert", "frag", "geom", "comp"]), ("http", ["http"])
        ]
        if let group = groups.first(where: { $0.1.contains(ext) }) { return .code(group.0) }
        let mime = (mimeType ?? "").lowercased().split(separator: ";").first.map(String.init) ?? ""
        let mimes = ["text/x-diff": "diff", "text/x-patch": "diff", "text/csv": "csv", "text/xml": "xml", "application/xml": "xml",
                     "application/json5": "json5", "application/json": "json", "application/ld+json": "json", "text/yaml": "yaml",
                     "text/x-yaml": "yaml", "application/yaml": "yaml", "application/x-yaml": "yaml", "text/css": "css",
                     "text/javascript": "javascript", "application/javascript": "javascript", "application/x-javascript": "javascript", "application/x-sh": "bash"]
        if let language = mimes[mime] { return .code(language) }
        return mime == "text/plain" ? .plainText : nil
    }
}

public enum ToolsJPEGPlatform {
    /// A signature heuristic for the last encoder, never a claim about the device
    /// which took the photograph. Compares the whole prefix, including short reads.
    public static func guess(header: Data) -> String? {
        let signatures = [
            ("FFD8FFE000104A46494600010101006000600000FFDB0043000403030403030404030405040405060A07060606060D090A080A0F0D10100F0D0F0E1113181411", "Desktop"),
            ("FFD8FFE000104A46494600010101004800480000FFE202184943435F50524F46494C4500010100000208", "Web"),
            ("FFD8FFE000104A46494600010100000100010000FFE202184943435F50524F46494C450001010000020800000000043000006D6E74725247422058595A2007E0", "Android"),
            ("FFD8FFE000104A46494600010101004800480000FFE201D84943435F50524F46494C45000101000001C800000000043000006D6E74725247422058595A2007E0", "Android"),
            ("FFD8FFE000104A46494600010100000100010000FFE201D84943435F50524F46494C45000101000001C800000000043000006D6E74725247422058595A2007E0", "Android"),
            ("FFD8FFE000104A46494600010100000100010000FFDB004300090607080706090807080A0A090B0D160F0D0C0C0D1B14151016201D2222201D1F1F2428342C24", "iOS"),
            ("FFD8FFE000104A46494600010100000100010000FFDB004300080606070605080707070909080A0C140D0C0B0B0C1912130F141D1A1F1E1D1A1C1C20242E2720", "macOS"),
            ("FFD8FFE000104A46494600010101004800480000FFE201DB4943435F50524F46494C45000101000001CB00000000024000006D6E74725247422058595A200000", "macOS")
        ]
        let hex = header.prefix(64).map { String(format: "%02X", $0) }.joined()
        return signatures.first(where: { hex.hasPrefix($0.0) })?.1
    }
}

/// CADisplayLink callback gaps, not GPU frame render times or a Java stack sampler.
public struct ToolsFrameProfile: Sendable {
    public private(set) var samples = 0
    public private(set) var delayed = 0
    public private(set) var longestInterval: Double = 0
    public private(set) var totalInterval: Double = 0
    public private(set) var slowest: [Double] = []
    private var previous: Double?

    public init() {}

    public mutating func record(timestamp: Double, expectedInterval: Double) {
        guard timestamp.isFinite, expectedInterval.isFinite, expectedInterval > 0, samples < 10_000 else { return }
        guard let previous else { self.previous = timestamp; return }
        guard timestamp > previous else { return }
        self.previous = timestamp
        let interval = timestamp - previous
        samples += 1
        totalInterval += interval
        longestInterval = max(longestInterval, interval)
        if interval > expectedInterval * 1.5 {
            delayed += 1
            slowest.append(interval)
            slowest.sort(by: >)
            if slowest.count > 40 { slowest.removeLast() }
        }
    }

    public var report: String {
        "Display-link intervals: \(samples)\nDelayed (>1.5× target interval): \(delayed)\nLongest callback interval: \(String(format: "%.2f", longestInterval * 1000)) ms\nSlowest intervals (ms): "
            + slowest.map { String(format: "%.2f", $0 * 1000) }.joined(separator: ", ")
    }
}

public final class ToolsToggleTraceBuffer: @unchecked Sendable {
    public static let shared = ToolsToggleTraceBuffer()
    private let lock = NSLock()
    private var records: [String] = []
    public init() {}

    public func record(pluginId: String, enabled: Bool, elapsed: TimeInterval, succeeded: Bool) {
        guard elapsed.isFinite, elapsed >= 0 else { return }
        let id = ToolsFileSafety.isComponent(pluginId) ? pluginId : "plugin"
        let line = "\(enabled ? "enable" : "disable") \(id): \(String(format: "%.1f", elapsed * 1000)) ms · \(succeeded ? "completed" : "failed")"
        lock.lock()
        records.append(line)
        if records.count > 40 { records.removeFirst(records.count - 40) }
        lock.unlock()
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
