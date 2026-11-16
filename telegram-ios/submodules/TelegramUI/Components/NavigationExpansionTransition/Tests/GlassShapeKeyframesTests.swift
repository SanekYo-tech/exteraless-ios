import XCTest
import UIKit
import Display
import ExteralessCore
import GlassBackgroundComponent

final class GlassShapeKeyframesTests: XCTestCase {
    @MainActor
    private func layers(_ layer: CALayer) -> [CALayer] {
        return [layer] + ((layer.sublayers ?? []) + [layer.mask].compactMap { $0 }).flatMap { self.layers($0) }
    }

    private func appearanceStore() throws -> ClientSettings {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-glass-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try ClientSettings(storageURL: directory.appendingPathComponent("settings.json"))
        try store.register(AppearanceFeatures.definitions)
        return store
    }

    // The card's corners: capsule while short, the screen's once tall — keyframed as given, not half the shorter side.
    @MainActor
    func test_animateShape_keyframesTheGivenRadii() {
        let glass = GlassBackgroundView()
        glass.frame = CGRect(x: 0.0, y: 0.0, width: 140.0, height: 44.0)
        let timing = NavigationKeyframeTiming(origin: .explicit(CACurrentMediaTime()), duration: 0.1, factor: 1.0)
        let sizes = timing.sampleTimes.map { t in CGSize(width: 140.0 + 2000.0 * CGFloat(t), height: 44.0 + 4000.0 * CGFloat(t)) }
        let radii = sizes.map { min(min($0.width, $0.height) * 0.5, 55.0) }
        glass.animateShape(sizes: sizes, cornerRadii: radii, timing: timing, isDark: false, tintColor: .init(kind: .panel))
        let animations = self.layers(glass.layer).compactMap { $0.animation(forKey: "navigationGlass.cornerRadius") as? CAKeyframeAnimation }
        XCTAssertFalse(animations.isEmpty)
        for animation in animations {
            let values = (animation.values ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            XCTAssertEqual(values.count, radii.count)
            XCTAssertEqual(values.last ?? 0.0, 55.0, accuracy: 0.001, "capped at the screen's corner")
        }
    }

    // Four radii per sample (iPhone Duo's cover screen, 8 pt on the hinge side): keyframed as the layer's own per-corner
    // radii, and the model (a custom shape) is the last of them.
    @MainActor
    func test_animateShape_fourRadii_keyframesTheLayersCornerRadii() throws {
        try XCTSkipUnless(CALayer.cornerRadiiSupported)
        let glass = GlassBackgroundView()
        glass.frame = CGRect(x: 0.0, y: 0.0, width: 140.0, height: 44.0)
        let timing = NavigationKeyframeTiming(origin: .explicit(CACurrentMediaTime()), duration: 0.1, factor: 1.0)
        let sizes = timing.sampleTimes.map { t in CGSize(width: 140.0 + 2000.0 * CGFloat(t), height: 44.0 + 4000.0 * CGFloat(t)) }
        let radii = sizes.map { size -> GlassBackgroundView.CornerRadii in
            let capsule = min(size.width, size.height) * 0.5
            return GlassBackgroundView.CornerRadii(topLeft: min(capsule, 8.0), topRight: min(capsule, 59.0), bottomLeft: min(capsule, 8.0), bottomRight: min(capsule, 59.0))
        }
        glass.animateShape(sizes: sizes, cornerRadii: radii, timing: timing, isDark: false, tintColor: .init(kind: .panel))
        let animated = self.layers(glass.layer).filter { $0.animation(forKey: "navigationGlass.cornerRadii") != nil }
        XCTAssertFalse(animated.isEmpty)
        for layer in animated {
            let animation = layer.animation(forKey: "navigationGlass.cornerRadii") as? CAKeyframeAnimation
            let values = (animation?.values ?? []).compactMap { ($0 as? NSValue).flatMap { CornerRadii(boxedValue: $0) } }
            XCTAssertEqual(values.count, radii.count)
            XCTAssertEqual(values.last, CornerRadii(topLeft: 8.0, topRight: 59.0, bottomLeft: 8.0, bottomRight: 59.0))
            XCTAssertEqual(layer.cornerRadii, values.last, "the model is the last keyframe")
        }
    }

    @MainActor
    func testAppearanceTintOutlineAndFallbackMasksShareEveryShapeSample() throws {
        let settings = try self.appearanceStore()
        let previousLegacy = GlassBackgroundView.useCustomGlassImpl
        defer { GlassBackgroundView.useCustomGlassImpl = previousLegacy }
        let timing = NavigationKeyframeTiming(origin: .explicit(CACurrentMediaTime() + 1), duration: 0.1, factor: 10)
        let sizes = timing.sampleTimes.map { CGSize(width: 140 + 2000 * CGFloat($0), height: 44 + 4000 * CGFloat($0)) }
        let radii = sizes.map { min(min($0.width, $0.height) * 0.5, 55) }
        for legacy in [false, true] {
            GlassBackgroundView.useCustomGlassImpl = legacy
            for mode in [0, 1, 2] {
                for opaque in [false, true] where mode != 0 || opaque {
                    try settings.set(.integer(Int64(mode)), for: "appearance.glassOutlineStyle")
                    let glass = GlassBackgroundView(frame: CGRect(origin: .zero, size: sizes[0]), appearanceSettings: settings)
                    if opaque { glass.exteralessOpaqueFillColor = .white }
                    glass.animateShape(sizes: sizes, cornerRadii: radii, timing: timing, isDark: false, tintColor: .init(kind: .panel))
                    let owned = self.layers(glass.layer).filter { $0.name?.hasPrefix("appearance.glass.") == true }
                    var names = Set(["appearance.glass.tint", "appearance.glass.tintMask", "appearance.glass.outline"])
                    var legacyBackend = legacy
                    if #unavailable(iOS 26.0) { legacyBackend = true }
                    if legacyBackend && !opaque { names.formUnion(["appearance.glass.fallbackBlur", "appearance.glass.fallbackMask"]) }
                    XCTAssertEqual(Set(owned.compactMap(\.name)), names)
                    for layer in owned {
                        let bounds = try XCTUnwrap(layer.animation(forKey: "navigationGlass.bounds") as? CAKeyframeAnimation)
                        let values = (bounds.values ?? []).compactMap { ($0 as? NSValue)?.cgRectValue.size }
                        XCTAssertEqual(values, sizes, layer.name ?? "")
                        XCTAssertEqual(bounds.keyTimes, timing.sampleTimes.map { NSNumber(value: $0 / timing.duration) })
                        XCTAssertEqual(bounds.speed, 0.1, accuracy: 0.00001)
                        XCTAssertEqual(bounds.beginTime, layer.convertTime({ if case let .explicit(value) = timing.origin { return value }; return 0 }(), from: nil), accuracy: 0.00001)
                        if let shape = layer as? CAShapeLayer {
                            let animation = try XCTUnwrap(layer.animation(forKey: "navigationGlass.path") as? CAKeyframeAnimation)
                            let paths = (animation.values ?? []).map { $0 as! CGPath }
                            XCTAssertEqual(paths.count, sizes.count)
                            let inset: CGFloat = layer.name == "appearance.glass.outline" ? 1 : 0
                            for (index, path) in paths.enumerated() {
                                XCTAssertEqual(path.boundingBoxOfPath.width, sizes[index].width - inset, accuracy: 0.00001)
                                XCTAssertEqual(path.boundingBoxOfPath.height, sizes[index].height - inset, accuracy: 0.00001)
                            }
                            let modelPath = try XCTUnwrap(shape.path)
                            let finalPath = try XCTUnwrap(paths.last)
                            XCTAssertTrue(modelPath == finalPath)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testAsymmetricPathsOrdinaryTransitionsAndCancelRestoreAllAppearanceLayers() throws {
        let settings = try self.appearanceStore()
        try settings.set(.integer(1), for: "appearance.glassOutlineStyle")
        let previousLegacy = GlassBackgroundView.useCustomGlassImpl
        GlassBackgroundView.useCustomGlassImpl = true
        defer { GlassBackgroundView.useCustomGlassImpl = previousLegacy }
        let small = CGSize(width: 140, height: 44)
        let glass = GlassBackgroundView(frame: CGRect(origin: .zero, size: small), appearanceSettings: settings)
        let timing = NavigationKeyframeTiming(origin: .explicit(CACurrentMediaTime() + 1), duration: 0.1, factor: 1)
        let sizes = timing.sampleTimes.map { CGSize(width: 140 + 2000 * CGFloat($0), height: 44 + 4000 * CGFloat($0)) }
        let corners = sizes.map { _ in GlassBackgroundView.CornerRadii(topLeft: 0, topRight: 59, bottomLeft: 8, bottomRight: 32) }
        glass.animateShape(sizes: sizes, cornerRadii: corners, timing: timing, isDark: true, tintColor: .init(kind: .panel))
        let shapes = self.layers(glass.layer).compactMap { $0 as? CAShapeLayer }.filter { $0.name?.hasPrefix("appearance.glass.") == true }
        XCTAssertEqual(shapes.count, 3, "tint, outline, older-iOS blur mask")
        for shape in shapes {
            let animation = try XCTUnwrap(shape.animation(forKey: "navigationGlass.path") as? CAKeyframeAnimation)
            let paths = (animation.values ?? []).map { $0 as! CGPath }
            XCTAssertTrue(try XCTUnwrap(paths.first).contains(CGPoint(x: 1, y: 1)), "square top-left is preserved")
            XCTAssertFalse(try XCTUnwrap(paths.first).contains(CGPoint(x: 139, y: 1)), "rounded top-right is preserved")
        }

        // Same actual update API used outside a sampled navigation transition.
        glass.update(size: small, cornerRadius: 12, isDark: true, tintColor: .init(kind: .panel), transition: .easeInOut(duration: 0.2))
        for shape in shapes {
            XCTAssertNil(shape.animation(forKey: "navigationGlass.path"))
            XCTAssertNotNil(shape.animation(forKey: "path"), "ordinary path transition must not jump to final shape")
        }
        glass.cancelShapeAnimations()
        glass.update(size: small, cornerRadius: 12, isDark: true, tintColor: .init(kind: .panel), transition: .init(animation: .none))
        for layer in self.layers(glass.layer) where layer.name?.hasPrefix("appearance.glass.") == true {
            XCTAssertFalse(layer.animationKeys()?.contains { $0.hasPrefix("navigationGlass.") || ["path", "position", "bounds", "bounds.size"].contains($0) } ?? false)
            XCTAssertEqual(layer.bounds.size, small)
        }
        try settings.set(.integer(0), for: "appearance.glassOutlineStyle")
        glass.update(size: small, cornerRadius: 12, isDark: true, tintColor: .init(kind: .panel), transition: .init(animation: .none))
        XCTAssertTrue(self.layers(glass.layer).first { $0.name == "appearance.glass.outline" }?.isHidden == true)
        XCTAssertFalse(self.layers(glass.layer).contains { $0.name == "appearance.glass.fallbackBlur" })
    }
}
