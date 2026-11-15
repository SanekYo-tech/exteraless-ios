import Foundation
import sqlcipher

enum ExteralessAyuCell: Codable {
    case integer(Int64), text(String), bytes(Data), null
}

struct ExteralessAyuRow: Codable {
    let table: String
    let values: [String: ExteralessAyuCell]

    func integer(_ key: String, default fallback: Int64 = 0) throws -> Int64 {
        guard let value = self.values[key] else { return fallback }
        if case .null = value { return fallback }
        guard case let .integer(result) = value else { throw ExteralessRetentionError.invalidArchive }
        return result
    }
    func int32(_ key: String, default fallback: Int32 = 0) throws -> Int32 {
        let value = try self.integer(key, default: Int64(fallback))
        guard let result = Int32(exactly: value) else { throw ExteralessRetentionError.invalidArchive }
        return result
    }
    func text(_ key: String) throws -> String {
        guard let value = self.values[key] else { return "" }
        if case .null = value { return "" }
        guard case let .text(result) = value else { throw ExteralessRetentionError.invalidArchive }
        return result
    }
    func data(_ key: String) throws -> Data? {
        guard let value = self.values[key] else { return nil }
        if case .null = value { return nil }
        guard case let .bytes(result) = value else { throw ExteralessRetentionError.invalidArchive }
        return result.isEmpty ? nil : result
    }
}

struct ExteralessAyuDatabase {
    let rows: [ExteralessAyuRow]
    let reactions: [Int64: [ExteralessAyuRow]]
    let auxiliaryTables: [String: Int]
    let sourceVersion: Int64
    let auxiliaryRows: [String: [ExteralessAyuRow]]

    init(rows: [ExteralessAyuRow], reactions: [Int64: [ExteralessAyuRow]], auxiliaryTables: [String: Int], sourceVersion: Int64, auxiliaryRows: [String: [ExteralessAyuRow]] = [:]) {
        self.rows = rows
        self.reactions = reactions
        self.auxiliaryTables = auxiliaryTables
        self.sourceVersion = sourceVersion
        self.auxiliaryRows = auxiliaryRows
    }
}

/// Read-only SQLite schema adapter for AyuDatabaseImport's actual tables. Nothing from the
/// source is executed as SQL, loaded as an extension, or treated as a native Postbox database.
final class ExteralessAyuDatabaseReader {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var cancelled = false
    private var stagedBytes = 0 // reader queue only; includes messages, reactions and auxiliaries

    func cancel() {
        self.lock.lock()
        self.cancelled = true
        if let handle = self.handle { sqlite3_interrupt(handle) }
        self.lock.unlock()
    }

    private func check() throws {
        self.lock.lock()
        let cancelled = self.cancelled
        self.lock.unlock()
        if cancelled { throw ExteralessRetentionError.cancelled }
    }

    func read(url: URL) throws -> ExteralessAyuDatabase {
        try self.check()
        guard url.isFileURL else { throw ExteralessRetentionError.invalidArchive }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, let length = (attributes[.size] as? NSNumber)?.int64Value,
              length >= 100, length <= 64 * 1024 * 1024 else { throw ExteralessRetentionError.limitExceeded }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ExteralessRetentionError.invalidArchive
        }
        self.lock.lock()
        self.handle = database
        self.lock.unlock()
        defer {
            self.lock.lock()
            self.handle = nil
            sqlite3_close(database)
            self.lock.unlock()
        }
        // The shipped sqlcipher omits progress callbacks; interrupt is the real deadline path.
        let deadline = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20.0, execute: deadline)
        defer { deadline.cancel() }
        sqlite3_busy_timeout(database, 250)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1024 * 1024)
        sqlite3_limit(database, SQLITE_LIMIT_COLUMN, 128)
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 8192)
        guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA trusted_schema=OFF", nil, nil, nil) == SQLITE_OK else { throw ExteralessRetentionError.invalidArchive }
        let integrity = try self.query(database, sql: "PRAGMA quick_check(1)", table: "check", budget: 4)
        guard integrity.count == 1, try integrity[0].text("quick_check") == "ok" else { throw ExteralessRetentionError.invalidArchive }
        let versionRows = try self.query(database, sql: "PRAGMA user_version", table: "version", budget: 1)
        let sourceVersion = try versionRows.first?.integer("user_version") ?? 0
        let tables = try self.query(database, sql: "SELECT name, sql FROM sqlite_master WHERE type='table'", table: "schema", budget: 64)
        var available = Set<String>()
        for row in tables {
            let name = try row.text("name")
            if Self.columns[name] != nil {
                let sql = try row.text("sql").uppercased()
                guard !sql.contains("VIRTUAL TABLE"), !sql.contains("GENERATED ALWAYS") else { throw ExteralessRetentionError.invalidArchive }
                available.insert(name)
                let info = try self.query(database, sql: "PRAGMA table_xinfo(`\(name)`)", table: "columns", budget: 128)
                let names = try Set(info.map { try $0.text("name") })
                guard try info.allSatisfy({ try $0.integer("hidden") == 0 }) else { throw ExteralessRetentionError.unsupportedFormat }
                guard names.isSubset(of: Self.columns[name]!) else { throw ExteralessRetentionError.unsupportedFormat }
                if name == "DeletedMessage" || name == "EditedMessage" {
                    guard Set(["userId", "dialogId", "messageId", "date", "entityCreateDate", "editDate", "flags", "text"]).isSubset(of: names) else { throw ExteralessRetentionError.invalidArchive }
                } else if name == "SpyMessageRead" || name == "SpyMessageContentsRead" {
                    guard Set(["userId", "dialogId", "messageId"]).isSubset(of: names), names.contains("date") || names.contains("entityCreateDate") else { throw ExteralessRetentionError.invalidArchive }
                } else if let required = Self.requiredColumns[name] {
                    guard required.isSubset(of: names) else { throw ExteralessRetentionError.invalidArchive }
                }
            }
        }
        guard available.contains("DeletedMessage") || available.contains("EditedMessage") else { throw ExteralessRetentionError.invalidArchive }
        var rows: [ExteralessAyuRow] = []
        for table in ["EditedMessage", "DeletedMessage"] where available.contains(table) {
            let result = try self.query(database, sql: "SELECT * FROM `\(table)` ORDER BY entityCreateDate, messageId", table: table, budget: 20000 - rows.count)
            for row in result {
                rows.append(row)
            }
        }
        var reactions: [Int64: [ExteralessAyuRow]] = [:]
        if available.contains("DeletedMessageReaction") {
            for row in try self.query(database, sql: "SELECT * FROM DeletedMessageReaction", table: "DeletedMessageReaction", budget: 40000) {
                let id = try row.integer("deletedMessageId")
                guard id > 0 else { throw ExteralessRetentionError.invalidArchive }
                reactions[id, default: []].append(row)
                guard reactions[id]!.count <= 100 else { throw ExteralessRetentionError.limitExceeded }
            }
        }
        var auxiliary: [String: Int] = [:]
        var auxiliaryRows: [String: [ExteralessAyuRow]] = [:]
        var auxiliaryCount = 0
        for table in ["DeletedDialog", "SpyMessageRead", "SpyMessageContentsRead", "LastSeenEntity", "SpyLastSeen"] where available.contains(table) {
            let rows = try self.query(database, sql: "SELECT * FROM `\(table)`", table: table, budget: 50000 - auxiliaryCount)
            auxiliaryCount += rows.count
            auxiliary[table] = rows.count
            auxiliaryRows[table] = rows
        }
        try self.check()
        return ExteralessAyuDatabase(rows: rows, reactions: reactions, auxiliaryTables: auxiliary, sourceVersion: sourceVersion, auxiliaryRows: auxiliaryRows)
    }

    private func query(_ database: OpaquePointer, sql: String, table: String, budget: Int) throws -> [ExteralessAyuRow] {
        try self.check()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ExteralessRetentionError.invalidArchive }
        defer { sqlite3_finalize(statement) }
        var rows: [ExteralessAyuRow] = []
        var bytes = 0
        while true {
            try self.check()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            if result == SQLITE_INTERRUPT { try self.check(); throw ExteralessRetentionError.cancelled }
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { throw ExteralessRetentionError.unavailable }
            guard result == SQLITE_ROW else { throw ExteralessRetentionError.invalidArchive }
            guard rows.count < budget else { throw ExteralessRetentionError.limitExceeded }
            var values: [String: ExteralessAyuCell] = [:]
            for column in 0 ..< sqlite3_column_count(statement) {
                guard let rawName = sqlite3_column_name(statement, column) else { throw ExteralessRetentionError.invalidArchive }
                let name = String(cString: rawName)
                guard values[name] == nil else { throw ExteralessRetentionError.invalidArchive }
                // SQLite column_type must precede getters that can coerce a value to text.
                let valueType = sqlite3_column_type(statement, column)
                let size = Int(sqlite3_column_bytes(statement, column))
                guard size >= 0, size <= 512 * 1024 else { throw ExteralessRetentionError.limitExceeded }
                bytes += size
                guard bytes <= 16 * 1024 * 1024 else { throw ExteralessRetentionError.limitExceeded }
                switch valueType {
                case SQLITE_NULL: values[name] = .null
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_TEXT:
                    guard let pointer = sqlite3_column_text(statement, column), let text = String(data: Data(bytes: pointer, count: size), encoding: .utf8) else { throw ExteralessRetentionError.invalidArchive }
                    values[name] = .text(text)
                case SQLITE_BLOB:
                    if size == 0 { values[name] = .bytes(Data()) }
                    else {
                        guard let pointer = sqlite3_column_blob(statement, column) else { throw ExteralessRetentionError.invalidArchive }
                        values[name] = .bytes(Data(bytes: pointer, count: size))
                    }
                default: throw ExteralessRetentionError.invalidArchive
                }
            }
            let row = ExteralessAyuRow(table: table, values: values)
            self.stagedBytes += try exteralessRetentionEncode(row).count
            guard self.stagedBytes <= 16 * 1024 * 1024 else { throw ExteralessRetentionError.limitExceeded }
            rows.append(row)
        }
        return rows
    }

    private static let messageColumns: Set<String> = ["fakeId", "userId", "dialogId", "groupedId", "peerId", "fromId", "topicId", "messageId", "date", "flags", "editDate", "views", "forwards", "fwdFlags", "fwdFromId", "fwdName", "fwdDate", "fwdPostAuthor", "replyFlags", "replyMessageId", "replyPeerId", "replyTopId", "replyForumTopic", "replyQuote", "replyQuoteText", "replyQuoteEntities", "replyFromSerialized", "entityCreateDate", "text", "textEntities", "mediaPath", "hqThumbPath", "documentType", "documentSerialized", "thumbsSerialized", "documentAttributesSerialized", "mimeType", "replyMarkupSerialized"]
    private static let columns: [String: Set<String>] = [
        "DeletedMessage": messageColumns, "EditedMessage": messageColumns,
        "DeletedMessageReaction": ["fakeReactionId", "deletedMessageId", "emoticon", "documentId", "isCustom", "count", "selfSelected"],
        "DeletedDialog": ["userId", "dialogId", "folderId", "topMessage", "lastMessageDate", "entityCreateDate"],
        "SpyMessageRead": ["fakeId", "userId", "dialogId", "messageId", "date", "entityCreateDate"],
        "SpyMessageContentsRead": ["fakeId", "userId", "dialogId", "messageId", "date", "entityCreateDate"],
        "LastSeenEntity": ["userId", "lastSeen"], "SpyLastSeen": ["userId", "lastSeenDate"]
    ]
    private static let requiredColumns: [String: Set<String>] = [
        "DeletedMessageReaction": ["deletedMessageId", "count", "isCustom", "selfSelected"],
        "DeletedDialog": ["userId", "dialogId", "folderId", "topMessage", "lastMessageDate", "entityCreateDate"],
        "LastSeenEntity": ["userId", "lastSeen"], "SpyLastSeen": ["userId", "lastSeenDate"]
    ]
}
