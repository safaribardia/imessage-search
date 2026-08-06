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

/// Where a message lives, used to jump from a search result to the same
/// spot in the People tab.
struct MessageConversationLocation: Sendable {
    let isGroup: Bool
    /// Matches MessageConversation.rowID: handle ROWID for 1:1 chats,
    /// chat ROWID for group chats.
    let conversationRowID: Int64
    /// Messages in the conversation newer than the target, counted with the
    /// same filters as the history queries so pagination offsets line up.
    let newerCount: Int
}

struct MessagesReader {
    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")

    /// Shared row filters for the People-tab history queries; the newer-count
    /// query below must match them exactly or reveal offsets drift.
    private static let historyMessageFilters = """
        AND m.item_type = 0
        AND m.associated_message_type = 0
        AND m.is_system_message = 0
        AND m.is_service_message = 0
        AND COALESCE(m.date_retracted, 0) = 0
        AND (NULLIF(m.text, '') IS NOT NULL OR m.attributedBody IS NOT NULL)
        """

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

    /// People (1:1 threads) and group chats, newest activity first.
    func readConversations() throws -> [MessageConversation] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        var conversations = try readPeople(database)
        conversations.append(contentsOf: try readGroupChats(database))
        return conversations.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    /// One entry per person, ranked by the latest direct (style 45) message.
    private func readPeople(_ database: OpaquePointer) throws -> [MessageConversation] {
        let sql = """
            SELECT
                h.ROWID,
                h.id,
                MAX(m.date)
            FROM handle AS h
            JOIN chat_handle_join AS chj ON chj.handle_id = h.ROWID
            JOIN chat AS c ON c.ROWID = chj.chat_id
            JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE NULLIF(h.id, '') IS NOT NULL
              AND c.style = 45
              AND m.item_type = 0
              AND m.associated_message_type = 0
              AND m.is_system_message = 0
              AND m.is_service_message = 0
              AND COALESCE(m.date_retracted, 0) = 0
              AND (NULLIF(m.text, '') IS NOT NULL OR m.attributedBody IS NOT NULL)
            GROUP BY h.ROWID, h.id
            ORDER BY MAX(m.date) DESC, h.id COLLATE NOCASE
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var people: [MessageConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let handle = columnText(statement, index: 1) else {
                continue
            }
            people.append(
                MessageConversation(
                    kind: .person(handle: handle),
                    rowID: sqlite3_column_int64(statement, 0),
                    lastMessageDate: messageDate(sqlite3_column_int64(statement, 2))
                )
            )
        }

        guard sqlite3_errcode(database) == SQLITE_OK ||
                sqlite3_errcode(database) == SQLITE_DONE else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        return people
    }

    /// One entry per group chat (style 43) with readable messages.
    private func readGroupChats(_ database: OpaquePointer) throws -> [MessageConversation] {
        let sql = """
            SELECT
                c.ROWID,
                COALESCE(NULLIF(c.display_name, ''), NULLIF(c.chat_identifier, ''), 'Group chat'),
                MAX(m.date),
                (
                    SELECT GROUP_CONCAT(participant.id, '|')
                    FROM chat_handle_join AS participant_join
                    JOIN handle AS participant
                      ON participant.ROWID = participant_join.handle_id
                    WHERE participant_join.chat_id = c.ROWID
                )
            FROM chat AS c
            JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE c.style = 43
              AND m.item_type = 0
              AND m.associated_message_type = 0
              AND m.is_system_message = 0
              AND m.is_service_message = 0
              AND COALESCE(m.date_retracted, 0) = 0
              AND (NULLIF(m.text, '') IS NOT NULL OR m.attributedBody IS NOT NULL)
            GROUP BY c.ROWID
            ORDER BY MAX(m.date) DESC
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var groups: [MessageConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let participants = (columnText(statement, index: 3) ?? "")
                .split(separator: "|")
                .map(String.init)
            groups.append(
                MessageConversation(
                    kind: .group(
                        rawName: columnText(statement, index: 1) ?? "Group chat",
                        participants: participants
                    ),
                    rowID: sqlite3_column_int64(statement, 0),
                    lastMessageDate: messageDate(sqlite3_column_int64(statement, 2))
                )
            )
        }

        guard sqlite3_errcode(database) == SQLITE_OK ||
                sqlite3_errcode(database) == SQLITE_DONE else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        return groups
    }

    func readMessageHistory(
        personID: Int64,
        limit: Int,
        offset: Int
    ) throws -> [PersonHistoryMessage] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        // Direct (style 45) chats only: the People tab shows the 1:1
        // conversation with a person, never their group chats.
        let sql = """
            SELECT
                m.ROWID,
                CASE WHEN m.is_from_me = 1 THEN 'Me' ELSE person.id END,
                m.date,
                m.text,
                m.attributedBody
            FROM handle AS person
            JOIN chat_handle_join AS person_join ON person_join.handle_id = person.ROWID
            JOIN chat AS c ON c.ROWID = person_join.chat_id
            JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE person.ROWID = ?
              AND c.style = 45
              AND m.item_type = 0
              AND m.associated_message_type = 0
              AND m.is_system_message = 0
              AND m.is_service_message = 0
              AND COALESCE(m.date_retracted, 0) = 0
              AND (NULLIF(m.text, '') IS NOT NULL OR m.attributedBody IS NOT NULL)
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT ? OFFSET ?
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, personID)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))
        sqlite3_bind_int(statement, 3, Int32(max(0, offset)))

        return try historyMessages(statement, database: database)
    }

    /// One group chat's messages, oldest first within the returned page.
    func readGroupMessageHistory(
        chatID: Int64,
        limit: Int,
        offset: Int
    ) throws -> [PersonHistoryMessage] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        let sql = """
            SELECT
                m.ROWID,
                CASE
                    WHEN m.is_from_me = 1 THEN 'Me'
                    ELSE COALESCE(NULLIF(sender.id, ''), 'Unknown')
                END,
                m.date,
                m.text,
                m.attributedBody
            FROM message AS m
            JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle AS sender ON sender.ROWID = m.handle_id
            WHERE cmj.chat_id = ?
              AND m.item_type = 0
              AND m.associated_message_type = 0
              AND m.is_system_message = 0
              AND m.is_service_message = 0
              AND COALESCE(m.date_retracted, 0) = 0
              AND (NULLIF(m.text, '') IS NOT NULL OR m.attributedBody IS NOT NULL)
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT ? OFFSET ?
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))
        sqlite3_bind_int(statement, 3, Int32(max(0, offset)))

        return try historyMessages(statement, database: database)
    }

    /// All 1:1 (style 45) chat ROWIDs for a person — usually one iMessage
    /// chat plus an SMS chat. Used to scope index searches to that thread.
    func directChatIDs(handleID: Int64) throws -> [Int64] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        let sql = """
            SELECT c.ROWID
            FROM chat_handle_join AS chj
            JOIN chat AS c ON c.ROWID = chj.chat_id
            WHERE chj.handle_id = ?
              AND c.style = 45
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, handleID)

        var chatIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            chatIDs.append(sqlite3_column_int64(statement, 0))
        }

        guard sqlite3_errcode(database) == SQLITE_OK ||
                sqlite3_errcode(database) == SQLITE_DONE else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        return chatIDs
    }

    /// Resolves which People-tab conversation a message belongs to and how
    /// deep it sits (messages newer than it), so callers can load exactly
    /// enough history to show it. Returns nil when the message is gone.
    func locateMessage(rowID: Int64) throws -> MessageConversationLocation? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        let locationSQL = """
            SELECT
                c.ROWID,
                c.style,
                (
                    SELECT chj.handle_id
                    FROM chat_handle_join AS chj
                    WHERE chj.chat_id = c.ROWID
                    LIMIT 1
                ),
                m.date
            FROM message AS m
            JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            JOIN chat AS c ON c.ROWID = cmj.chat_id
            WHERE m.ROWID = ?
            LIMIT 1
            """

        var locationStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, locationSQL, -1, &locationStatement, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(locationStatement) }
        sqlite3_bind_int64(locationStatement, 1, rowID)

        guard sqlite3_step(locationStatement) == SQLITE_ROW else {
            return nil
        }
        let chatID = sqlite3_column_int64(locationStatement, 0)
        let isGroup = sqlite3_column_int64(locationStatement, 1) == 43
        let hasHandle = sqlite3_column_type(locationStatement, 2) != SQLITE_NULL
        let handleID = sqlite3_column_int64(locationStatement, 2)
        let date = sqlite3_column_int64(locationStatement, 3)

        guard isGroup || hasHandle else {
            return nil
        }

        // "Newer" mirrors the history ordering (date DESC, ROWID DESC): the
        // count equals the target's index from the newest message.
        let countSQL = isGroup
            ? """
            SELECT COUNT(*)
            FROM message AS m
            JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ?1
              AND (m.date > ?2 OR (m.date = ?2 AND m.ROWID > ?3))
              \(Self.historyMessageFilters)
            """
            : """
            SELECT COUNT(*)
            FROM chat_handle_join AS person_join
            JOIN chat AS c ON c.ROWID = person_join.chat_id
            JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE person_join.handle_id = ?1
              AND c.style = 45
              AND (m.date > ?2 OR (m.date = ?2 AND m.ROWID > ?3))
              \(Self.historyMessageFilters)
            """

        var countStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, countSQL, -1, &countStatement, nil) == SQLITE_OK else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        defer { sqlite3_finalize(countStatement) }
        sqlite3_bind_int64(countStatement, 1, isGroup ? chatID : handleID)
        sqlite3_bind_int64(countStatement, 2, date)
        sqlite3_bind_int64(countStatement, 3, rowID)

        guard sqlite3_step(countStatement) == SQLITE_ROW else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }

        return MessageConversationLocation(
            isGroup: isGroup,
            conversationRowID: isGroup ? chatID : handleID,
            newerCount: Int(sqlite3_column_int64(countStatement, 0))
        )
    }

    /// Decodes history rows shaped (ROWID, sender, date, text, attributedBody)
    /// and flips the newest-first page into chronological order.
    private func historyMessages(
        _ statement: OpaquePointer?,
        database: OpaquePointer
    ) throws -> [PersonHistoryMessage] {
        var messages: [PersonHistoryMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = messageText(
                from: statement,
                textColumn: 3,
                bodyColumn: 4
            ) ?? "Attachment"
            messages.append(
                PersonHistoryMessage(
                    id: sqlite3_column_int64(statement, 0),
                    sender: columnText(statement, index: 1) ?? "Unknown",
                    date: messageDate(sqlite3_column_int64(statement, 2)),
                    text: text
                )
            )
        }

        guard sqlite3_errcode(database) == SQLITE_OK ||
                sqlite3_errcode(database) == SQLITE_DONE else {
            throw MessagesReaderError.databaseError(errorMessage(database))
        }
        return Array(messages.reversed())
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

    private func messageText(
        from statement: OpaquePointer?,
        textColumn: Int32 = 5,
        bodyColumn: Int32 = 6
    ) -> String? {
        if let text = columnText(statement, index: textColumn) {
            let cleaned = clean(text)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        let byteCount = Int(sqlite3_column_bytes(statement, bodyColumn))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, bodyColumn) else {
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

    private func messageDate(_ rawValue: Int64) -> Date {
        Date(
            timeIntervalSinceReferenceDate: TimeInterval(rawValue) / 1_000_000_000
        )
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
