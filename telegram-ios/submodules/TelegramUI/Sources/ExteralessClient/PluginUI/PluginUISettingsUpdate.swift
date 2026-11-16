import Foundation

/// Typed third argument to uiUpdate for portable SDK settings only. The UUIDs
/// identify Python callback snapshots, never native owner/account/permission.
/// Store owns the unique completion handle until ACK + release enter owner FIFO.
struct PluginUISettingsUpdate: Sendable {
    let id = UUID()
    let previousSnapshotId: String
    let snapshotId: String
    let baseRevision: Int64
    let completion: PluginUICallback
    var committed: Bool?

    init(_ value: PluginUIJSON, previous: PluginUIModel, candidate: PluginUIModel, revision: Int64) throws {
        guard let object = value.object else { throw PluginUIFailure.malformed("Settings update requires a transaction object") }
        try object.uiFields(["previousSnapshotId", "snapshotId", "completion"], name: "settingsUpdate")
        guard previous.kind == .settings, previous.raw["rows"] != nil,
              let previousId = try object.uiString("previousSnapshotId", limit: 36), UUID(uuidString: previousId) != nil,
              let snapshotId = try object.uiString("snapshotId", limit: 36), UUID(uuidString: snapshotId) != nil,
              previous.raw["settingsSnapshotId"] == .string(previousId), candidate.raw["settingsSnapshotId"] == .string(snapshotId),
              let completion = object["completion"] else {
            throw PluginUIFailure.invalidHandle("Settings update does not match its original callback snapshot")
        }
        self.previousSnapshotId = previousId
        self.snapshotId = snapshotId
        self.baseRevision = revision
        self.completion = try PluginUICallback(completion)
    }

    func check(previous: PluginUIModel, candidate: PluginUIModel, revision: Int64) throws {
        guard self.committed == nil, self.baseRevision == revision,
              previous.raw["settingsSnapshotId"] == .string(self.previousSnapshotId),
              candidate.raw["settingsSnapshotId"] == .string(self.snapshotId) else {
            throw PluginUIFailure.invalidHandle("Settings update lost its native model/revision commit")
        }
    }
}
