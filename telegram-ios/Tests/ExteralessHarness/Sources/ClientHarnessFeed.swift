import AsyncDisplayKit
import ExteralessCore
import Foundation
import TelegramCore
import TelegramUI
import UIKit

@MainActor
extension ClientHarnessSession {
    func runFeedScenario() async throws {
        guard let feed = makeExteralessFeedSmoke(context: self.context) else {
            throw ClientHarnessFailure(description: "actual Feed factory rejected offline fixture")
        }
        defer { feed.dispose() }
        let host = ClientHarnessDomainHost(context: self.context, title: "Native Feed fixture", child: feed.controller)
        self.navigation.pushViewController(host)
        try await self.driver.settle()
        let table = try self.nativeTable("exteraless.feed.offlineSmoke", in: feed.controller.view)
        let ledger = try ClientHarnessFeedStore(context: self.context)
        let initial = try await ledger.seed(edited: false)
        try clientHarnessRequire(table.numberOfRows(inSection: 0) == 4, "six Feed messages did not group into four native rows")
        try await self.waitForFeedBubbles(table)
        try self.probe("feed-initial", extra: self.feedEvidence(table, projections: initial))

        var seen: Set<String> = []
        var rowIds: [Int: String] = [:]
        for row in 0 ..< 4 {
            table.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: true)
            try await self.driver.settle(0.4)
            try await self.waitForFeedBubbles(table)
            for cell in table.visibleCells {
                if let id = cell.accessibilityIdentifier, let path = table.indexPath(for: cell) {
                    seen.insert(id); rowIds[path.row] = id
                }
            }
        }
        try clientHarnessRequire(seen.count == 4, "Feed scroll failed to expose every native composite row")
        let albumIds = seen.filter { $0.hasSuffix(".\(Namespaces.Message.Cloud).3") }
        try clientHarnessRequire(albumIds.count == 2, "same-number peer albums shared a renderer identity")
        try self.probe("feed-albums", extra: ["table": self.tableEvidence(table), "seenRows": seen.sorted()])
        guard let styledRow = rowIds.first(where: { $0.value.hasSuffix(".\(Namespaces.Message.Cloud).2") })?.key else {
            throw ClientHarnessFailure(description: "styled Feed fixture row was not found")
        }
        table.scrollToRow(at: IndexPath(row: styledRow, section: 0), at: .middle, animated: true)
        try await self.driver.settle(0.4)
        feed.setEdited(true)
        let edited = try await ledger.seed(edited: true)
        try await self.driver.settle(0.4)
        try await self.waitForFeedBubbles(table)
        try clientHarnessRequire(Set(initial.keys) == Set(edited.keys), "Feed edit changed composite message identity")
        try self.probe("feed-edited", extra: self.feedEvidence(table, projections: edited))

        self.setDark(true)
        // The owner's factory keeps the same permit/controller. Its ordinary
        // update path reads current PresentationData for the native cells.
        feed.setEdited(true)
        try await self.driver.settle(0.4)
        try await self.waitForFeedBubbles(table)
        try self.probe("feed-dark", extra: self.feedEvidence(table, projections: edited))

        let player = try ClientHarnessPlayerFixture(context: self.context)
        defer { player.stop() }
        player.appearance(context: self.context)
        let mini = ClientHarnessMiniFixture(input: player.input, window: self.window)
        defer { mini.stop(); mini.finishObservation() }
        mini.dock(in: self.display.hostView.containerView, top: false, compact: false, animated: false)
        try await self.driver.settle(0.35)
        try mini.assertPublication(height: 64)
        try self.probe("feed-bottom-player", extra: ["table": self.tableEvidence(table), "mini": mini.snapshot])
        mini.dock(in: self.display.hostView.containerView, top: true, compact: true, animated: true)
        try await self.driver.settle(0.55)
        try mini.assertPublication(height: 52)
        try self.probe("feed-top-player", extra: ["table": self.tableEvidence(table), "mini": mini.snapshot])
        mini.stop()
        player.stop()
        feed.dispose()
        try await self.driver.settle(0.2)
        try clientHarnessRequire(table.numberOfRows(inSection: 0) == 0 && mini.rects.isEmpty, "Feed/native Player cleanup did not retire owned UI")
        try self.driver.back(); try await self.driver.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == 1, "Feed fixture left a navigation controller")
        self.report.facts["domain"] = ["name": "feed-render", "realNativeRenderer": true, "cleanup": true,
            "messageIds": edited.keys.map(ClientHarnessFeedStore.key).sorted(), "postCount": 4,
            "projectionVerified": true, "namespaceIsolation": true,
            "projectionBoundary": "real local transaction against owned seed; smoke renders its immutable native projection snapshots",
            "occlusionBoundary": "real mini/publisher over real smoke cells; production Feed receipts/exports are not invoked",
            "seenRows": seen.sorted()]
        try self.probe("feed-cleanup", extra: ["rows": table.numberOfRows(inSection: 0), "published": mini.rects.count])
    }

    private func waitForFeedBubbles(_ table: UITableView) async throws {
        try await self.driver.until("actual Feed bubble nodes") {
            !table.visibleCells.isEmpty && table.visibleCells.allSatisfy { cell in
                self.driver.views(in: cell).contains { view in
                    guard let node = view.asyncdisplaykit_node else { return false }
                    return NSStringFromClass(type(of: node)).contains("ChatMessageBubbleItemNode") && view.bounds.height > 20
                }
            }
        }
    }

    private func feedEvidence(_ table: UITableView, projections: [EngineMessage.Id: ExteralessFeedMessageProjection]) -> [String: Any] {
        ["factory": "makeExteralessFeedSmoke", "table": self.tableEvidence(table),
         "projections": projections.values.sorted { $0.message.id < $1.message.id }.map { value in
             ["id": ClientHarnessFeedStore.key(value.message.id), "token": value.renderToken.uuidString,
              "text": value.message.text, "copyProtected": value.isCopyProtected,
              "eligible": value.isEligible, "stableVersion": value.message.stableVersion] as [String: Any]
         }]
    }
}
