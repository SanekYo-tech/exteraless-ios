import PluginHost

/// Runtime calls closeAll before replacing/clearing AccountContext. Weak entries
/// do not prolong a cancelled read; closing never reacquires an owner by plugin ID.
@MainActor public enum PluginUIManagerSettingsLifetimes {
    private final class Entry {
        weak var lease: PluginSettingsPageLease?
        init(_ lease: PluginSettingsPageLease) { self.lease = lease }
    }
    private static var entries: [Entry] = []

    static func track(_ lease: PluginSettingsPageLease) {
        self.entries.removeAll { $0.lease?.isOpen != true }
        self.entries.append(Entry(lease))
    }

    public static func closeAll() {
        let previous = self.entries
        self.entries.removeAll()
        for entry in previous { entry.lease?.close() }
    }
}
