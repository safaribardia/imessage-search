import Foundation

struct MessageRecord: Sendable {
    let rowID: Int64
    let chatID: Int64
    let chatName: String
    let sender: String
    let date: Date
    let text: String
}

struct MessageConversation: Identifiable, Sendable {
    enum Kind: Sendable {
        case person(handle: String)
        case group(rawName: String, participants: [String])
    }

    let kind: Kind
    /// Handle ROWID for people, chat ROWID for group chats.
    let rowID: Int64
    let lastMessageDate: Date

    var id: String {
        switch kind {
        case .person:
            "person-\(rowID)"
        case .group:
            "group-\(rowID)"
        }
    }

    var isGroup: Bool {
        if case .group = kind {
            return true
        }
        return false
    }

    func title(using map: HandleNameMap) -> String {
        switch kind {
        case .person(let handle):
            map.displayName(for: handle)
        case .group(let rawName, let participants):
            map.chatTitle(rawName: rawName, participants: participants)
        }
    }
}

struct PersonHistoryMessage: Identifiable, Sendable {
    let id: Int64
    let sender: String
    let date: Date
    let text: String
    let attachments: [MessageAttachment]

    var isFromMe: Bool { sender == "Me" }
}

struct MessageAttachment: Identifiable, Sendable {
    let id: Int64
    let name: String
    let localURL: URL?
    let uti: String?
    let mimeType: String?
    let byteCount: Int64
    let isSticker: Bool
}

struct ConversationWindow: Identifiable, Sendable {
    let id: String
    let chatID: Int64
    let chatName: String
    let startDate: Date
    let endDate: Date
    let transcript: String
    let messageIDs: [Int64]
    let contentHash: String
}

enum EmbeddingModel: String, CaseIterable, Sendable {
    case fast = "qwen3-embedding:0.6b"
    case quality = "qwen3-embedding:4b"

    var displayName: String {
        switch self {
        case .fast:
            "Qwen3 0.6B"
        case .quality:
            "Qwen3 4B"
        }
    }
}

struct EmbeddingCoverage: Equatable, Sendable {
    let completed: Int
    let total: Int

    var fraction: Double {
        total == 0 ? 1 : Double(completed) / Double(total)
    }

    var isComplete: Bool {
        completed >= total
    }
}

enum QualityIndexState: Equatable, Sendable {
    case checking
    case installing(fraction: Double?, status: String)
    case building(EmbeddingCoverage)
    case paused(EmbeddingCoverage)
    case ready
    case needsModel
    case failed(String)
}

struct SearchResult: Identifiable, Sendable {
    let id: String
    let chatName: String
    let startDate: Date
    let endDate: Date
    let transcript: String
    let messageIDs: [Int64]
    let score: Float
}

struct IndexProgress: Sendable {
    let fraction: Double
    let status: String
}

struct IndexSummary: Sendable {
    let messageCount: Int
    let windowCount: Int
}

enum AnswerProvider: Equatable, Sendable {
    case chatGPT(accountLabel: String)
    case ollama(modelName: String)
}

enum AppSection: Sendable {
    case search
    case ask
    case settings
}

enum ChatRole: String, Sendable {
    case user
    case assistant
}

struct ChatThread: Identifiable, Sendable {
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
}

struct AnswerSource: Identifiable, Sendable {
    let id: String
    let label: String
    let windowID: String
    let chatName: String
    let startDate: Date
    let endDate: Date
    let transcript: String
}

struct ChatMessage: Identifiable, Sendable {
    let id: String
    let threadID: String
    let role: ChatRole
    let content: String
    let createdAt: Date
    let sources: [AnswerSource]
    let activities: [AgentActivity]
}

struct GeneratedAnswer: Sendable {
    let content: String
    let sources: [AnswerSource]
    let activities: [AgentActivity]
}

struct AgentActivity: Identifiable, Sendable {
    let id: String
    let toolName: String
    let title: String
    let detail: String
    let resultCount: Int?
    let createdAt: Date
}

struct TranscriptMessage: Identifiable {
    let id: Int
    let sender: String
    let text: String

    var isFromMe: Bool { sender == "Me" }
}

/// Maps raw message handles (phone numbers, emails) to contact names and photos.
struct HandleNameMap: Sendable {
    let names: [String: String]
    let thumbnails: [String: Data]

    init(names: [String: String], thumbnails: [String: Data] = [:]) {
        self.names = names
        self.thumbnails = thumbnails
    }

    func displayName(for handle: String) -> String {
        lookup(handle, in: names) ?? handle
    }

    func thumbnail(for handle: String) -> Data? {
        lookup(handle, in: thumbnails)
    }

    private func lookup<Value>(_ handle: String, in table: [String: Value]) -> Value? {
        if handle.contains("@") {
            return table[handle.lowercased()]
        }
        let digits = handle.filter(\.isNumber)
        guard digits.count >= 7 else {
            return nil
        }
        return table[digits] ?? table[String(digits.suffix(10))]
    }

    /// Human title for a chat: resolves one-on-one handles directly and names
    /// unnamed group chats ("chat1234…") after their participants.
    func chatTitle(rawName: String, participants: [String]) -> String {
        guard rawName.hasPrefix("chat"),
              rawName.dropFirst(4).allSatisfy(\.isNumber) else {
            return displayName(for: rawName)
        }

        var firstNames: [String] = []
        for participant in participants {
            let name = displayName(for: participant)
            let firstName = name.split(separator: " ").first.map(String.init) ?? name
            if !firstNames.contains(firstName) {
                firstNames.append(firstName)
            }
        }
        if firstNames.isEmpty {
            return "Group chat"
        }
        if firstNames.count <= 3 {
            return firstNames.joined(separator: ", ")
        }
        return firstNames.prefix(3).joined(separator: ", ") + " +\(firstNames.count - 3)"
    }
}

extension String {
    /// Transcripts begin with a "Conversation: <chat>" line that is redundant
    /// wherever the chat name is already shown.
    var withoutConversationHeader: String {
        guard hasPrefix("Conversation:") else {
            return self
        }
        guard let newlineIndex = firstIndex(of: "\n") else {
            return self
        }
        return String(self[index(after: newlineIndex)...])
    }

    /// Splits a stored "Sender: text" transcript back into individual
    /// messages. Senders are handles ("Me", phone numbers, emails) and never
    /// contain spaces; lines without such a prefix continue the previous
    /// message.
    var transcriptMessages: [TranscriptMessage] {
        var messages: [(sender: String, text: String)] = []
        for line in withoutConversationHeader
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if let separatorRange = line.range(of: ": "),
               !line[line.startIndex..<separatorRange.lowerBound].contains(" ") {
                messages.append(
                    (
                        sender: String(line[..<separatorRange.lowerBound]),
                        text: String(line[separatorRange.upperBound...])
                    )
                )
            } else if !messages.isEmpty {
                messages[messages.count - 1].text += "\n" + line
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                messages.append((sender: "", text: String(line)))
            }
        }
        return messages.enumerated()
            .filter {
                !$0.element.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            .map {
                TranscriptMessage(
                    id: $0.offset,
                    sender: $0.element.sender,
                    text: $0.element.text
                )
            }
    }

    /// Rewrites a raw "handle: text" transcript with contact names substituted.
    func transcriptResolved(using map: HandleNameMap) -> String {
        transcriptMessages
            .map { message in
                let sender = message.isFromMe
                    ? "Me"
                    : map.displayName(for: message.sender)
                return "\(sender): \(message.text)"
            }
            .joined(separator: "\n")
    }
}

enum AnswerModel {
    /// Overridable via environment for A/B experiments; the app defaults
    /// to Qwen3 8B.
    static let name = ProcessInfo.processInfo.environment["ANSWER_MODEL"] ?? "qwen3:8b"
}
