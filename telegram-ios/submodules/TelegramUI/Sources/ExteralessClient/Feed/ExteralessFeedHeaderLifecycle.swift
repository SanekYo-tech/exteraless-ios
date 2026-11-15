import Foundation

/// Prepare before subscribing to cached foreground signals. Retains one current header and
/// makes its start/stop transition explicit, independent of when a source emits synchronously.
@MainActor
final class ExteralessFeedHeaderLifecycle<Header: AnyObject> {
    private let make: () -> Header
    private let start: (Header) -> Void
    private let stop: (Header) -> Void
    private var header: Header?
    private var visible = false

    init(make: @escaping () -> Header, start: @escaping (Header) -> Void, stop: @escaping (Header) -> Void) {
        self.make = make
        self.start = start
        self.stop = stop
    }

    func prepare() -> Header {
        if let header = self.header { return header }
        let header = self.make()
        self.header = header
        return header
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible { self.start(self.prepare()) }
        else if let header = self.header { self.stop(header) }
    }
}
