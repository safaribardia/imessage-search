import AppKit
import SwiftUI

@MainActor
final class PeopleModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var conversations: [MessageConversation] = []
    @Published private(set) var selectedConversationID: String?
    @Published private(set) var messages: [PersonHistoryMessage] = []
    @Published private(set) var isLoadingConversations = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var canLoadEarlier = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedMessageIDs: Set<Int64> = []
    /// Message the history view should scroll to and flash, set by "See
    /// full chat" navigation from the Chat tab.
    @Published private(set) var revealedMessageID: Int64?
    /// Toolbar search text; submitted searches run within the selected
    /// conversation. Nil results mean no search is active.
    @Published var threadQuery = ""
    @Published private(set) var threadResults: [SearchResult]?
    @Published private(set) var isSearchingThread = false

    private let pageSize = 400
    private var historyOffset = 0
    private var hasStarted = false
    private var conversationsTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var threadSearchTask: Task<Void, Never>?
    /// The Chat tab's engine, shared so both tabs use one index store.
    private var engine: SearchEngine?
    /// Last message the user plain-clicked; shift-clicks select the whole
    /// chronological range between this anchor and the clicked message.
    private var selectionAnchorID: Int64?

    var selectedConversation: MessageConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    func attach(engine: SearchEngine) {
        self.engine = engine
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        isLoadingConversations = true
        errorMessage = nil

        conversationsTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let conversations = try await Task.detached(priority: .userInitiated) {
                    try MessagesReader().readConversations()
                }.value
                try Task.checkCancellation()
                self.conversations = conversations
                self.isLoadingConversations = false
                if self.selectedConversationID == nil, let first = conversations.first {
                    self.select(first)
                }
            } catch is CancellationError {
                self.isLoadingConversations = false
            } catch {
                self.isLoadingConversations = false
                self.errorMessage = error.localizedDescription
            }
            self.conversationsTask = nil
        }
    }

    func select(_ conversation: MessageConversation) {
        guard conversation.id != selectedConversationID else {
            return
        }
        historyTask?.cancel()
        selectedConversationID = conversation.id
        messages = []
        historyOffset = 0
        canLoadEarlier = false
        errorMessage = nil
        revealedMessageID = nil
        clearMessageSelection()
        threadQuery = ""
        exitThreadSearch()
        loadHistory(for: conversation, reset: true)
    }

    /// Hybrid (semantic + keyword) search scoped to the selected
    /// conversation's chat IDs in the index.
    func searchThread() {
        let query = threadQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let conversation = selectedConversation,
              let engine else {
            return
        }
        threadSearchTask?.cancel()
        isSearchingThread = true
        errorMessage = nil

        threadSearchTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                // Group conversations are their chat ROWID; a person spans
                // their 1:1 chats (typically iMessage + SMS).
                let chatIDs: Set<Int64>
                if conversation.isGroup {
                    chatIDs = [conversation.rowID]
                } else {
                    chatIDs = Set(
                        try await Task.detached(priority: .userInitiated) {
                            try MessagesReader()
                                .directChatIDs(handleID: conversation.rowID)
                        }.value
                    )
                }
                let results = try await engine.search(query: query, chatIDs: chatIDs)
                try Task.checkCancellation()
                guard self.selectedConversationID == conversation.id else {
                    return
                }
                self.threadResults = results
                self.isSearchingThread = false
            } catch is CancellationError {
            } catch {
                self.isSearchingThread = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func exitThreadSearch() {
        threadSearchTask?.cancel()
        threadResults = nil
        isSearchingThread = false
    }

    /// Leaves search mode and scrolls the thread to the result's excerpt.
    func openSearchResult(_ result: SearchResult) {
        guard let messageID = result.messageIDs.first else {
            return
        }
        threadQuery = ""
        exitThreadSearch()
        reveal(messageID: messageID)
    }

    /// Jumps to the conversation containing the given message and loads
    /// enough history (whole pages, so "load earlier" stays consistent) for
    /// the message to be on screen.
    func reveal(messageID: Int64) {
        start()
        historyTask?.cancel()
        errorMessage = nil
        revealedMessageID = nil
        threadQuery = ""
        exitThreadSearch()

        historyTask = Task { [weak self] in
            guard let self else {
                return
            }
            // The conversation list may still be loading on first launch.
            if let conversationsTask = self.conversationsTask {
                await conversationsTask.value
            }
            do {
                let location = try await Task.detached(priority: .userInitiated) {
                    try MessagesReader().locateMessage(rowID: messageID)
                }.value
                try Task.checkCancellation()
                guard let location,
                      let conversation = self.conversations.first(where: {
                          $0.isGroup == location.isGroup &&
                          $0.rowID == location.conversationRowID
                      }) else {
                    self.errorMessage = "That conversation could not be found in Messages."
                    return
                }

                self.selectedConversationID = conversation.id
                self.messages = []
                self.canLoadEarlier = false
                self.clearMessageSelection()
                self.isLoadingHistory = true

                // Round up to whole pages so historyOffset stays a page
                // multiple and later "load earlier" clicks continue cleanly.
                let needed = location.newerCount + 1
                let limit = ((needed + self.pageSize - 1) / self.pageSize) * self.pageSize
                let page = try await Task.detached(priority: .userInitiated) {
                    let reader = MessagesReader()
                    return conversation.isGroup
                        ? try reader.readGroupMessageHistory(
                            chatID: conversation.rowID,
                            limit: limit,
                            offset: 0
                        )
                        : try reader.readMessageHistory(
                            personID: conversation.rowID,
                            limit: limit,
                            offset: 0
                        )
                }.value
                try Task.checkCancellation()
                guard self.selectedConversationID == conversation.id else {
                    return
                }
                self.messages = page
                self.historyOffset = limit
                self.canLoadEarlier = page.count == limit
                self.isLoadingHistory = false
                self.revealedMessageID = messageID
                self.historyTask = nil
            } catch is CancellationError {
            } catch {
                self.isLoadingHistory = false
                self.errorMessage = error.localizedDescription
                self.historyTask = nil
            }
        }
    }

    /// Called by the history view once the reveal scroll and flash finish.
    func finishReveal() {
        revealedMessageID = nil
    }

    /// Plain click: selects just this message and anchors future
    /// shift-click range selections to it (Finder-style).
    func selectMessage(_ id: Int64) {
        guard messages.contains(where: { $0.id == id }) else {
            return
        }
        selectionAnchorID = id
        selectedMessageIDs = [id]
    }

    /// Shift-click: selects everything between the anchor and the clicked
    /// message; without an anchor it behaves like a plain click.
    func extendMessageSelection(to id: Int64) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let anchorID = selectionAnchorID,
           let anchorIndex = messages.firstIndex(where: { $0.id == anchorID }) {
            let range = min(anchorIndex, index)...max(anchorIndex, index)
            selectedMessageIDs = Set(messages[range].map(\.id))
        } else {
            selectionAnchorID = id
            selectedMessageIDs = [id]
        }
    }

    func clearMessageSelection() {
        selectionAnchorID = nil
        selectedMessageIDs = []
    }

    /// Copies the selected messages chronologically, one per line, prefixed
    /// with the sender's display name so pasted threads read naturally.
    func copySelectedMessages() {
        guard !selectedMessageIDs.isEmpty else {
            return
        }
        let map = ContactsResolver.shared.map
        let transcript = messages
            .filter { selectedMessageIDs.contains($0.id) }
            .map { message in
                let sender = message.isFromMe
                    ? "Me"
                    : map.displayName(for: message.sender)
                return "\(sender): \(message.text)"
            }
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
    }

    func loadEarlier() {
        guard canLoadEarlier,
              !isLoadingHistory,
              let conversation = selectedConversation else {
            return
        }
        loadHistory(for: conversation, reset: false)
    }

    private func loadHistory(for conversation: MessageConversation, reset: Bool) {
        let offset = reset ? 0 : historyOffset
        let limit = pageSize
        isLoadingHistory = true
        historyTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let page = try await Task.detached(priority: .userInitiated) {
                    let reader = MessagesReader()
                    return conversation.isGroup
                        ? try reader.readGroupMessageHistory(
                            chatID: conversation.rowID,
                            limit: limit,
                            offset: offset
                        )
                        : try reader.readMessageHistory(
                            personID: conversation.rowID,
                            limit: limit,
                            offset: offset
                        )
                }.value
                try Task.checkCancellation()
                guard self.selectedConversationID == conversation.id else {
                    return
                }

                if reset {
                    self.messages = page
                } else {
                    self.messages.insert(contentsOf: page, at: 0)
                }
                self.historyOffset = offset + limit
                self.canLoadEarlier = page.count == limit
                self.isLoadingHistory = false
                self.historyTask = nil
            } catch is CancellationError {
                if self.selectedConversationID == conversation.id {
                    self.isLoadingHistory = false
                }
            } catch {
                guard self.selectedConversationID == conversation.id else {
                    return
                }
                self.isLoadingHistory = false
                self.errorMessage = error.localizedDescription
                self.historyTask = nil
            }
        }
    }
}

struct PeopleSidebar: View {
    @ObservedObject var model: PeopleModel
    @ObservedObject private var contacts = ContactsResolver.shared

    private var filteredConversations: [MessageConversation] {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return model.conversations
        }
        return model.conversations.filter { conversation in
            if conversation.title(using: contacts.map)
                .localizedCaseInsensitiveContains(query) {
                return true
            }
            switch conversation.kind {
            case .person(let handle):
                return handle.localizedCaseInsensitiveContains(query)
            case .group(_, let participants):
                return participants.contains { participant in
                    participant.localizedCaseInsensitiveContains(query) ||
                    contacts.map.displayName(for: participant)
                        .localizedCaseInsensitiveContains(query)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterField
            conversationList
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    }

    /// Quiet inline filter for the conversation list; the toolbar search
    /// field searches within the selected conversation instead.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("", text: $model.query, prompt: Text("Filter"))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var conversationList: some View {
        Group {
            if model.isLoadingConversations && model.conversations.isEmpty {
                ProgressView("Loading people…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredConversations.isEmpty {
                VStack(spacing: 5) {
                    Text(model.query.isEmpty ? "No people" : "No matches")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(model.query.isEmpty
                         ? "Your Messages history is empty."
                         : "Try another name or handle.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredConversations) { conversation in
                            ConversationSidebarRow(
                                conversation: conversation,
                                isSelected: model.selectedConversationID == conversation.id
                            ) {
                                model.select(conversation)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

private struct ConversationSidebarRow: View {
    let conversation: MessageConversation
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject private var contacts = ContactsResolver.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ConversationAvatar(conversation: conversation, size: 30)

                Text(conversation.title(using: contacts.map))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(conversation.lastMessageDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointingHandCursor()
    }

    private var rowFill: Color {
        if isSelected {
            return Color.primary.opacity(0.09)
        }
        if isHovered {
            return Color.primary.opacity(0.045)
        }
        return .clear
    }
}

/// Contact photo for people; a symbol circle for group chats.
private struct ConversationAvatar: View {
    let conversation: MessageConversation
    let size: CGFloat

    var body: some View {
        switch conversation.kind {
        case .person(let handle):
            ContactAvatar(handle: handle, size: size)
        case .group:
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        }
    }
}

struct PeopleDetail: View {
    @ObservedObject var model: PeopleModel
    @ObservedObject private var contacts = ContactsResolver.shared

    private var title: String {
        model.selectedConversation?.title(using: contacts.map) ?? "People"
    }

    var body: some View {
        Group {
            if let conversation = model.selectedConversation {
                VStack(spacing: 0) {
                    header(conversation)

                    if model.isSearchingThread {
                        ProgressView("Searching this conversation…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let results = model.threadResults {
                        if results.isEmpty {
                            VStack(spacing: 5) {
                                Text("No matches")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text("Nothing in this conversation matches that search.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(results) { result in
                                SearchResultRow(result: result) {
                                    model.openSearchResult(result)
                                }
                                .listRowSeparator(.hidden)
                            }
                            .listStyle(.inset)
                        }
                    } else if model.isLoadingHistory && model.messages.isEmpty {
                        ProgressView("Loading message history…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.messages.isEmpty {
                        VStack(spacing: 5) {
                            Text("No message history")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("There are no readable messages in this conversation.")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PersonHistory(model: model, showsSenders: conversation.isGroup)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select a conversation")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Its message history will appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
    }

    private func header(_ conversation: MessageConversation) -> some View {
        HStack(spacing: 12) {
            ConversationAvatar(conversation: conversation, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = subtitle(for: conversation) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func subtitle(for conversation: MessageConversation) -> String? {
        switch conversation.kind {
        case .person(let handle):
            return title == handle ? nil : handle
        case .group(_, let participants):
            let count = participants.count
            return count == 1 ? "1 person" : "\(count) people"
        }
    }
}

private struct PersonHistory: View {
    private struct Row: Identifiable {
        let message: PersonHistoryMessage
        let showsDate: Bool
        let showsSender: Bool

        var id: Int64 { message.id }
    }

    @ObservedObject var model: PeopleModel
    let showsSenders: Bool

    private var rows: [Row] {
        let calendar = Calendar.current
        return model.messages.indices.map { index in
            let message = model.messages[index]
            let previous = index > 0 ? model.messages[index - 1] : nil
            let isNewDay = previous.map {
                !calendar.isDate($0.date, inSameDayAs: message.date)
            } ?? true
            return Row(
                message: message,
                showsDate: isNewDay,
                // Group chats label who's speaking at the start of each run.
                showsSender: showsSenders &&
                    !message.isFromMe &&
                    (isNewDay || previous?.sender != message.sender)
            )
        }
    }

    /// Top-most message before a prepend; scrolling back to it keeps the
    /// view visually stable after older messages load in above.
    @State private var pendingTopAnchorID: Int64?
    /// Briefly highlights the message a "See full chat" jump landed on.
    @State private var flashedMessageID: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.canLoadEarlier || model.isLoadingHistory {
                        Button {
                            pendingTopAnchorID = model.messages.first?.id
                            model.loadEarlier()
                        } label: {
                            HStack(spacing: 7) {
                                if model.isLoadingHistory {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                                Text(model.isLoadingHistory
                                     ? "Loading earlier messages…"
                                     : "Load earlier messages")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoadingHistory)
                        .pointingHandCursor()
                        .padding(.bottom, 8)
                    }

                    ForEach(rows) { row in
                        if row.showsDate {
                            HistoryDateDivider(date: row.message.date)
                        }
                        let isSelected =
                            model.selectedMessageIDs.contains(row.message.id)
                            || flashedMessageID == row.message.id
                        PersonMessageBubble(
                            message: row.message,
                            showsSender: row.showsSender,
                            isSelected: isSelected,
                            onClick: { isShiftClick in
                                if isShiftClick {
                                    model.extendMessageSelection(to: row.message.id)
                                } else {
                                    model.selectMessage(row.message.id)
                                }
                            }
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.clearMessageSelection()
                        }
                }
            }
            .onChange(of: model.messages.count) {
                guard let anchorID = pendingTopAnchorID else {
                    return
                }
                pendingTopAnchorID = nil
                // Wait a runloop turn so the prepended rows are laid out
                // before re-anchoring the previous top message.
                Task { @MainActor in
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
            // Reveals arrive either with the view (conversation switch
            // recreates it) or in place (already-selected conversation).
            .onAppear {
                revealIfNeeded(proxy)
            }
            .onChange(of: model.revealedMessageID) {
                revealIfNeeded(proxy)
            }
        }
        // Opens pinned to the newest message. The id ties the scroll view's
        // lifetime to the conversation, so each selection starts at the
        // bottom again instead of inheriting the previous scroll position.
        .defaultScrollAnchor(.bottom)
        .id(model.selectedConversationID)
        // Only intercept Cmd+C and Esc while bubbles are selected, so normal
        // drag-based text selection keeps its native copy behavior.
        .background {
            if !model.selectedMessageIDs.isEmpty {
                Group {
                    Button("Copy Selected Messages") {
                        model.copySelectedMessages()
                    }
                    .keyboardShortcut("c", modifiers: .command)
                    Button("Clear Message Selection") {
                        model.clearMessageSelection()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// Scrolls the revealed message to center, repeating while the lazy
    /// rows settle into their real heights, then fades a brief highlight.
    private func revealIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = model.revealedMessageID else {
            return
        }
        flashedMessageID = target
        proxy.scrollTo(target, anchor: .center)
        Task { @MainActor in
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(90))
                proxy.scrollTo(target, anchor: .center)
            }
            model.finishReveal()
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeOut(duration: 0.5)) {
                flashedMessageID = nil
            }
        }
    }
}

private struct HistoryDateDivider: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }
}

private struct PersonMessageBubble: View {
    let message: PersonHistoryMessage
    let showsSender: Bool
    let isSelected: Bool
    let onClick: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var contacts = ContactsResolver.shared
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsSender {
                Text(contacts.map.displayName(for: message.sender))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 13)
            }

            HStack(alignment: .bottom, spacing: 7) {
                if message.isFromMe {
                    Spacer(minLength: 80)
                    timestamp
                }

                SelectableBubbleText(
                    text: message.text,
                    textColor: message.isFromMe ? outgoingTextColor : .labelColor,
                    onClick: onClick
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7.5)
                    .background(
                        message.isFromMe ? outgoingFill : incomingFill,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                selectionRing.opacity(isSelected ? 1 : 0),
                                lineWidth: 1.5
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    // The native selectable text view handles clicks on its
                    // glyphs; this catches clicks in the bubble's padding.
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            onClick(NSEvent.modifierFlags.contains(.shift))
                        }
                    )

                if !message.isFromMe {
                    timestamp
                    Spacer(minLength: 80)
                }
            }
        }
        .padding(.vertical, 1)
        .onHover { isHovered = $0 }
    }

    /// Sits beside the bubble and only appears while hovering, so the
    /// transcript stays clean.
    private var timestamp: some View {
        Text(message.date, format: .dateTime.hour().minute())
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 4)
            .opacity(isHovered ? 1 : 0)
    }

    private var selectionRing: Color {
        Color(nsColor: .systemBlue)
    }

    private var outgoingFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
    }

    private var outgoingForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    private var outgoingTextColor: NSColor {
        colorScheme == .dark ? .black : .white
    }

    private var incomingFill: Color {
        Color.primary.opacity(0.07)
    }
}

/// A selectable wrapping label that can distinguish a click from a text
/// selection drag. Handling both in the same AppKit view avoids competing
/// SwiftUI gestures and event monitors.
private struct SelectableBubbleText: NSViewRepresentable {
    let text: String
    let textColor: NSColor
    let onClick: (Bool) -> Void

    func makeNSView(context: Context) -> ClickSelectableTextField {
        let field = ClickSelectableTextField()
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.usesSingleLineMode = false
        return field
    }

    func updateNSView(_ field: ClickSelectableTextField, context: Context) {
        let font = NSFont.systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5
        // Set both the control attributes and the attributed value. When the
        // field editor takes over for native text selection it reads the
        // control attributes; leaving these at their defaults caused text to
        // change size and color while clicking or selecting.
        field.font = font
        field.textColor = textColor
        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
        )
        field.onClick = onClick
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView field: ClickSelectableTextField,
        context: Context
    ) -> CGSize? {
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            return field.intrinsicContentSize
        }
        field.preferredMaxLayoutWidth = proposedWidth
        guard let cell = field.cell else {
            return nil
        }
        let size = cell.cellSize(
            forBounds: CGRect(
                x: 0,
                y: 0,
                width: proposedWidth,
                height: .greatestFiniteMagnitude
            )
        )
        return CGSize(
            width: min(proposedWidth, ceil(size.width)),
            height: ceil(size.height)
        )
    }
}

private final class ClickSelectableTextField: NSTextField {
    var onClick: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let downPoint = NSEvent.mouseLocation
        let isShiftClick = event.modifierFlags.contains(.shift)

        // NSTextField owns the complete selection interaction and returns
        // after mouse-up. A stationary interaction is a click; movement is a
        // native text-selection drag and must not select the whole message.
        super.mouseDown(with: event)

        let upPoint = NSEvent.mouseLocation
        let movement = hypot(
            upPoint.x - downPoint.x,
            upPoint.y - downPoint.y
        )
        if movement < 4 {
            // A click selects the message, not an arbitrary character or
            // word. Clear the field editor's transient selection and focus
            // before updating the SwiftUI message selection. A real drag
            // keeps its native text highlight and first-responder state.
            currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
            window?.makeFirstResponder(nil)
            onClick?(isShiftClick)
        }
    }
}

struct PeopleErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
