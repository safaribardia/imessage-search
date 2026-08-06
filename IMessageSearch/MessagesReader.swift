import Foundation
import SQLite3

enum MessagesReaderError: LocalizedError, Sendable {
    case fullDiskAccessRequired
    case databaseUnavailable
    case databaseError(String)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired:
            "Full Disk Access is required to read your Messages database."
        case .databaseUnavailable:
            "Your Messages database could not be found. Open Messages and make sure your history is downloaded to this Mac."
        case .databaseError(let message):
            "Messages database error: \(message)"
        }
    }
}

struct MessagesReader {
    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")

    func checkAccess() throws {
        _ = try latestMessageRowID()
    }

    /// Cheap change marker: bumps whenever any new message arrives.
    func latestMessageRowID() throws -> Int64 {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COALESCE(MAX(ROWID), 0) FROM message",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        return sqlite3_column_int64(statement, 0)
    }

    func readMessages(months: Int) throws -> [MessageRecord] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        guard let cutoffDate = Calendar.current.date(
            byAdding: .month,
            value: -months,
            to: Date()
        ) else {
            throw MessagesReaderError.databaseError("Could not calculate the index date range.")
        }
        let cutoff = Int64(cutoffDate.timeIntervalSinceReferenceDate * 1_000_000_000)

        let sql = """
            SELECT
                m.ROWID,
                cmj.chat_id,
                COALESCE(NULLIF(c.display_name, ''), NULLIF(c.chat_identifier, ''), 'Unknown chat'),
                CASE
                    WHEN m.is_from_me = 1 THEN 'Me'
                    ELSE COALESCE(NULLIF(h.id, ''), 'Unknown')
                END,
                m.date,
                m.text,
                m.attributedBody
            FROM message AS m
            JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            JOIN chat AS c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle AS h ON h.ROWID = m.handle_id
            WHERE m.date >= ?
              AND m.item_type = 0
              AND m.associated_message_type = 0
              AND m.is_system_message = 0
              AND m.is_service_message = 0
              AND COALESCE(m.date_retracted, 0) = 0
            ORDER BY cmj.chat_id, m.date, m.ROWID
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_int64(statement, 1, cutoff) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        var messages: [MessageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = messageText(from: statement), !text.isEmpty else {
                continue
            }

            let rawDate = sqlite3_column_int64(statement, 4)
            messages.append(
                MessageRecord(
                    rowID: sqlite3_column_int64(statement, 0),
                    chatID: sqlite3_column_int64(statement, 1),
                    chatName: columnText(statement, index: 2) ?? "Unknown chat",
                    sender: columnText(statement, index: 3) ?? "Unknown",
                    date: Date(
                        timeIntervalSinceReferenceDate: TimeInterval(rawDate) / 1_000_000_000
                    ),
                    text: text
                )
            )
        }

        guard sqlite3_errcode(database) == SQLITE_OK ||
                sqlite3_errcode(database) == SQLITE_DONE else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        return messages
    }

    private func openDatabase() throws -> OpaquePointer {
        do {
            let handle = try FileHandle(forReadingFrom: databaseURL)
            try handle.close()
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain {
                switch CocoaError.Code(rawValue: cocoaError.code) {
                case .fileNoSuchFile:
                    throw MessagesReaderError.databaseUnavailable
                case .fileReadNoPermission, .fileWriteNoPermission:
                    throw MessagesReaderError.fullDiskAccessRequired
                default:
                    throw MessagesReaderError.databaseError(error.localizedDescription)
                }
            }
            throw MessagesReaderError.databaseError(error.localizedDescription)
        }

        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = errorMessage(database)
            sqlite3_close(database)
            throw MessagesReaderError.databaseError(message)
        }
        guard sqlite3_db_readonly(database, "main") == 1 else {
            sqlite3_close(database)
            throw MessagesReaderError.databaseError("The database was not opened read-only.")
        }
        return database
    }

    private func messageText(from statement: OpaquePointer?) -> String? {
        if let text = columnText(statement, index: 5) {
            let cleaned = clean(text)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        let byteCount = Int(sqlite3_column_bytes(statement, 6))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, 6) else {
            return nil
        }

        let data = Data(bytes: bytes, count: byteCount)
        return autoreleasepool {
            // Messages uses Foundation's legacy typedstream archive format.
            guard let value = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString else {
                return nil
            }
            let cleaned = clean(value.string)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func errorMessage(_ database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "Unknown error"
        }
        return String(cString: message)
    }
}
