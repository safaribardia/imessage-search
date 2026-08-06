import Accelerate
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum IndexStoreError: LocalizedError {
    case database(String)

    var errorDescription: String? {
        switch self {
        case .database(let message):
            "Search index error: \(message)"
        }
    }
}

private struct EmbeddingMatrix {
    let windowIDs: [String]
    let dimension: Int
    let vectors: [Float]
}

final class IndexStore {
    private var database: OpaquePointer?
    /// In-memory copy of all embedding vectors, keyed by model name.
    /// Avoids re-reading and decoding ~40 MB from SQLite on every search.
    private var embeddingMatrices: [String: EmbeddingMatrix] = [:]

    init() throws {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(
            "IMessageSearch",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("index.sqlite3")

        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = errorMessage()
            sqlite3_close(database)
            database = nil
            throw IndexStoreError.database(message)
        }

        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try createSchema()
        try removeObsoleteEmbeddingData()
    }

    deinit {
        sqlite3_close(database)
    }

    func hasWindows() throws -> Bool {
        let statement = try prepare("SELECT EXISTS(SELECT 1 FROM windows)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw IndexStoreError.database(errorMessage())
        }
        return sqlite3_column_int(statement, 0) == 1
    }

    func lastSyncedMessageRowID() throws -> Int64? {
        let statement = try prepare(
            "SELECT value FROM metadata WHERE key = 'last_synced_message_row_id'"
        )
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw IndexStoreError.database(errorMessage())
        }
        guard let value = columnText(statement, index: 0),
              let rowID = Int64(value) else {
            throw IndexStoreError.database("The saved Messages sync marker is invalid.")
        }
        return rowID
    }

    func setLastSyncedMessageRowID(_ rowID: Int64) throws {
        let statement = try prepare(
            """
            INSERT INTO metadata (key, value)
            VALUES ('last_synced_message_row_id', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(String(rowID), to: 1, in: statement)
        try stepDone(statement)
    }

    func synchronize(windows: [ConversationWindow]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute(
                """
                CREATE TEMP TABLE IF NOT EXISTS current_window_ids (
                    id TEXT PRIMARY KEY
                )
                """
            )
            try execute("DELETE FROM current_window_ids")
            try execute("DELETE FROM windows_fts")

            let upsertWindow = try prepare(
                """
                INSERT INTO windows (
                    id, chat_id, chat_name, start_date, end_date,
                    transcript, message_ids, content_hash
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    chat_id = excluded.chat_id,
                    chat_name = excluded.chat_name,
                    start_date = excluded.start_date,
                    end_date = excluded.end_date,
                    transcript = excluded.transcript,
                    message_ids = excluded.message_ids,
                    content_hash = excluded.content_hash
                """
            )
            defer { sqlite3_finalize(upsertWindow) }

            let insertFTS = try prepare(
                "INSERT INTO windows_fts (window_id, transcript) VALUES (?, ?)"
            )
            defer { sqlite3_finalize(insertFTS) }

            let insertCurrentID = try prepare(
                "INSERT INTO current_window_ids (id) VALUES (?)"
            )
            defer { sqlite3_finalize(insertCurrentID) }

            for window in windows {
                try bind(window.id, to: 1, in: upsertWindow)
                sqlite3_bind_int64(upsertWindow, 2, window.chatID)
                try bind(window.chatName, to: 3, in: upsertWindow)
                sqlite3_bind_double(upsertWindow, 4, window.startDate.timeIntervalSince1970)
                sqlite3_bind_double(upsertWindow, 5, window.endDate.timeIntervalSince1970)
                try bind(window.transcript, to: 6, in: upsertWindow)
                try bind(
                    window.messageIDs.map(String.init).joined(separator: ","),
                    to: 7,
                    in: upsertWindow
                )
                try bind(window.contentHash, to: 8, in: upsertWindow)
                try stepDone(upsertWindow)

                try bind(window.id, to: 1, in: insertFTS)
                try bind(window.transcript, to: 2, in: insertFTS)
                try stepDone(insertFTS)

                try bind(window.id, to: 1, in: insertCurrentID)
                try stepDone(insertCurrentID)
            }

            try execute(
                """
                DELETE FROM windows
                WHERE id NOT IN (SELECT id FROM current_window_ids)
                """
            )
            try execute("COMMIT")
            embeddingMatrices.removeAll()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func embeddingCoverage(for model: EmbeddingModel) throws -> EmbeddingCoverage {
        let statement = try prepare(
            """
            SELECT COUNT(w.id), COUNT(e.window_id)
            FROM windows AS w
            LEFT JOIN embeddings AS e
              ON e.window_id = w.id AND e.model = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(model.rawValue, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw IndexStoreError.database(errorMessage())
        }
        return EmbeddingCoverage(
            completed: Int(sqlite3_column_int64(statement, 1)),
            total: Int(sqlite3_column_int64(statement, 0))
        )
    }

    func windowsMissingEmbeddings(
        for model: EmbeddingModel,
        limit: Int? = nil
    ) throws -> [ConversationWindow] {
        let limitClause = limit.map { "LIMIT \(max(0, $0))" } ?? ""
        let statement = try prepare(
            """
            SELECT
                w.id, w.chat_id, w.chat_name, w.start_date, w.end_date,
                w.transcript, w.message_ids, w.content_hash
            FROM windows AS w
            LEFT JOIN embeddings AS e
              ON e.window_id = w.id AND e.model = ?
            WHERE e.window_id IS NULL
            ORDER BY w.start_date
            \(limitClause)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(model.rawValue, to: 1, in: statement)

        var windows: [ConversationWindow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            windows.append(window(from: statement))
        }
        try ensureStatementFinished(statement)
        return windows
    }

    func saveEmbeddings(
        _ embeddings: [(windowID: String, vector: [Float])],
        model: EmbeddingModel
    ) throws {
        guard !embeddings.isEmpty else {
            return
        }

        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare(
                """
                INSERT INTO embeddings (window_id, model, dimension, vector)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(window_id, model) DO UPDATE SET
                    dimension = excluded.dimension,
                    vector = excluded.vector
                """
            )
            defer { sqlite3_finalize(statement) }

            for embedding in embeddings {
                try bind(embedding.windowID, to: 1, in: statement)
                try bind(model.rawValue, to: 2, in: statement)
                sqlite3_bind_int(statement, 3, Int32(embedding.vector.count))
                try bind(vectorData(embedding.vector), to: 4, in: statement)
                try stepDone(statement)
            }
            try execute("COMMIT")
            embeddingMatrices.removeValue(forKey: model.rawValue)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func semanticSearch(
        embedding: [Float],
        model: EmbeddingModel,
        limit: Int,
        chatIDs: Set<Int64>? = nil
    ) throws -> [SearchResult] {
        let matrix = try embeddingMatrix(for: model)
        guard matrix.dimension == embedding.count, !matrix.windowIDs.isEmpty else {
            return []
        }

        // A chat scope prefilters the ranked rows so the limit is spent
        // entirely on in-scope windows.
        let allowedWindowIDs = try chatIDs.map(windowIDs(forChatIDs:))

        let rowCount = matrix.windowIDs.count
        var scores = [Float](repeating: 0, count: rowCount)
        matrix.vectors.withUnsafeBufferPointer { vectors in
            embedding.withUnsafeBufferPointer { query in
                for row in 0..<rowCount {
                    vDSP_dotpr(
                        vectors.baseAddress! + row * matrix.dimension,
                        1,
                        query.baseAddress!,
                        1,
                        &scores[row],
                        vDSP_Length(matrix.dimension)
                    )
                }
            }
        }

        let topRows = scores.enumerated()
            .filter { row, _ in
                allowedWindowIDs?.contains(matrix.windowIDs[row]) ?? true
            }
            .sorted { $0.element > $1.element }
            .prefix(limit)

        var results: [SearchResult] = []
        for (row, score) in topRows {
            if let result = try window(id: matrix.windowIDs[row], score: score) {
                results.append(result)
            }
        }
        return results
    }

    private func windowIDs(forChatIDs chatIDs: Set<Int64>) throws -> Set<String> {
        guard !chatIDs.isEmpty else {
            return []
        }
        let placeholders = chatIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try prepare(
            "SELECT id FROM windows WHERE chat_id IN (\(placeholders))"
        )
        defer { sqlite3_finalize(statement) }
        for (index, chatID) in chatIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatID)
        }

        var ids: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = columnText(statement, index: 0) {
                ids.insert(id)
            }
        }
        try ensureStatementFinished(statement)
        return ids
    }

    private func embeddingMatrix(for model: EmbeddingModel) throws -> EmbeddingMatrix {
        if let cached = embeddingMatrices[model.rawValue] {
            return cached
        }

        let statement = try prepare(
            "SELECT window_id, dimension, vector FROM embeddings WHERE model = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(model.rawValue, to: 1, in: statement)

        var windowIDs: [String] = []
        var vectors: [Float] = []
        var dimension = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowDimension = Int(sqlite3_column_int(statement, 1))
            if dimension == 0 {
                dimension = rowDimension
            }
            guard rowDimension == dimension,
                  let windowID = columnText(statement, index: 0),
                  let vector = columnVector(statement, index: 2, dimension: rowDimension) else {
                continue
            }
            windowIDs.append(windowID)
            vectors.append(contentsOf: vector)
        }
        try ensureStatementFinished(statement)

        let matrix = EmbeddingMatrix(
            windowIDs: windowIDs,
            dimension: dimension,
            vectors: vectors
        )
        embeddingMatrices[model.rawValue] = matrix
        return matrix
    }

    private func window(id: String, score: Float) throws -> SearchResult? {
        let statement = try prepare(
            """
            SELECT id, chat_name, start_date, end_date, transcript, message_ids
            FROM windows
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return SearchResult(
            id: columnText(statement, index: 0) ?? "",
            chatName: columnText(statement, index: 1) ?? "Unknown chat",
            startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            transcript: columnText(statement, index: 4) ?? "",
            messageIDs: messageIDs(columnText(statement, index: 5)),
            score: score
        )
    }

    /// Case-insensitive substring scan across raw transcripts — catches
    /// links, partial words, and exact phrases that token search misses.
    func grepSearch(
        pattern: String,
        handles: [String],
        limit: Int
    ) throws -> [SearchResult] {
        var sql = """
            SELECT id, chat_name, start_date, end_date, transcript, message_ids
            FROM windows
            WHERE instr(lower(transcript), lower(?)) > 0
            """
        if !handles.isEmpty {
            let clauses = handles.map { _ in
                "(instr(lower(chat_name), ?) > 0 OR instr(lower(transcript), ?) > 0)"
            }
            sql += " AND (" + clauses.joined(separator: " OR ") + ")"
        }
        sql += " ORDER BY start_date DESC LIMIT ?"

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        try bind(pattern, to: bindIndex, in: statement)
        bindIndex += 1
        for handle in handles {
            try bind(handle.lowercased(), to: bindIndex, in: statement)
            try bind(handle.lowercased(), to: bindIndex + 1, in: statement)
            bindIndex += 2
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var results: [SearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(
                SearchResult(
                    id: columnText(statement, index: 0) ?? "",
                    chatName: columnText(statement, index: 1) ?? "Unknown chat",
                    startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    transcript: columnText(statement, index: 4) ?? "",
                    messageIDs: messageIDs(columnText(statement, index: 5)),
                    score: 0
                )
            )
        }
        try ensureStatementFinished(statement)
        return results
    }

    /// Newest conversation windows, optionally narrowed to a person's handles.
    func recentWindows(handles: [String], limit: Int) throws -> [SearchResult] {
        var sql = """
            SELECT id, chat_name, start_date, end_date, transcript, message_ids
            FROM windows
            """
        if !handles.isEmpty {
            let clauses = handles.map { _ in
                "(instr(lower(chat_name), ?) > 0 OR instr(lower(transcript), ?) > 0)"
            }
            sql += " WHERE " + clauses.joined(separator: " OR ")
        }
        sql += " ORDER BY start_date DESC LIMIT ?"

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for handle in handles {
            try bind(handle.lowercased(), to: bindIndex, in: statement)
            try bind(handle.lowercased(), to: bindIndex + 1, in: statement)
            bindIndex += 2
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var results: [SearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(
                SearchResult(
                    id: columnText(statement, index: 0) ?? "",
                    chatName: columnText(statement, index: 1) ?? "Unknown chat",
                    startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    transcript: columnText(statement, index: 4) ?? "",
                    messageIDs: messageIDs(columnText(statement, index: 5)),
                    score: 0
                )
            )
        }
        try ensureStatementFinished(statement)
        return results
    }

    func keywordSearch(
        query: String,
        limit: Int,
        chatIDs: Set<Int64>? = nil
    ) throws -> [SearchResult] {
        guard !query.isEmpty else {
            return []
        }

        var scopeClause = ""
        if let chatIDs {
            let placeholders = chatIDs.map { _ in "?" }.joined(separator: ",")
            scopeClause = "AND w.chat_id IN (\(placeholders))"
        }
        let statement = try prepare(
            """
            SELECT
                w.id, w.chat_name, w.start_date, w.end_date, w.transcript,
                w.message_ids, bm25(windows_fts)
            FROM windows_fts
            JOIN windows AS w ON w.id = windows_fts.window_id
            WHERE windows_fts MATCH ?
            \(scopeClause)
            ORDER BY bm25(windows_fts)
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(query, to: 1, in: statement)
        var bindIndex: Int32 = 2
        for chatID in chatIDs ?? [] {
            sqlite3_bind_int64(statement, bindIndex, chatID)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var results: [SearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(
                SearchResult(
                    id: columnText(statement, index: 0) ?? "",
                    chatName: columnText(statement, index: 1) ?? "Unknown chat",
                    startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    transcript: columnText(statement, index: 4) ?? "",
                    messageIDs: messageIDs(columnText(statement, index: 5)),
                    score: Float(-sqlite3_column_double(statement, 6))
                )
            )
        }
        try ensureStatementFinished(statement)
        return results
    }

    func conversationContext(
        windowID: String,
        before: Int,
        after: Int
    ) throws -> [SearchResult] {
        let targetStatement = try prepare(
            "SELECT chat_id FROM windows WHERE id = ?"
        )
        defer { sqlite3_finalize(targetStatement) }
        try bind(windowID, to: 1, in: targetStatement)
        guard sqlite3_step(targetStatement) == SQLITE_ROW else {
            return []
        }
        let chatID = sqlite3_column_int64(targetStatement, 0)

        let statement = try prepare(
            """
            SELECT
                id, chat_name, start_date, end_date, transcript, message_ids
            FROM windows
            WHERE chat_id = ?
            ORDER BY start_date
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chatID)

        var windows: [SearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            windows.append(
                SearchResult(
                    id: columnText(statement, index: 0) ?? "",
                    chatName: columnText(statement, index: 1) ?? "Unknown chat",
                    startDate: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 2)
                    ),
                    endDate: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 3)
                    ),
                    transcript: columnText(statement, index: 4) ?? "",
                    messageIDs: messageIDs(columnText(statement, index: 5)),
                    score: 0
                )
            )
        }
        try ensureStatementFinished(statement)

        guard let targetIndex = windows.firstIndex(where: { $0.id == windowID }) else {
            return []
        }
        let lowerBound = max(0, targetIndex - max(0, before))
        let upperBound = min(
            windows.count,
            targetIndex + max(0, after) + 1
        )
        return Array(windows[lowerBound..<upperBound])
    }

    func createThread() throws -> ChatThread {
        let thread = ChatThread(
            id: UUID().uuidString,
            title: "New conversation",
            createdAt: Date(),
            updatedAt: Date()
        )
        let statement = try prepare(
            """
            INSERT INTO answer_threads (id, title, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(thread.id, to: 1, in: statement)
        try bind(thread.title, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, thread.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, thread.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
        return thread
    }

    func threads() throws -> [ChatThread] {
        let statement = try prepare(
            """
            SELECT id, title, created_at, updated_at
            FROM answer_threads
            ORDER BY updated_at DESC
            """
        )
        defer { sqlite3_finalize(statement) }

        var threads: [ChatThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            threads.append(
                ChatThread(
                    id: columnText(statement, index: 0) ?? "",
                    title: columnText(statement, index: 1) ?? "Conversation",
                    createdAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 2)
                    ),
                    updatedAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 3)
                    )
                )
            )
        }
        try ensureStatementFinished(statement)
        return threads
    }

    func messages(threadID: String) throws -> [ChatMessage] {
        let statement = try prepare(
            """
            SELECT id, role, content, created_at
            FROM answer_messages
            WHERE thread_id = ?
            ORDER BY created_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(threadID, to: 1, in: statement)

        var messages: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let roleValue = columnText(statement, index: 1),
                  let role = ChatRole(rawValue: roleValue) else {
                continue
            }
            let messageID = columnText(statement, index: 0) ?? ""
            messages.append(
                ChatMessage(
                    id: messageID,
                    threadID: threadID,
                    role: role,
                    content: columnText(statement, index: 2) ?? "",
                    createdAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 3)
                    ),
                    sources: try sources(messageID: messageID),
                    activities: try activities(messageID: messageID)
                )
            )
        }
        try ensureStatementFinished(statement)
        return messages
    }

    func saveMessage(
        threadID: String,
        role: ChatRole,
        content: String,
        sources: [AnswerSource],
        activities: [AgentActivity]
    ) throws -> ChatMessage {
        let message = ChatMessage(
            id: UUID().uuidString,
            threadID: threadID,
            role: role,
            content: content,
            createdAt: Date(),
            sources: sources,
            activities: activities
        )

        try execute("BEGIN IMMEDIATE")
        do {
            let insertMessage = try prepare(
                """
                INSERT INTO answer_messages (
                    id, thread_id, role, content, created_at
                ) VALUES (?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(insertMessage) }
            try bind(message.id, to: 1, in: insertMessage)
            try bind(threadID, to: 2, in: insertMessage)
            try bind(role.rawValue, to: 3, in: insertMessage)
            try bind(content, to: 4, in: insertMessage)
            sqlite3_bind_double(
                insertMessage,
                5,
                message.createdAt.timeIntervalSince1970
            )
            try stepDone(insertMessage)

            let insertSource = try prepare(
                """
                INSERT INTO answer_sources (
                    id, message_id, position, label, window_id, chat_name,
                    start_date, end_date, transcript
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(insertSource) }
            for (index, source) in sources.enumerated() {
                try bind(source.id, to: 1, in: insertSource)
                try bind(message.id, to: 2, in: insertSource)
                sqlite3_bind_int(insertSource, 3, Int32(index))
                try bind(source.label, to: 4, in: insertSource)
                try bind(source.windowID, to: 5, in: insertSource)
                try bind(source.chatName, to: 6, in: insertSource)
                sqlite3_bind_double(
                    insertSource,
                    7,
                    source.startDate.timeIntervalSince1970
                )
                sqlite3_bind_double(
                    insertSource,
                    8,
                    source.endDate.timeIntervalSince1970
                )
                try bind(source.transcript, to: 9, in: insertSource)
                try stepDone(insertSource)
            }

            let insertActivity = try prepare(
                """
                INSERT INTO answer_activities (
                    id, message_id, position, tool_name, title, detail,
                    result_count, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(insertActivity) }
            for (index, activity) in activities.enumerated() {
                try bind(activity.id, to: 1, in: insertActivity)
                try bind(message.id, to: 2, in: insertActivity)
                sqlite3_bind_int(insertActivity, 3, Int32(index))
                try bind(activity.toolName, to: 4, in: insertActivity)
                try bind(activity.title, to: 5, in: insertActivity)
                try bind(activity.detail, to: 6, in: insertActivity)
                if let resultCount = activity.resultCount {
                    sqlite3_bind_int(insertActivity, 7, Int32(resultCount))
                } else {
                    sqlite3_bind_null(insertActivity, 7)
                }
                sqlite3_bind_double(
                    insertActivity,
                    8,
                    activity.createdAt.timeIntervalSince1970
                )
                try stepDone(insertActivity)
            }

            let updateThread = try prepare(
                """
                UPDATE answer_threads
                SET
                    title = CASE
                        WHEN title = 'New conversation' AND ? = 'user' THEN ?
                        ELSE title
                    END,
                    updated_at = ?
                WHERE id = ?
                """
            )
            defer { sqlite3_finalize(updateThread) }
            try bind(role.rawValue, to: 1, in: updateThread)
            try bind(threadTitle(from: content), to: 2, in: updateThread)
            sqlite3_bind_double(
                updateThread,
                3,
                message.createdAt.timeIntervalSince1970
            )
            try bind(threadID, to: 4, in: updateThread)
            try stepDone(updateThread)

            try execute("COMMIT")
            return message
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func deleteThread(id: String) throws {
        let statement = try prepare(
            "DELETE FROM answer_threads WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: 1, in: statement)
        try stepDone(statement)
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS windows (
                id TEXT PRIMARY KEY,
                chat_id INTEGER NOT NULL,
                chat_name TEXT NOT NULL,
                start_date REAL NOT NULL,
                end_date REAL NOT NULL,
                transcript TEXT NOT NULL,
                message_ids TEXT NOT NULL,
                content_hash TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE IF NOT EXISTS windows_fts USING fts5(
                window_id UNINDEXED,
                transcript
            );

            CREATE TABLE IF NOT EXISTS embeddings (
                window_id TEXT NOT NULL REFERENCES windows(id) ON DELETE CASCADE,
                model TEXT NOT NULL,
                dimension INTEGER NOT NULL,
                vector BLOB NOT NULL,
                PRIMARY KEY (window_id, model)
            );

            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS answer_threads (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS answer_messages (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL
                    REFERENCES answer_threads(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS answer_sources (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL
                    REFERENCES answer_messages(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                label TEXT NOT NULL,
                window_id TEXT NOT NULL,
                chat_name TEXT NOT NULL,
                start_date REAL NOT NULL,
                end_date REAL NOT NULL,
                transcript TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS answer_activities (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL
                    REFERENCES answer_messages(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                tool_name TEXT NOT NULL,
                title TEXT NOT NULL,
                detail TEXT NOT NULL,
                result_count INTEGER,
                created_at REAL NOT NULL
            );

            CREATE TRIGGER IF NOT EXISTS delete_changed_embeddings
            AFTER UPDATE OF content_hash ON windows
            WHEN old.content_hash <> new.content_hash
            BEGIN
                DELETE FROM embeddings WHERE window_id = old.id;
            END;
            """
        )
    }

    private func sources(messageID: String) throws -> [AnswerSource] {
        let statement = try prepare(
            """
            SELECT
                id, label, window_id, chat_name, start_date, end_date, transcript
            FROM answer_sources
            WHERE message_id = ?
            ORDER BY position
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(messageID, to: 1, in: statement)

        var sources: [AnswerSource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            sources.append(
                AnswerSource(
                    id: columnText(statement, index: 0) ?? "",
                    label: columnText(statement, index: 1) ?? "",
                    windowID: columnText(statement, index: 2) ?? "",
                    chatName: columnText(statement, index: 3) ?? "Unknown chat",
                    startDate: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 4)
                    ),
                    endDate: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 5)
                    ),
                    transcript: columnText(statement, index: 6) ?? ""
                )
            )
        }
        try ensureStatementFinished(statement)
        return sources
    }

    private func activities(messageID: String) throws -> [AgentActivity] {
        let statement = try prepare(
            """
            SELECT
                id, tool_name, title, detail, result_count, created_at
            FROM answer_activities
            WHERE message_id = ?
            ORDER BY position
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(messageID, to: 1, in: statement)

        var activities: [AgentActivity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let resultCount = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int(statement, 4))
            activities.append(
                AgentActivity(
                    id: columnText(statement, index: 0) ?? "",
                    toolName: columnText(statement, index: 1) ?? "",
                    title: columnText(statement, index: 2) ?? "",
                    detail: columnText(statement, index: 3) ?? "",
                    resultCount: resultCount,
                    createdAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 5)
                    )
                )
            )
        }
        try ensureStatementFinished(statement)
        return activities
    }

    private func threadTitle(from content: String) -> String {
        let singleLine = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(60))
    }

    private func removeObsoleteEmbeddingData() throws {
        try execute(
            """
            DELETE FROM embeddings
            WHERE model NOT IN (
                'qwen3-embedding:0.6b',
                'qwen3-embedding:4b'
            );
            DROP TABLE IF EXISTS evaluations;
            """
        )
    }

    private func window(from statement: OpaquePointer?) -> ConversationWindow {
        return ConversationWindow(
            id: columnText(statement, index: 0) ?? "",
            chatID: sqlite3_column_int64(statement, 1),
            chatName: columnText(statement, index: 2) ?? "Unknown chat",
            startDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            endDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            transcript: columnText(statement, index: 5) ?? "",
            messageIDs: messageIDs(columnText(statement, index: 6)),
            contentHash: columnText(statement, index: 7) ?? ""
        )
    }

    private func messageIDs(_ value: String?) -> [Int64] {
        (value ?? "")
            .split(separator: ",")
            .compactMap { Int64($0) }
    }

    private func vectorData(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(
                bytes: buffer.baseAddress!,
                count: buffer.count * MemoryLayout<Float>.size
            )
        }
    }

    private func columnVector(
        _ statement: OpaquePointer?,
        index: Int32,
        dimension: Int
    ) -> [Float]? {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        let expectedByteCount = dimension * MemoryLayout<Float>.size
        guard byteCount == expectedByteCount,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }

        var vector = [Float](repeating: 0, count: dimension)
        vector.withUnsafeMutableBytes { destination in
            destination.copyBytes(from: UnsafeRawBufferPointer(
                start: bytes,
                count: byteCount
            ))
        }
        return vector
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(error)
            throw IndexStoreError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexStoreError.database(errorMessage())
        }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw IndexStoreError.database(errorMessage())
        }
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw IndexStoreError.database(errorMessage())
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexStoreError.database(errorMessage())
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func ensureStatementFinished(_ statement: OpaquePointer?) throws {
        guard sqlite3_errcode(database) == SQLITE_OK ||
                sqlite3_errcode(database) == SQLITE_DONE else {
            throw IndexStoreError.database(errorMessage())
        }
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func errorMessage() -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "Unknown error"
        }
        return String(cString: message)
    }
}
