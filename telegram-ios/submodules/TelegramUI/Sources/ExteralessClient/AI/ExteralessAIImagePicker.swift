import Display
import ExteralessCore
import Foundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ExteralessAIImagePicker: NSObject, PHPickerViewControllerDelegate {
    private let completion: (Result<AIImageAttachment, AIError>) -> Void
    private var finished = false
    init(completion: @escaping (Result<AIImageAttachment, AIError>) -> Void) { self.completion = completion }

    func present(from controller: ViewController) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        controller.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { finish(.failure(.cancelled)); return }
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { finish(.failure(.invalidResponse)); return }
        provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
            let result: Result<AIImageAttachment, AIError>
            do {
                guard let url else { throw AIError.invalidResponse }
                // File representations exist only inside this callback. Decode a
                // thumbnail here on the provider's worker, not after its URL dies.
                result = .success(try ExteralessAIImageEncoder.encode(url: url))
            } catch { result = .failure((error as? AIError) ?? .invalidResponse) }
            Task { @MainActor [weak self] in self?.finish(result) }
        }
    }

    private func finish(_ result: Result<AIImageAttachment, AIError>) {
        guard !finished else { return }
        finished = true
        completion(result)
    }
}

enum ExteralessAIImageEncoder {
    static func encode(url: URL) throws -> AIImageAttachment {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = attributes.fileSize, size > 0, size <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: AILimits.imageSide, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw AIError.inputTooLarge }
        let value = UIImage(cgImage: image)
        for quality in [0.85, 0.75, 0.65, 0.55] {
            if let data = value.jpegData(compressionQuality: CGFloat(quality)), data.count <= AILimits.imageBytes {
                return AIImageAttachment(data: data, mimeType: "image/jpeg")
            }
        }
        throw AIError.inputTooLarge
    }
}
