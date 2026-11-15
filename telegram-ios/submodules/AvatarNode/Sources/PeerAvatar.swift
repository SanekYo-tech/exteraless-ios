import Foundation
import ExteralessCore
import UIKit
import SwiftSignalKit
import Display
import ImageIO
import TelegramCore
import TinyThumbnail
import FastBlur
import Postbox

private let roundCorners = { () -> UIImage in
    let diameter: CGFloat = 60.0
    UIGraphicsBeginImageContextWithOptions(CGSize(width: diameter, height: diameter), false, 0.0)
    let context = UIGraphicsGetCurrentContext()!
    context.setBlendMode(.copy)
    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(origin: CGPoint(), size: CGSize(width: diameter, height: diameter)))
    context.setFillColor(UIColor.clear.cgColor)
    context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: diameter, height: diameter)))
    let image = UIGraphicsGetImageFromCurrentImageContext()!.stretchableImage(withLeftCapWidth: Int(diameter / 2.0), topCapHeight: Int(diameter / 2.0))
    UIGraphicsEndImageContext()
    return image
}()

public enum PeerAvatarImageType {
    case blurred
    case complete
}

/// Supplies encoded avatar data to the production decoder/compositor. A nil
/// source means no representation; an emitted nil is a pending image.
public typealias PeerAvatarImageDataProvider = (TelegramMediaImageRepresentation, Bool) -> Signal<(Data, PeerAvatarImageType)?, NoError>?

public func peerAvatarImageData(postbox: Postbox, peerReference: PeerReference?, authorOfMessage: MessageReference?, representation: TelegramMediaImageRepresentation?, synchronousLoad: Bool) -> Signal<(Data, PeerAvatarImageType)?, NoError>? {
    if let smallProfileImage = representation {
        let resourceData = postbox.mediaBox.resourceData(smallProfileImage.resource, attemptSynchronously: synchronousLoad)
        let imageData = resourceData
        |> take(1)
        |> mapToSignal { maybeData -> Signal<(Data, PeerAvatarImageType)?, NoError> in
            if maybeData.complete {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path)) {
                    return .single((data, .complete))
                } else {
                    return .single(nil)
                }
            } else {
                return Signal { subscriber in
                    var emittedFirstData = false
                    if let miniData = representation?.immediateThumbnailData, let decodedData = decodeTinyThumbnail(data: miniData) {
                        emittedFirstData = true
                        subscriber.putNext((decodedData, .blurred))
                    }

                    let resourceDataDisposable = resourceData.start(next: { data in
                        if data.complete {
                            if let dataValue = try? Data(contentsOf: URL(fileURLWithPath: data.path)) {
                                subscriber.putNext((dataValue, .complete))
                            } else {
                                subscriber.putNext(nil)
                            }
                            subscriber.putCompletion()
                        } else {
                            if !emittedFirstData {
                                subscriber.putNext(nil)
                            }
                        }
                    }, error: { _ in
                    }, completed: {
                        subscriber.putCompletion()
                    })
                    var fetchedDataDisposable: Disposable?
                    if let peerReference = peerReference {
                        fetchedDataDisposable = fetchedMediaResource(mediaBox: postbox.mediaBox, userLocation: .other, userContentType: .avatar, reference: .avatar(peer: peerReference, resource: smallProfileImage.resource), statsCategory: .generic).start()
                    } else if let authorOfMessage = authorOfMessage {
                        fetchedDataDisposable = fetchedMediaResource(mediaBox: postbox.mediaBox, userLocation: .other, userContentType: .avatar, reference: .messageAuthorAvatar(message: authorOfMessage, resource: smallProfileImage.resource), statsCategory: .generic).start()
                    } else {
                        fetchedDataDisposable = fetchedMediaResource(mediaBox: postbox.mediaBox, userLocation: .other, userContentType: .avatar, reference: .standalone(resource: smallProfileImage.resource), statsCategory: .generic).start()
                    }
                    return ActionDisposable {
                        resourceDataDisposable.dispose()
                        fetchedDataDisposable?.dispose()
                    }
                }
            }
        }
        return imageData
    } else {
        return nil
    }
}

public func peerAvatarCompleteImage(account: Account, peer: EnginePeer, forceProvidedRepresentation: Bool = false, representation: TelegramMediaImageRepresentation? = nil, size: CGSize, round: Bool = true, font: UIFont = avatarPlaceholderFont(size: 13.0), drawLetters: Bool = true, fullSize: Bool = false, blurred: Bool = false) -> Signal<UIImage?, NoError> {
    return peerAvatarCompleteImage(
        postbox: account.postbox,
        peer: peer,
        forceProvidedRepresentation: forceProvidedRepresentation,
        representation: representation,
        size: size,
        round: round,
        font: font,
        drawLetters: drawLetters,
        fullSize: fullSize,
        blurred: blurred,
        identityPresentation: exteralessIdentityPresentation(account: account, peer: peer)
    )
}

public func peerAvatarCompleteImage(postbox: Postbox, peer: EnginePeer, forceProvidedRepresentation: Bool = false, representation: TelegramMediaImageRepresentation? = nil, size: CGSize, round: Bool = true, font: UIFont = avatarPlaceholderFont(size: 13.0), drawLetters: Bool = true, fullSize: Bool = false, blurred: Bool = false, identityPresentation: ExteralessPeerIdentityPresentation? = nil) -> Signal<UIImage?, NoError> {
    return peerAvatarCompleteImage(peer: peer, forceProvidedRepresentation: forceProvidedRepresentation, representation: representation, size: size, round: round, font: font, drawLetters: drawLetters, fullSize: fullSize, blurred: blurred, identityPresentation: identityPresentation, imageDataProvider: { representation, synchronousLoad in
        peerAvatarImageData(postbox: postbox, peerReference: PeerReference(peer), authorOfMessage: nil, representation: representation, synchronousLoad: synchronousLoad)
    })
}

/// Account-independent entry to the same complete-image path, including forum
/// selection, photo decoding, fallback initials and caller font/unrounded choice.
public func peerAvatarCompleteImage(peer: EnginePeer, forceProvidedRepresentation: Bool = false, representation: TelegramMediaImageRepresentation? = nil, size: CGSize, round: Bool = true, font: UIFont = avatarPlaceholderFont(size: 13.0), drawLetters: Bool = true, fullSize: Bool = false, blurred: Bool = false, identityPresentation: ExteralessPeerIdentityPresentation? = nil, appearanceSettings: ClientSettings = .shared, imageDataProvider: @escaping PeerAvatarImageDataProvider) -> Signal<UIImage?, NoError> {
    let iconSignal: Signal<UIImage?, NoError>
    
    let nativeClipStyle: AvatarNodeClipStyle
    if round {
        if case let .channel(channel) = peer, channel.isForumOrMonoForum {
            nativeClipStyle = .roundedRect
        } else {
            nativeClipStyle = .round
        }
    } else {
        nativeClipStyle = .none
    }
    let policy = AppearanceAvatarPolicy(corners: appearanceSettings.integer("appearance.avatarCorners", default: 28), singleRadius: appearanceSettings.bool("appearance.singleCornerRadius"))
    let clipStyle = nativeClipStyle.withExteralessShape(size: size, policy: policy)

    func imageSignal(_ representation: TelegramMediaImageRepresentation?, synchronousLoad: Bool, blurred: Bool) -> Signal<(UIImage, UIImage)?, NoError>? {
        guard let representation else { return nil }
        return peerAvatarImage(imageData: imageDataProvider(representation, synchronousLoad), displayDimensions: size, resolvedClipStyle: clipStyle, blurred: blurred, synchronousLoad: synchronousLoad)
    }
    
    let thumbnailRepresentation: TelegramMediaImageRepresentation?
    if forceProvidedRepresentation {
        thumbnailRepresentation = representation
    } else {
        thumbnailRepresentation = peer.profileImageRepresentations.first
    }
    
    if let signal = imageSignal(thumbnailRepresentation, synchronousLoad: fullSize, blurred: blurred) {
        if fullSize, let fullSizeSignal = imageSignal(peer.profileImageRepresentations.last, synchronousLoad: true, blurred: blurred) {
            iconSignal = combineLatest(.single(nil) |> then(signal), .single(nil) |> then(fullSizeSignal))
            |> mapToSignal { thumbnailImage, fullSizeImage -> Signal<UIImage?, NoError> in
                if let fullSizeImage = fullSizeImage {
                    return .single(fullSizeImage.0)
                } else if let thumbnailImage = thumbnailImage {
                    return .single(thumbnailImage.0)
                } else {
                    return .complete()
                }
            }
        } else {
            iconSignal = signal
            |> map { imageVersions -> UIImage? in
                return imageVersions?.0
            }
        }
    } else {
        let peerId = peer.id
        var displayLetters = (identityPresentation?.letters ?? peer.displayLetters).map { exteralessZalgoDisplayText($0) }
        if displayLetters.count == 2 && displayLetters[0].isSingleEmoji && displayLetters[1].isSingleEmoji {
            displayLetters = [displayLetters[0]]
        }
        if !drawLetters {
            displayLetters = []
        }
        iconSignal = Signal { subscriber in
            let image = generateImage(size, rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                drawPeerAvatarLetters(context: context, size: size, resolvedClipStyle: clipStyle, font: font, letters: displayLetters, peerId: peerId, nameColor: identityPresentation?.nameColor ?? peer.nameColor)
                if blurred {
                    clipPeerAvatarLetters(context: context, size: size, clipStyle: clipStyle)
                    context.setFillColor(UIColor(rgb: 0x000000, alpha: 0.5).cgColor)
                    context.fill(CGRect(origin: CGPoint(), size: size))
                }
            })?.withRenderingMode(.alwaysOriginal)
            
            subscriber.putNext(image)
            subscriber.putCompletion()
            return EmptyDisposable
        }
    }
    return iconSignal
}

public func peerAvatarImage(account: Account, peerReference: PeerReference?, authorOfMessage: MessageReference?, representation: TelegramMediaImageRepresentation?, displayDimensions: CGSize = CGSize(width: 60.0, height: 60.0), clipStyle: AvatarNodeClipStyle = .round, blurred: Bool = false, inset: CGFloat = 0.0, emptyColor: UIColor? = nil, synchronousLoad: Bool = false, provideUnrounded: Bool = false, cutoutRect: CGRect? = nil) -> Signal<(UIImage, UIImage)?, NoError>? {
    return peerAvatarImage(
        postbox: account.postbox,
        peerReference: peerReference,
        authorOfMessage: authorOfMessage,
        representation: representation,
        displayDimensions: displayDimensions,
        clipStyle: clipStyle,
        blurred: blurred,
        inset: inset,
        emptyColor: emptyColor,
        synchronousLoad: synchronousLoad,
        provideUnrounded: provideUnrounded,
        cutoutRect: cutoutRect
    )
}
    
public func peerAvatarImage(postbox: Postbox, peerReference: PeerReference?, authorOfMessage: MessageReference?, representation: TelegramMediaImageRepresentation?, displayDimensions: CGSize = CGSize(width: 60.0, height: 60.0), clipStyle: AvatarNodeClipStyle = .round, blurred: Bool = false, inset: CGFloat = 0.0, emptyColor: UIColor? = nil, synchronousLoad: Bool = false, provideUnrounded: Bool = false, cutoutRect: CGRect? = nil) -> Signal<(UIImage, UIImage)?, NoError>? {
    let clipStyle = clipStyle.withExteralessShape(size: displayDimensions)
    return peerAvatarImage(imageData: peerAvatarImageData(postbox: postbox, peerReference: peerReference, authorOfMessage: authorOfMessage, representation: representation, synchronousLoad: synchronousLoad), displayDimensions: displayDimensions, resolvedClipStyle: clipStyle, blurred: blurred, inset: inset, emptyColor: emptyColor, synchronousLoad: synchronousLoad, provideUnrounded: provideUnrounded, cutoutRect: cutoutRect)
}

/// Decodes cached or delivered bytes using an already resolved contour. In
/// particular, a native forum fraction must not be re-resolved as a regular avatar.
public func peerAvatarImage(imageData: Signal<(Data, PeerAvatarImageType)?, NoError>?, displayDimensions: CGSize, resolvedClipStyle clipStyle: AvatarNodeClipStyle, blurred: Bool = false, inset: CGFloat = 0, emptyColor: UIColor? = nil, synchronousLoad: Bool = false, provideUnrounded: Bool = false, cutoutRect: CGRect? = nil) -> Signal<(UIImage, UIImage)?, NoError>? {
    if let imageData {
        return imageData
        |> mapToSignal { data -> Signal<(UIImage, UIImage)?, NoError> in
            let generate = deferred { () -> Signal<(UIImage, UIImage)?, NoError> in
                if emptyColor == nil && data == nil {
                    return .single(nil)
                }
                let roundedImage = generateImage(displayDimensions, contextGenerator: { size, context -> Void in
                    if let (data, dataType) = data {
                        if let imageSource = CGImageSourceCreateWithData(data as CFData, nil), var dataImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                            context.clear(CGRect(origin: CGPoint(), size: displayDimensions))
                            context.setBlendMode(.copy)
                            
                            switch clipStyle {
                            case .none:
                                break
                            case .round:
                                if displayDimensions.width != 60.0 {
                                    context.addEllipse(in: CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                                    context.clip()
                                }
                            case .roundedRect:
                                context.addPath(UIBezierPath(roundedRect: CGRect(x: 0.0, y: 0.0, width: displayDimensions.width, height: displayDimensions.height).insetBy(dx: inset, dy: inset), cornerRadius: floor(displayDimensions.width * 0.25)).cgPath)
                                context.clip()
                            case let .exteralessRoundedRect(fraction):
                                context.addPath(UIBezierPath(roundedRect: CGRect(origin: .zero, size: displayDimensions).insetBy(dx: inset, dy: inset), cornerRadius: min(displayDimensions.width, displayDimensions.height) * fraction).cgPath)
                                context.clip()
                            case .bubble:
                                let rect = CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset)
                                context.translateBy(x: rect.midX, y: rect.midY)
                                context.scaleBy(x: 1.0, y: -1.0)
                                context.translateBy(x: -rect.midX, y: -rect.midY)
                                AvatarNode.addAvatarBubblePath(context: context, rect: rect)
                                context.translateBy(x: rect.midX, y: rect.midY)
                                context.scaleBy(x: 1.0, y: -1.0)
                                context.translateBy(x: -rect.midX, y: -rect.midY)
                                context.clip()
                            }

                            var shouldBlur = false
                            if case .blurred = dataType {
                                shouldBlur = true
                            } else if blurred {
                                shouldBlur = true
                            }
                            if shouldBlur {
                                let imageContextSize = size.width > 200.0 ? CGSize(width: 192.0, height: 192.0) : CGSize(width: 64.0, height: 64.0)
                                if let imageContext = DrawingContext(size: imageContextSize, scale: 1.0, clear: true) {
                                    imageContext.withFlippedContext { c in
                                        c.draw(dataImage, in: CGRect(origin: CGPoint(), size: imageContextSize))
                                        
                                        context.setBlendMode(.saturation)
                                        context.setFillColor(UIColor(rgb: 0xffffff, alpha: 1.0).cgColor)
                                        context.fill(CGRect(origin: CGPoint(), size: size))
                                        context.setBlendMode(.copy)
                                    }
                                    
                                    telegramFastBlurMore(Int32(imageContext.size.width * imageContext.scale), Int32(imageContext.size.height * imageContext.scale), Int32(imageContext.bytesPerRow), imageContext.bytes)
                                    if size.width > 200.0 {
                                        telegramFastBlurMore(Int32(imageContext.size.width * imageContext.scale), Int32(imageContext.size.height * imageContext.scale), Int32(imageContext.bytesPerRow), imageContext.bytes)
                                        telegramFastBlurMore(Int32(imageContext.size.width * imageContext.scale), Int32(imageContext.size.height * imageContext.scale), Int32(imageContext.bytesPerRow), imageContext.bytes)
                                        telegramFastBlurMore(Int32(imageContext.size.width * imageContext.scale), Int32(imageContext.size.height * imageContext.scale), Int32(imageContext.bytesPerRow), imageContext.bytes)
                                        telegramFastBlurMore(Int32(imageContext.size.width * imageContext.scale), Int32(imageContext.size.height * imageContext.scale), Int32(imageContext.bytesPerRow), imageContext.bytes)
                                    }
                                    
                                    dataImage = imageContext.generateImage()!.cgImage!
                                }
                            }
                            
                            let filledSize = CGSize(width: dataImage.width, height: dataImage.height).aspectFilled(displayDimensions)
                            
                            context.draw(dataImage, in: CGRect(origin: CGPoint(x: floor((displayDimensions.width - filledSize.width) / 2.0), y: floor((displayDimensions.height - filledSize.height) / 2.0)), size: filledSize).insetBy(dx: inset, dy: inset))
                            if blurred {
                                context.setBlendMode(.normal)
                                context.setFillColor(UIColor(rgb: 0x000000, alpha: 0.45).cgColor)
                                context.fill(CGRect(origin: CGPoint(), size: size))
                                context.setBlendMode(.copy)
                            }
                            switch clipStyle {
                            case .none:
                                break
                            case .round:
                                if displayDimensions.width == 60.0 {
                                    context.setBlendMode(.destinationOut)
                                    context.draw(roundCorners.cgImage!, in: CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                                }
                            case .roundedRect, .exteralessRoundedRect:
                                break
                            case .bubble:
                                break
                            }
                        } else {
                            if let emptyColor = emptyColor {
                                context.clear(CGRect(origin: CGPoint(), size: displayDimensions))
                                context.setFillColor(emptyColor.cgColor)
                                switch clipStyle {
                                case .none:
                                    context.fill(CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                                case .round:
                                    context.fillEllipse(in: CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                                case .roundedRect:
                                    context.beginPath()
                                    context.addPath(UIBezierPath(roundedRect: CGRect(x: 0.0, y: 0.0, width: displayDimensions.width, height: displayDimensions.height).insetBy(dx: inset, dy: inset), cornerRadius: floor(displayDimensions.width * 0.25)).cgPath)
                                    context.fillPath()
                                case let .exteralessRoundedRect(fraction):
                                    context.addPath(UIBezierPath(roundedRect: CGRect(origin: .zero, size: displayDimensions).insetBy(dx: inset, dy: inset), cornerRadius: min(displayDimensions.width, displayDimensions.height) * fraction).cgPath)
                                    context.fillPath()
                                case .bubble:
                                    let rect = CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset)
                                    context.translateBy(x: rect.midX, y: rect.midY)
                                    context.scaleBy(x: 1.0, y: -1.0)
                                    context.translateBy(x: -rect.midX, y: -rect.midY)
                                    AvatarNode.addAvatarBubblePath(context: context, rect: rect)
                                    context.translateBy(x: rect.midX, y: rect.midY)
                                    context.scaleBy(x: 1.0, y: -1.0)
                                    context.translateBy(x: -rect.midX, y: -rect.midY)
                                    context.clip()
                                }
                            }
                        }
                    } else if let emptyColor = emptyColor {
                        context.clear(CGRect(origin: CGPoint(), size: displayDimensions))
                        context.setFillColor(emptyColor.cgColor)
                        
                        switch clipStyle {
                        case .none:
                            context.fill(CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                        case .round:
                            context.fillEllipse(in: CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                        case .roundedRect:
                            context.beginPath()
                            context.addPath(UIBezierPath(roundedRect: CGRect(x: 0.0, y: 0.0, width: displayDimensions.width, height: displayDimensions.height).insetBy(dx: inset, dy: inset), cornerRadius: floor(displayDimensions.width * 0.25)).cgPath)
                            context.fillPath()
                        case let .exteralessRoundedRect(fraction):
                            context.addPath(UIBezierPath(roundedRect: CGRect(origin: .zero, size: displayDimensions).insetBy(dx: inset, dy: inset), cornerRadius: min(displayDimensions.width, displayDimensions.height) * fraction).cgPath)
                            context.fillPath()
                        case .bubble:
                            let rect = CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset)
                            context.translateBy(x: rect.midX, y: rect.midY)
                            context.scaleBy(x: 1.0, y: -1.0)
                            context.translateBy(x: -rect.midX, y: -rect.midY)
                            AvatarNode.addAvatarBubblePath(context: context, rect: rect)
                            context.translateBy(x: rect.midX, y: rect.midY)
                            context.scaleBy(x: 1.0, y: -1.0)
                            context.translateBy(x: -rect.midX, y: -rect.midY)
                            context.clip()
                        }
                    }
                    
                    if let cutoutRect {
                        context.setBlendMode(.copy)
                        context.setFillColor(UIColor.clear.cgColor)
                        //TODO:fix
                        context.fillEllipse(in: cutoutRect)
                    }
                })
                let unroundedImage: UIImage?
                if provideUnrounded {
                    unroundedImage = generateImage(displayDimensions, contextGenerator: { size, context -> Void in
                        if let (data, _) = data {
                            if let imageSource = CGImageSourceCreateWithData(data as CFData, nil), let dataImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                                context.clear(CGRect(origin: CGPoint(), size: displayDimensions))
                                context.setBlendMode(.copy)
                                
                                context.draw(dataImage, in: CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                            } else {
                                if let emptyColor = emptyColor {
                                    context.clear(CGRect(origin: CGPoint(), size: displayDimensions))
                                    context.setFillColor(emptyColor.cgColor)
                                    context.fill(CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                                }
                            }
                        } else if let emptyColor = emptyColor {
                            context.clear(CGRect(origin: CGPoint(), size: displayDimensions))
                            context.setFillColor(emptyColor.cgColor)
                            // This is the unrounded copy, including the placeholder.
                            context.fill(CGRect(origin: CGPoint(), size: displayDimensions).insetBy(dx: inset, dy: inset))
                        }
                    })
                } else {
                    unroundedImage = roundedImage
                }
                if let roundedImage = roundedImage, let unroundedImage = unroundedImage {
                    return .single((roundedImage, unroundedImage))
                } else {
                    return .single(nil)
                }
            }
            if synchronousLoad {
                return generate
            } else {
                return generate |> runOn(Queue.concurrentDefaultQueue())
            }
        }
    } else {
        return nil
    }
}

public func drawPeerAvatarLetters(context: CGContext, size: CGSize, round: Bool = true, font: UIFont, letters: [String], peerId: EnginePeer.Id, nameColor: PeerColor?) {
    let clipStyle = (round ? AvatarNodeClipStyle.round : .none).withExteralessShape(size: size)
    drawPeerAvatarLetters(context: context, size: size, resolvedClipStyle: clipStyle, font: font, letters: letters, peerId: peerId, nameColor: nameColor)
}

private func clipPeerAvatarLetters(context: CGContext, size: CGSize, clipStyle: AvatarNodeClipStyle) {
    let bounds = CGRect(origin: .zero, size: size)
    context.beginPath()
    switch clipStyle {
    case .none:
        return
    case .round:
        context.addEllipse(in: bounds)
    case .roundedRect:
        context.addPath(UIBezierPath(roundedRect: bounds, cornerRadius: floor(size.width * 0.25)).cgPath)
    case let .exteralessRoundedRect(fraction):
        context.addPath(UIBezierPath(roundedRect: bounds, cornerRadius: min(size.width, size.height) * fraction).cgPath)
    case .bubble:
        AvatarNode.addAvatarBubblePath(context: context, rect: bounds)
    }
    context.clip()
}

public func drawPeerAvatarLetters(context: CGContext, size: CGSize, resolvedClipStyle: AvatarNodeClipStyle, font: UIFont, letters: [String], peerId: EnginePeer.Id, nameColor: PeerColor?) {
    context.saveGState()
    defer { context.restoreGState() }
    clipPeerAvatarLetters(context: context, size: size, clipStyle: resolvedClipStyle)
    
    let colorIndex: Int
    if peerId.namespace == .max {
        colorIndex = -1
    } else {
        colorIndex = Int(clamping: abs(peerId.id._internalGetInt64Value()))
    }
    
    let colorsArray: NSArray
    if colorIndex == -1 {
        colorsArray = AvatarNode.grayscaleColors.map(\.cgColor) as NSArray
    } else {
        var index = colorIndex % AvatarNode.gradientColors.count
        if let nameColor {
            switch nameColor {
            case let .preset(peerNameColor):
                index = Int(peerNameColor.rawValue) % AvatarNode.gradientColors.count
            case let .collectible(peerCollectibleColor):
                let _ = peerCollectibleColor
                break
            }
        }
        colorsArray = AvatarNode.gradientColors[index].map(\.cgColor) as NSArray
    }
    
    var locations: [CGFloat] = [1.0, 0.0]
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colorsArray, locations: &locations)!
    
    context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
    
    context.setBlendMode(.normal)
    
    let string = letters.count == 0 ? "" : (letters[0] + (letters.count == 1 ? "" : letters[1]))
    let attributedString = NSAttributedString(string: string, attributes: [NSAttributedString.Key.font: font, NSAttributedString.Key.foregroundColor: UIColor.white])
    
    let line = CTLineCreateWithAttributedString(attributedString)
    let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    
    let lineOffset = CGPoint(x: string == "B" ? 1.0 : 0.0, y: 0.0)
    let lineOrigin = CGPoint(x: floorToScreenPixels(-lineBounds.origin.x + (size.width - lineBounds.size.width) / 2.0) + lineOffset.x, y: floorToScreenPixels(-lineBounds.origin.y + (size.height - lineBounds.size.height) / 2.0))
    
    context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
    context.scaleBy(x: 1.0, y: -1.0)
    context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
    
    let textPosition = context.textPosition
    context.translateBy(x: lineOrigin.x, y: lineOrigin.y)
    CTLineDraw(line, context)
    context.translateBy(x: -lineOrigin.x, y: -lineOrigin.y)
    context.textPosition = textPosition
}


public enum AvatarBackgroundColor {
    case blue
    case yellow
    case green
    case purple
    case red
    case violet
}

public func generateAvatarImage(size: CGSize, icon: UIImage?, iconScale: CGFloat = 1.0, cornerRadius: CGFloat? = nil, circleCorners: Bool = false, color: AvatarBackgroundColor, customColors: [UIColor]? = nil, diagonal: Bool = false) -> UIImage? {
    return generateImage(size, rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.beginPath()
        if let cornerRadius {
            if circleCorners {
                let roundedRect = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                context.addPath(roundedRect)
            } else {
                let roundedRect = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius)
                context.addPath(roundedRect.cgPath)
            }
        } else {
            context.addEllipse(in: CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height))
        }
        context.clip()
        
        let colorIndex: Int
        switch color {
        case .blue:
            colorIndex = 5
        case .yellow:
            colorIndex = 1
        case .green:
            colorIndex = 3
        case .purple:
            colorIndex = 2
        case .red:
            colorIndex = 0
        case .violet:
            colorIndex = 6
        }
        
        let colorsArray: NSArray
        if let customColors {
            colorsArray = customColors.map(\.cgColor) as NSArray
        } else {
            if colorIndex == -1 {
                colorsArray = AvatarNode.grayscaleColors.map(\.cgColor) as NSArray
            } else {
                colorsArray = AvatarNode.gradientColors[colorIndex % AvatarNode.gradientColors.count].map(\.cgColor) as NSArray
            }
        }
                
        var locations: [CGFloat] = []
        let delta = 1.0 / CGFloat(colorsArray.count - 1)
        for i in 0 ..< colorsArray.count {
            locations.append(1.0 - delta * CGFloat(i))
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colorsArray, locations: &locations)!
        
        if diagonal {
            context.drawLinearGradient(gradient, start: CGPoint(x: size.width, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
        } else {
            context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
        }
        context.resetClip()
        
        context.setBlendMode(.normal)
        
        context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
        
        if let icon = icon {
            let iconSize = CGSize(width: icon.size.width * iconScale, height: icon.size.height * iconScale)
            let iconFrame = CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: floor((size.height - iconSize.height) / 2.0)), size: iconSize)
            context.draw(icon.cgImage!, in: iconFrame)
        }
    })
}
