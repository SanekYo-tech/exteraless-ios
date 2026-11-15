import CoreGraphics
import CoreText
import ExteralessCore
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct ExteralessEmojiFontOwner: Equatable, Sendable {
    fileprivate let id: UUID
    public let accountId: Int64
}

public final class ExteralessEmojiFont: @unchecked Sendable {
    public let inspection: EmojiFontInspection
    fileprivate let graphicsFont: CGFont
    fileprivate var font: CTFont { CTFontCreateWithGraphicsFont(self.graphicsFont, 32, nil, nil) }
    private let graphemes: EmojiGraphemeSupport

    fileprivate init(inspection: EmojiFontInspection, graphicsFont: CGFont) {
        self.inspection = inspection
        self.graphicsFont = graphicsFont
        self.graphemes = EmojiGraphemeSupport(graphicsFont: graphicsFont)
    }

    /// Every use must pass its own cached shaping/visibility decision. Installing
    /// a font with one visible sample does not establish support for other emoji.
    fileprivate func supports(_ text: String) -> Bool {
        return self.graphemes.supports(text)
    }

    fileprivate func hasVisibleProbe() -> Bool {
        return ["😀", "😉", "😔", "😨"].contains(where: self.supports)
    }
}

/// Process registration is app-local. The active face is account-scoped and
/// published only after both registration and actual glyph rendering succeed.
public final class ExteralessEmojiRendering: @unchecked Sendable {
    public static let shared = ExteralessEmojiRendering()
    private let lock = NSLock()
    private var registered: [String: ExteralessEmojiFont] = [:]
    private var owner: ExteralessEmojiFontOwner?
    private var active: (accountId: Int64, face: ExteralessEmojiFont)?

    private init() {}

    public func begin(accountId: Int64) -> ExteralessEmojiFontOwner {
        self.lock.lock()
        self.active = nil
        self.removeUnusedRegistrations()
        let owner = ExteralessEmojiFontOwner(id: UUID(), accountId: accountId)
        self.owner = owner
        self.lock.unlock()
        self.invalidate()
        return owner
    }

    public func prepare(data: Data, fileExtension: String, expectedSHA256: String? = nil, owner: ExteralessEmojiFontOwner) throws -> ExteralessEmojiFont {
        let inspection = try EmojiFontInspection.inspect(data, fileExtension: fileExtension, expectedSHA256: expectedSHA256)
        let registrationData = try EmojiFontRegistration.data(data, inspection: inspection)
        guard let provider = CGDataProvider(data: registrationData as CFData), let graphicsFont = CGFont(provider),
              let name = graphicsFont.postScriptName as String?, name == EmojiFontRegistration.privateName(sha256: inspection.sha256) else { throw EmojiPackError.incompatibleFont }
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.owner == owner else { throw EmojiPackError.cancelled }
        if let existing = self.registered[name], existing.inspection.sha256 == inspection.sha256 { return existing }
        if self.registered.count >= EmojiPackLimits.installedCount || self.registered.values.reduce(inspection.byteCount, { $0 + $1.inspection.byteCount }) > EmojiPackLimits.libraryBytes {
            self.removeUnusedRegistrations(keepingActive: true)
        }
        guard self.registered[name] != nil || self.registered.count < EmojiPackLimits.installedCount else { throw EmojiPackError.quota }
        guard self.registered.values.reduce(inspection.byteCount, { $0 + $1.inspection.byteCount }) <= EmojiPackLimits.libraryBytes else { throw EmojiPackError.quota }
        guard CTFontManagerRegisterGraphicsFont(graphicsFont, nil) else {
            throw EmojiPackError.registrationFailed
        }
        let face = ExteralessEmojiFont(inspection: inspection, graphicsFont: graphicsFont)
        guard face.hasVisibleProbe() else {
            _ = CTFontManagerUnregisterGraphicsFont(graphicsFont, nil)
            throw EmojiPackError.registrationFailed
        }
        #if canImport(UIKit)
        // Registration must be usable by native attributed-text consumers too.
        guard UIFont(name: name, size: 32) != nil else {
            _ = CTFontManagerUnregisterGraphicsFont(graphicsFont, nil)
            throw EmojiPackError.registrationFailed
        }
        #endif
        self.registered[name] = face
        return face
    }

    @discardableResult public func apply(_ face: ExteralessEmojiFont?, owner: ExteralessEmojiFontOwner) -> Bool {
        self.lock.lock()
        guard self.owner == owner else { self.lock.unlock(); return false }
        if let face, !self.registered.values.contains(where: { $0 === face }) { self.lock.unlock(); return false }
        self.active = face.map { (owner.accountId, $0) }
        self.lock.unlock()
        self.invalidate()
        return true
    }

    public func clear(owner: ExteralessEmojiFontOwner) {
        self.lock.lock()
        guard self.owner == owner else { self.lock.unlock(); return }
        self.owner = nil
        self.active = nil
        self.removeUnusedRegistrations()
        self.lock.unlock()
        self.invalidate()
    }

    public func appliedSHA256(accountId: Int64) -> String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.active?.accountId == accountId ? self.active?.face.inspection.sha256 : nil
    }

    private func selected(accountId: Int64) -> ExteralessEmojiFont? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.active?.accountId == accountId ? self.active?.face : nil
    }

    /// CoreText can temporarily retain fonts used by existing attributed runs.
    /// Keep ownership of a registration it refuses to remove, so a later load
    /// reuses our known content hash rather than treating any name as installed.
    private func removeUnusedRegistrations(keepingActive: Bool = false) {
        for (name, face) in Array(self.registered) {
            if keepingActive, self.active?.face === face { continue }
            if CTFontManagerUnregisterGraphicsFont(face.graphicsFont, nil) { self.registered.removeValue(forKey: name) }
        }
    }

    private func invalidate() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: StickerFeatures.emojiChangedNotification, object: nil) }
    }

    #if canImport(UIKit)
    public func font(for emoji: String, size: CGFloat, accountId: Int64, fallback: UIFont) -> UIFont {
        guard let face = self.selected(accountId: accountId), face.supports(emoji) else { return fallback }
        return CTFontCreateCopyWithAttributes(face.font, size, nil, nil) as UIFont
    }

    /// Display-only copy: retains text, UTF-16 ranges, links and custom-emoji
    /// attachments. Call after entity formatting, never on stored/send content.
    public func attributedText(_ text: NSAttributedString, accountId: Int64, defaultSize: CGFloat = 17) -> NSAttributedString {
        guard let face = self.selected(accountId: accountId) else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let string = text.string
        string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byComposedCharacterSequences) { substring, range, _, _ in
            guard let substring, substring.utf16.count <= 32, StickerReactionPolicy.isEmoji(substring) else { return }
            let nsRange = NSRange(range, in: string)
            var hasAttachment = false
            text.enumerateAttributes(in: nsRange, options: []) { attributes, _, stop in
                if attributes.keys.contains(where: { $0.rawValue.lowercased().contains("customemoji") || $0 == .attachment }) {
                    hasAttachment = true
                    stop.pointee = true
                }
            }
            guard !hasAttachment, face.supports(substring) else { return }
            let attributes = text.attributes(at: nsRange.location, effectiveRange: nil)
            let size = (attributes[.font] as? UIFont)?.pointSize ?? defaultSize
            result.addAttribute(.font, value: CTFontCreateCopyWithAttributes(face.font, size, nil, nil) as UIFont, range: nsRange)
        }
        return result
    }

    public func preview(_ face: ExteralessEmojiFont, size: CGFloat = 32) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "😀  😉  😔  😨", attributes: [.font: UIFont.systemFont(ofSize: size)])
        let string = text.string
        string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byComposedCharacterSequences) { substring, range, _, _ in
            if let substring, face.supports(substring) { text.addAttribute(.font, value: CTFontCreateCopyWithAttributes(face.font, size, nil, nil) as UIFont, range: NSRange(range, in: string)) }
        }
        return text
    }
    #endif
}
