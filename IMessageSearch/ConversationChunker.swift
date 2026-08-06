import CryptoKit
import Foundation

struct ConversationChunker {
    private let maximumMessages = 12
    private let overlapMessages = 2
    private let maximumCharacters = 4_000
    private let maximumGap: TimeInterval = 15 * 60

    func makeWindows(from messages: [MessageRecord]) -> [ConversationWindow] {
        guard !messages.isEmpty else {
            return []
        }

        var windows: [ConversationWindow] = []
        var current: [MessageRecord] = []

        for message in messages.flatMap(splitLongMessage) {
            if let previous = current.last {
                let sameChat = previous.chatID == message.chatID
                let gap = message.date.timeIntervalSince(previous.date)
                let reachedSizeLimit = current.count >= maximumMessages
                let reachedCharacterLimit =
                    characterCount(current) + characterCount([message]) > maximumCharacters
                let shouldSplit =
                    !sameChat ||
                    gap > maximumGap ||
                    reachedSizeLimit ||
                    reachedCharacterLimit

                if shouldSplit {
                    windows.append(makeWindow(from: current))
                    if sameChat &&
                        gap <= maximumGap &&
                        reachedSizeLimit &&
                        !reachedCharacterLimit {
                        current = Array(current.suffix(overlapMessages))
                    } else {
                        current.removeAll(keepingCapacity: true)
                    }
                }
            }
            current.append(message)
        }

        if !current.isEmpty {
            windows.append(makeWindow(from: current))
        }
        return windows
    }

    private func splitLongMessage(_ message: MessageRecord) -> [MessageRecord] {
        let maximumTextCharacters = maximumCharacters - message.sender.count - 100
        guard message.text.count > maximumTextCharacters else {
            return [message]
        }

        var fragments: [MessageRecord] = []
        var start = message.text.startIndex
        while start < message.text.endIndex {
            let end = message.text.index(
                start,
                offsetBy: maximumTextCharacters,
                limitedBy: message.text.endIndex
            ) ?? message.text.endIndex
            fragments.append(
                MessageRecord(
                    rowID: message.rowID,
                    chatID: message.chatID,
                    chatName: message.chatName,
                    sender: message.sender,
                    date: message.date,
                    text: String(message.text[start..<end])
                )
            )
            start = end
        }
        return fragments
    }

    private func characterCount(_ messages: [MessageRecord]) -> Int {
        guard let first = messages.first else {
            return 0
        }
        return "Conversation: \(first.chatName)".count +
            messages.reduce(0) { count, message in
                count + message.sender.count + message.text.count + 3
            }
    }

    private func makeWindow(from messages: [MessageRecord]) -> ConversationWindow {
        let first = messages[0]
        let last = messages[messages.count - 1]
        let transcriptLines = messages.map { "\($0.sender): \($0.text)" }
        let transcript = (["Conversation: \(first.chatName)"] + transcriptLines)
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(transcript.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return ConversationWindow(
            id: "\(first.chatID):\(first.rowID):\(last.rowID):\(digest.prefix(12))",
            chatID: first.chatID,
            chatName: first.chatName,
            startDate: first.date,
            endDate: last.date,
            transcript: transcript,
            messageIDs: messages.map(\.rowID),
            contentHash: digest
        )
    }
}
