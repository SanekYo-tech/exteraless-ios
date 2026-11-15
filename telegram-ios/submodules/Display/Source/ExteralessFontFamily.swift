import CoreGraphics
import CoreText
import ExteralessCore
import Foundation
import UIKit

public enum ExteralessFontFamilyError: Error, Equatable {
    case missingResource(String)
    case invalidResource(String)
    case registrationFailed(String)
}

/// Two immutable, process-local font registrations. Bootstrap calls prepare()
/// before publishing settings; a first Font producer can also initialize them.
/// Never unregister on settings/account reload: existing CTLines retain faces.
public enum ExteralessFontFamily {
    private struct Resource {
        let name: String
        let byteCount: Int
        let sha256: String
        let postScriptName: String
    }

    private final class RegisteredFonts: @unchecked Sendable {
        let regular: CTFont
        let italic: CTFont
        // Own the providers/checked bytes as well as the CoreText templates.
        let graphicsFonts: [CGFont]

        init(regular: (CGFont, CTFont), italic: (CGFont, CTFont)) {
            self.regular = regular.1
            self.italic = italic.1
            self.graphicsFonts = [regular.0, italic.0]
        }
    }

    private static let weightAxis: UInt32 = 0x77676874 // wght
    private static let widthAxis: UInt32 = 0x77647468 // wdth

    // See Resources/Fonts/ExteralessRoboto/pins.json. Both faces are the same
    // upstream release; filenames are namespaced, internal names are unmodified.
    private static let registered: Result<RegisteredFonts, ExteralessFontFamilyError> = {
        do {
            let regular = try ExteralessFontFamily.load(Resource(name: "ExteralessRoboto-Regular", byteCount: 488584,
                sha256: "d7598e12c5dbef095ff8272cfc55da0250bd07fbdecbac8a530b9b277872a134", postScriptName: "Roboto-Regular"))
            let italic = try ExteralessFontFamily.load(Resource(name: "ExteralessRoboto-Italic", byteCount: 530944,
                sha256: "9725a847af6b460ffca162ae66d20dad48b01876137947180b42d7dcd7887182", postScriptName: "Roboto-Italic"))
            let fonts = RegisteredFonts(regular: regular, italic: italic)
            for graphicsFont in fonts.graphicsFonts {
                // A name collision is not evidence that these exact bytes were
                // registered. Report it rather than accepting a different face.
                guard CTFontManagerRegisterGraphicsFont(graphicsFont, nil) else {
                    throw ExteralessFontFamilyError.registrationFailed(graphicsFont.postScriptName as String? ?? "Roboto")
                }
            }
            return .success(fonts)
        } catch let error as ExteralessFontFamilyError {
            return .failure(error)
        } catch {
            return .failure(.invalidResource("Roboto"))
        }
    }()

    /// Synchronous and idempotent, including failure. Stage the resources in the
    /// main bundle of each consuming process, not only in a framework/app parent.
    public static func prepare() throws {
        _ = try self.registered.get()
    }

    private static func load(_ resource: Resource) throws -> (CGFont, CTFont) {
        guard let url = Bundle.main.url(forResource: resource.name, withExtension: "ttf") else {
            throw ExteralessFontFamilyError.missingResource(resource.name)
        }
        let data: Data
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == resource.byteCount else {
                throw ExteralessFontFamilyError.invalidResource(resource.name)
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ExteralessFontFamilyError.invalidResource(resource.name)
        }
        guard data.count == resource.byteCount, ToolsSHA256.hex(data) == resource.sha256,
              let provider = CGDataProvider(data: data as CFData), let graphicsFont = CGFont(provider),
              graphicsFont.postScriptName as String? == resource.postScriptName else {
            throw ExteralessFontFamilyError.invalidResource(resource.name)
        }
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 17.0, nil, nil)
        guard let axes = CTFontCopyVariationAxes(font) as? [NSDictionary],
              axes.contains(where: { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value == self.weightAxis }),
              axes.contains(where: { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value == self.widthAxis }) else {
            throw ExteralessFontFamilyError.invalidResource(resource.name)
        }
        return (graphicsFont, font)
    }

    static func selection(design: Font.Design, width: Font.Width, traits: Font.Traits) -> CoreAppearanceFontFamilyPolicy.Selection {
        // Roboto has a real 75...100 width axis. Do not collapse the explicit SF
        // compressed/expanded or alternate-dollar glyph roles into normal text.
        if width == .compressed || width == .expanded || traits.contains(.alternateDollarSign) {
            return .nativeRole
        }
        let role: CoreAppearanceFontFamilyPolicy.Role
        switch design {
        case .regular: role = .sansSerif
        case .serif: role = .serif
        case .monospace: role = .monospace
        case .round: role = .rounded
        case .camera: role = .camera
        }
        return CoreAppearanceFontFamilyPolicy.selection(useSystemFonts: CoreAppearanceFontFamilyPolicy.useSystemFonts(), role: role)
    }

    static func font(size: CGFloat, weight: Font.Weight, width: Font.Width, traits: Font.Traits) -> UIFont? {
        // Bootstrap surfaces a packaging/registration failure. An early producer
        // still has a usable native fallback and never caches a fake Roboto name.
        guard case let .success(fonts) = self.registered else { return nil }
        let template = traits.contains(.italic) ? fonts.italic : fonts.regular
        let value: Double
        switch weight {
        case .thin: value = 200
        case .light: value = 300
        case .regular: value = 400
        case .medium: value = 500
        case .semibold: value = 600
        case .bold: value = 700
        case .heavy: value = 800
        }
        var attributes: [CFString: Any] = [
            kCTFontVariationAttribute: [
                NSNumber(value: self.weightAxis): NSNumber(value: value),
                NSNumber(value: self.widthAxis): NSNumber(value: width == .condensed ? 75.0 : 100.0)
            ]
        ]
        var system = UIFont.systemFont(ofSize: size, weight: weight.weight)
        if traits.contains(.italic), let descriptor = system.fontDescriptor.withSymbolicTraits(system.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            system = UIFont(descriptor: descriptor, size: size)
        }
        // Variation coordinates select the real outlines. Also retain the native
        // trait metadata used by UIFont/attributed-text formatting consumers;
        // a variable font's default face is named Regular even at bold weights.
        var symbolic = CTFontGetSymbolicTraits(system as CTFont).intersection([.traitBold, .traitItalic])
        if traits.contains(.italic) {
            symbolic.insert(.traitItalic)
        }
        attributes[kCTFontTraitsAttribute] = [
            kCTFontWeightTrait: weight.weight.rawValue,
            kCTFontSymbolicTrait: symbolic.rawValue
        ] as [CFString: Any]
        if let cascade = CTFontCopyDefaultCascadeListForLanguages(system as CTFont, nil) {
            attributes[kCTFontCascadeListAttribute] = cascade
        }
        if traits.contains(.monospacedNumbers) {
            attributes[kCTFontFeatureSettingsAttribute] = [[
                kCTFontOpenTypeFeatureTag: "tnum",
                kCTFontOpenTypeFeatureValue: 1
            ] as [CFString: Any]]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        // Copy the checked, retained font, rather than looking up a family alias.
        // Point size is already the caller's size (including Dynamic Type).
        // CoreText owns shaping/fallback; no UTF-16 range or entity is rewritten.
        return CTFontCreateCopyWithAttributes(template, size, nil, descriptor) as UIFont
    }
}
