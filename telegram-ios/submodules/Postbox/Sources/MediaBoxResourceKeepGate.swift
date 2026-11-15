import Foundation
import SwiftSignalKit

/// Coordinates synchronous keep admission with the separate size-eviction worker. Checking a
/// copied set before unlink is insufficient: a new holder can arrive between those two steps.
final class MediaBoxResourceKeepGate {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func keep(_ id: String) -> Disposable {
        self.lock.lock()
        self.counts[id, default: 0] += 1
        self.lock.unlock()
        return ActionDisposable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if let count = self.counts[id] {
                if count == 1 { self.counts.removeValue(forKey: id) }
                else { self.counts[id] = count - 1 }
            }
            self.lock.unlock()
        }
    }

    /// The entire inode group is skipped if a primary/partial/extension-alias path is kept.
    /// Derived representations may be evicted and regenerated from the kept original.
    func evictIfUnkept(paths: [String], root: String, remove: () -> Void) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        for path in paths where (path as NSString).deletingLastPathComponent == root {
            var name = (path as NSString).lastPathComponent
            if self.counts[name] != nil || self.counts[MediaBox.idForFileName(name: name)] != nil { return false }
            // IDs can themselves contain dots. Strip possible extension aliases from the
            // right, checking the exact ID before each step rather than splitting at dot #1.
            while let dot = name.lastIndex(of: ".") {
                name = String(name[..<dot])
                if self.counts[name] != nil || self.counts[MediaBox.idForFileName(name: name)] != nil { return false }
            }
        }
        remove()
        return true
    }
}
