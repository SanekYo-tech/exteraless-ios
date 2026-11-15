import AccountContext
import Display
import ExteralessCore
import Foundation
import PhotoResources
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

public struct ExteralessPlayerPalette {
    public let surface: UIColor
    public let elevated: UIColor
    public let primary: UIColor
    public let text: UIColor
    public let secondary: UIColor

    public init(surface: UIColor, elevated: UIColor, primary: UIColor, text: UIColor, secondary: UIColor) {
        self.surface = surface; self.elevated = elevated; self.primary = primary
        self.text = text; self.secondary = secondary
    }

    static func make(theme: PresentationTheme, image: UIImage?, fromArtwork: Bool) -> Self {
        guard fromArtwork, let image = image?.cgImage else {
            return Self(surface: theme.list.blocksBackgroundColor, elevated: theme.list.itemBlocksBackgroundColor, primary: theme.list.itemAccentColor, text: theme.list.itemPrimaryTextColor, secondary: theme.list.itemSecondaryTextColor)
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let sampled = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard sampled, pixel[3] > 0 else { return make(theme: theme, image: nil, fromArtwork: false) }
        let color = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let dark = theme.overallDarkAppearance
        let surface = UIColor(hue: hue, saturation: min(0.24, saturation * 0.35), brightness: dark ? 0.13 : 0.97, alpha: 1)
        let elevated = UIColor(hue: hue, saturation: min(0.32, saturation * 0.45), brightness: dark ? 0.22 : 0.90, alpha: 1)
        let primary = UIColor(hue: hue, saturation: max(0.35, min(0.65, saturation)), brightness: dark ? 0.96 : 0.48, alpha: 1)
        let text: UIColor = dark ? .white : UIColor(white: 0.08, alpha: 1)
        return Self(surface: surface, elevated: elevated, primary: primary, text: text, secondary: text.withAlphaComponent(0.68))
    }
}

/// Artwork comes from Telegram's real cached embedded/thumbnail/album-art path,
/// with its FileMediaReference intact. The parent owns this view's frame.
final class ExteralessPlayerArtworkView: UIView {
    private let imageView = UIImageView()
    private let discHole = UIView()
    private let discRings = CAShapeLayer()
    private let disposable = MetaDisposable()
    private var resource: String?
    private var albumArt: SharedMediaPlaybackAlbumArt?
    private var style = PlayerStylePolicy()
    private var rotating = false
    private var discAngle: CGFloat = 0
    private(set) var image: UIImage?
    var imageChanged: ((UIImage?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerCurve = .continuous
        addSubview(imageView)
        imageView.layer.addSublayer(discRings)
        discRings.fillColor = UIColor.clear.cgColor
        discRings.strokeColor = UIColor(white: 0, alpha: 0.22).cgColor
        discRings.lineWidth = 1
        discHole.isUserInteractionEnabled = false
        addSubview(discHole)
        isAccessibilityElement = true
        accessibilityLabel = "Album artwork"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { disposable.dispose() }

    func update(context: AccountContext, state: SharedMediaPlayerItemPlaybackState?, style: PlayerStylePolicy, playing: Bool, visible: Bool, surface: UIColor) {
        self.style = style
        let file: FileMediaReference?
        if let source = state?.item.playbackData?.source, case let .telegramFile(reference, _, _) = source { file = reference } else { file = nil }
        let albumArt: SharedMediaPlaybackAlbumArt?
        if let data = state?.item.displayData, case let .music(_, _, value, _, _) = data { albumArt = value } else { albumArt = nil }
        let resource = file?.media.resource.id.stringRepresentation
        if self.resource != resource || self.albumArt != albumArt {
            self.resource = resource
            self.albumArt = albumArt
            image = nil
            imageView.image = nil
            imageChanged?(nil)
            disposable.set(nil)
            if file != nil {
                let size = CGSize(width: 320, height: 320)
                let arguments = TransformImageArguments(corners: ImageCorners(radius: 0), imageSize: size, boundingSize: size, intrinsicInsets: .zero)
                disposable.set((playerAlbumArt(engine: context.engine, fileReference: file, albumArt: albumArt, thumbnail: false)
                |> map { draw in draw(arguments)?.generateImage() }
                |> deliverOnMainQueue).start(next: { [weak self] image in
                    guard let self, self.resource == resource else { return }
                    self.image = image
                    self.imageView.image = image
                    self.imageChanged?(image)
                }))
            }
        }
        updatePresentation(style: style, playing: playing, visible: visible, surface: surface)
    }

    func updateVisual(image: UIImage?, style: PlayerStylePolicy, playing: Bool, visible: Bool, surface: UIColor) {
        resource = nil
        albumArt = nil
        disposable.set(nil)
        self.image = image
        imageView.image = image
        updatePresentation(style: style, playing: playing, visible: visible, surface: surface)
    }

    private func updatePresentation(style: PlayerStylePolicy, playing: Bool, visible: Bool, surface: UIColor) {
        self.style = style
        imageView.backgroundColor = surface
        discHole.backgroundColor = surface
        discHole.isHidden = style.cover != .disc
        discRings.isHidden = style.cover != .disc
        let rotates = style.rotatesDisc(playing: playing, visible: visible && window != nil, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        setRotating(rotates)
        if style.cover != .disc {
            discAngle = 0
            imageView.transform = .identity
        }
        setNeedsLayout()
    }

    func stopLoading() { disposable.set(nil); resource = nil; setRotating(false) }

    func clear() {
        disposable.set(nil)
        resource = nil
        albumArt = nil
        image = nil
        imageView.image = nil
        setRotating(false)
    }

    private func setRotating(_ value: Bool) {
        guard value != rotating else { return }
        rotating = value
        if value {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = discAngle
            rotation.toValue = discAngle + .pi * 2
            rotation.duration = 20
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            imageView.layer.add(rotation, forKey: "exteraless.disc")
        } else {
            if let angle = imageView.layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber { discAngle = CGFloat(angle.doubleValue) }
            imageView.layer.removeAnimation(forKey: "exteraless.disc")
            imageView.transform = CGAffineTransform(rotationAngle: discAngle)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setRotating(false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds/center keep resizing deterministic while the disc is rotating.
        imageView.bounds = bounds
        imageView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        imageView.layer.cornerRadius = style.cover == .disc ? min(bounds.width, bounds.height) / 2 : min(CGFloat(style.coverRadius), min(bounds.width, bounds.height) / 2)
        let hole = min(bounds.width, bounds.height) * 0.075
        discHole.frame = CGRect(x: bounds.midX - hole / 2, y: bounds.midY - hole / 2, width: hole, height: hole)
        discHole.layer.cornerRadius = hole / 2
        discRings.frame = bounds
        let rings = UIBezierPath()
        let side = min(bounds.width, bounds.height)
        for ratio in [CGFloat(0.12), 0.17, 0.40, 0.44, 0.48] {
            let radius = side * ratio
            rings.append(UIBezierPath(ovalIn: CGRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)))
        }
        discRings.path = rings.cgPath
    }
}
