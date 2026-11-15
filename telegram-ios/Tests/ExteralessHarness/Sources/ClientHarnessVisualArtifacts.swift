import CryptoKit
import Foundation
import UIKit

func clientHarnessSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Reads the actual rendered view/layer. These images are supplementary native
/// observations; acceptance is still the separate simctl variable-rate recording.
@MainActor
func clientHarnessViewImage(_ view: UIView, presentation: Bool = false) throws -> UIImage {
    try clientHarnessRequire(view.window != nil && view.bounds.width > 0 && view.bounds.height > 0,
        "native image capture requires a live, laid-out view")
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
        (presentation ? view.layer.presentation() ?? view.layer : view.layer).render(in: context.cgContext)
    }
}

struct ClientHarnessImagePixels {
    let width: Int
    let height: Int
    let rgba: Data
    var sha256: String { clientHarnessSHA256(self.rgba) }
    var alpha: Data { Data(stride(from: 3, to: self.rgba.count, by: 4).map { self.rgba[$0] }) }

    init(_ image: UIImage) throws {
        guard let image = image.cgImage else { throw ClientHarnessFailure(description: "native UIImage has no CGImage") }
        self.width = image.width
        self.height = image.height
        var bytes = Data(count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        try clientHarnessRequire(drawn, "native pixel read failed")
        self.rgba = bytes
    }
}

@MainActor
extension ClientHarnessSession {
    @discardableResult
    func saveVisualImage(_ image: UIImage, name: String, kind: String) throws -> String {
        try clientHarnessRequire(name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil, "invalid image handle")
        guard let bytes = image.pngData(), let cg = image.cgImage else {
            throw ClientHarnessFailure(description: "native image could not be encoded")
        }
        let path = "native/" + name + ".png"
        let url = self.report.directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try clientHarnessRequire(!FileManager.default.fileExists(atPath: url.path), "native image handle must be unique")
        try bytes.write(to: url, options: .atomic)
        var artifacts = self.report.facts["visualArtifacts"] as? [[String: Any]] ?? []
        artifacts.append(["path": path, "kind": kind, "sha256": clientHarnessSHA256(bytes), "bytes": bytes.count,
            "width": cg.width, "height": cg.height, "scale": image.scale])
        self.report.facts["visualArtifacts"] = artifacts
        return path
    }

    func visualProbe(_ name: String, view: UIView, extra: [String: Any]) throws {
        var extra = extra
        extra["nativeViewImage"] = try self.saveVisualImage(clientHarnessViewImage(view), name: name, kind: "live-view-layer")
        try self.probe(name, extra: extra)
    }
}
