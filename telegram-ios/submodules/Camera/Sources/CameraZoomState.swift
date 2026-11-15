import AVFoundation
import ExteralessCore
import Foundation
import SwiftSignalKit

public extension Camera {
    struct ZoomState: Equatable {
        public let deviceId: String
        public let minimum: CGFloat
        public let maximum: CGFloat
        public let neutral: CGFloat
        public let value: CGFloat
        public let stops: [CGFloat]

        public init(device: AVCaptureDevice) {
            self.deviceId = device.uniqueID
            self.minimum = max(1, device.minAvailableVideoZoomFactor)
            self.maximum = max(self.minimum, device.maxAvailableVideoZoomFactor)
            if device.position == .back,
               device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
                self.neutral = max(self.minimum, device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat($0.doubleValue) } ?? 1)
            } else { self.neutral = self.minimum }
            self.value = min(self.maximum, max(self.minimum, device.videoZoomFactor))
            var values = [self.minimum, self.neutral]
            values.append(contentsOf: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) })
            if #available(iOS 16.0, *) { values.append(contentsOf: device.activeFormat.secondaryNativeResolutionZoomFactors) }
            self.stops = ToolsCameraPolicy.lensStops(minimum: Double(self.minimum), maximum: Double(self.maximum), optical: values.map { Double($0) }).map { CGFloat($0) }
        }
    }
}

/// Real device capabilities and KVO feedback. A label of 0.5× is emitted only when
/// a virtual rear camera actually offers a lens below its wide-angle neutral zoom.
public func cameraDeviceZoomState(_ device: AVCaptureDevice) -> Signal<Camera.ZoomState?, NoError> {
    return Signal { subscriber in
        let emit: (AVCaptureDevice) -> Void = { subscriber.putNext(Camera.ZoomState(device: $0)) }
        let observers = [
            device.observe(\.videoZoomFactor, options: [.new]) { device, _ in emit(device) },
            device.observe(\.activeFormat, options: [.new]) { device, _ in emit(device) },
            device.observe(\.minAvailableVideoZoomFactor, options: [.new]) { device, _ in emit(device) },
            device.observe(\.maxAvailableVideoZoomFactor, options: [.new]) { device, _ in emit(device) }
        ]
        emit(device)
        return ActionDisposable { for observer in observers { observer.invalidate() } }
    }
    |> distinctUntilChanged
}
