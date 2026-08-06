import SwiftUI

extension Font {
    /// One shared style for all agent thinking/status text, so traces and
    /// loaders read as a single quiet voice instead of mixed sizes.
    static let statusText = Font.system(size: 12)
}

struct AskView: View {
    @ObservedObject var model: AppModel
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var threadTitle: String {
        model.threads.first { $0.id == model.selectedThreadID }?.title ?? "Ask"
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            inputBar
        }
        .navigationTitle(threadTitle)
        .sheet(item: $model.contextResult) { result in
            ConversationContextSheet(model: model, result: result)
        }
        .onAppear {
            isInputFocused = true
        }
        .onChange(of: model.selectedThreadID) {
            isInputFocused = true
        }
        .onChange(of: model.isGenerating) {
            if !model.isGenerating {
                isInputFocused = true
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.chatMessages.isEmpty && !model.isGenerating {
            VStack(spacing: 5) {
                Text("Ask your messages")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Answers are researched from your conversations and cited.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            messageList
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 24) {
                    ForEach(model.chatMessages) { message in
                        MessageView(model: model, message: message)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }

                    if model.isGenerating {
                        PendingAnswerView(
                            model: model,
                            content: model.pendingAnswer,
                            sources: model.pendingSources,
                            activities: model.pendingActivities
                        )
                        .transition(.opacity)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                // Full width with a comfortable gutter, rather than a column
                // floating in the center of the pane.
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .onChange(of: model.chatMessages.count) {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.pendingAnswer.count) {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: model.pendingActivities.count) {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 2) {
            TextField(
                "Ask about your messages…",
                text: $model.answerPrompt,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isInputFocused)
            .lineLimit(1...6)
            .onSubmit(model.sendAnswerPrompt)
            .disabled(model.isGenerating)
            .padding(.leading, 17)
            .padding(.vertical, 12)

            // 42pt square matches the single-line field height (18pt line + 2 × 12pt
            // padding), so the 28pt glyph is optically centered on every side.
            Group {
                if model.isGenerating {
                    Button(action: model.stopGenerating) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(bubbleForeground, bubbleFill)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(PressableIconButtonStyle())
                    .pointingHandCursor()
                    .help("Stop generating")
                } else {
                    Button(action: model.sendAnswerPrompt) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(
                                canSend ? bubbleForeground : Color.secondary.opacity(0.5),
                                canSend ? bubbleFill : Color.secondary.opacity(0.15)
                            )
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(PressableIconButtonStyle())
                    .disabled(!canSend)
                    .pointingHandCursor()
                    .help("Send")
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    /// The send control shares the user bubble's colors: it is the message
    /// you are about to send.
    private var bubbleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
    }

    private var bubbleForeground: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private var canSend: Bool {
        !model.answerPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty &&
        model.selectedThreadID != nil &&
        model.isIndexReady &&
        !model.isIndexing
    }
}

private struct PressableIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// The user's own prompt: a solid inverted bubble, so it reads as "what I
/// asked" and never blends with the muted quoted iMessage transcripts.
private struct UserBubble: View {
    let content: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(content)
                .font(.system(size: 14))
                .lineSpacing(1.5)
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 7.5)
                .background(
                    colorScheme == .dark
                        ? Color.white.opacity(0.92)
                        : Color.black.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }
}

private struct MessageView: View {
    @ObservedObject var model: AppModel
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            UserBubble(content: message.content)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if !message.activities.isEmpty {
                    ActivityTrace(activities: message.activities, isLive: false)
                }

                AnswerBody(
                    model: model,
                    content: message.content,
                    sources: message.sources
                )
            }
        }
    }
}

private struct PendingAnswerView: View {
    @ObservedObject var model: AppModel
    let content: String
    let sources: [AnswerSource]
    let activities: [AgentActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if activities.isEmpty && content.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading your messages…")
                        .font(.statusText)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !activities.isEmpty {
                ActivityTrace(
                    activities: activities,
                    isLive: true,
                    isWorking: content.isEmpty
                )
            }

            if !content.isEmpty {
                AnswerBody(model: model, content: content, sources: sources)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: activities.count)
    }
}

/// Answer text broken into paragraphs, with each cited source rendered as an
/// evidence card directly after the paragraph that first cites it.
private struct AnswerBody: View {
    @ObservedObject var model: AppModel
    let content: String
    let sources: [AnswerSource]

    private struct AnswerSegment: Identifiable {
        let id: Int
        let text: String
        let sources: [AnswerSource]
    }

    private var sourcesByLabel: [String: AnswerSource] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.label, $0) })
    }

    private var segments: [AnswerSegment] {
        let sourcesByLabel = self.sourcesByLabel
        var seenLabels = Set<String>()
        var segments: [AnswerSegment] = []
        for (index, paragraph) in content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated() {
            let text = String(paragraph)
            var cited: [AnswerSource] = []
            for match in text.matches(of: /\[(S\d+)\]/) {
                let label = String(match.1)
                if !seenLabels.contains(label),
                   let source = sourcesByLabel[label] {
                    seenLabels.insert(label)
                    cited.append(source)
                }
            }
            let cleaned = cleanedText(text)
            if !cleaned.isEmpty || !cited.isEmpty {
                segments.append(
                    AnswerSegment(id: index, text: cleaned, sources: cited)
                )
            }
        }
        return segments
    }

    var body: some View {
        let segments = self.segments
        VStack(alignment: .leading, spacing: 18) {
            ForEach(segments) { segment in
                if !segment.text.isEmpty {
                    Text(markdown(segment.text))
                        .textSelection(.enabled)
                        .lineSpacing(2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(segment.sources) { source in
                    EvidenceCard(source: source) {
                        model.openContext(for: source)
                    }
                }
            }

            let remaining = remainingSources(segments: segments)
            if !remaining.isEmpty {
                SourceList(
                    sources: remaining,
                    titleSuffix: remaining.count == sources.count ? "" : " more"
                )
            }
        }
    }

    private func remainingSources(segments: [AnswerSegment]) -> [AnswerSource] {
        let citedLabels = Set(segments.flatMap(\.sources).map(\.label))
        return sources.filter { !citedLabels.contains($0.label) }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Citation markers are shown as evidence cards, not inline text; strip
    /// them without disturbing surrounding spacing or punctuation.
    private func cleanedText(_ text: String) -> String {
        text
            .replacing(/[ \t]*\[S\d+\](?=[.,!?;:])/, with: "")
            .replacing(/[ \t]*\[S\d+\]/, with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A cited message excerpt rendered as bubbles; clicking opens the
/// surrounding conversation.
private struct EvidenceCard: View {
    let source: AnswerSource
    let onOpen: () -> Void
    @ObservedObject private var contacts = ContactsResolver.shared
    @State private var isHovered = false

    private var messages: [TranscriptMessage] {
        Array(source.transcript.transcriptMessages.prefix(3))
    }

    private var chatTitle: String {
        contacts.map.chatTitle(
            rawName: source.chatName,
            participants: source.transcript.transcriptMessages
                .filter { !$0.isFromMe }
                .map(\.sender)
        )
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if !source.chatName.hasPrefix("chat") {
                        ContactAvatar(handle: source.chatName, size: 16)
                    }
                    Text(chatTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(source.startDate, format: .dateTime.month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 1 : 0.45)
                    Spacer(minLength: 0)
                }

                TranscriptBubbleList(
                    items: messages.map {
                        TranscriptBubbleItem(
                            id: String($0.id),
                            message: $0,
                            isDimmed: false
                        )
                    },
                    lineLimit: 2
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.045) : Color.clear)
            )
            // Cancel the inner inset so the card content stays aligned with
            // the answer text while the hover box gets breathing room.
            .padding(.horizontal, -10)
            .padding(.vertical, -2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointingHandCursor()
        .help("Show surrounding conversation")
    }
}

private struct ActivityTrace: View {
    let activities: [AgentActivity]
    let isLive: Bool
    let isWorking: Bool
    @State private var isExpanded: Bool

    init(activities: [AgentActivity], isLive: Bool, isWorking: Bool = false) {
        self.activities = activities
        self.isLive = isLive
        self.isWorking = isWorking
        _isExpanded = State(initialValue: isLive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(summary)
                        .font(.statusText)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(activities) { activity in
                        ActivityRow(activity: activity)
                            .transition(.opacity)
                    }

                    if isWorking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 14)
                            Text("Still reading…")
                                .font(.statusText)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.leading, 13)
            }
        }
    }

    private var summary: String {
        isLive && isWorking ? "Reading your messages…" : "How I found this"
    }
}

private struct ActivityRow: View {
    let activity: AgentActivity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(activity.title)
                .font(.statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !activity.detail.isEmpty {
                Text(activity.detail)
                    .font(.statusText)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let resultCount = activity.resultCount {
                Text("\(resultCount)")
                    .font(.statusText)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private var icon: String {
        switch activity.toolName {
        case "search_messages":
            "magnifyingglass"
        case "grep_messages":
            "text.magnifyingglass"
        case "get_conversation_context":
            "text.bubble"
        case "finish_research":
            "checkmark.circle"
        default:
            "wrench.and.screwdriver"
        }
    }
}

private struct SourceList: View {
    let sources: [AnswerSource]
    var titleSuffix = ""
    @State private var isExpanded = false

    private var title: String {
        let noun = sources.count == 1 ? "source" : "sources"
        return "\(sources.count)\(titleSuffix) \(noun)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sources) { source in
                        SourceRow(source: source)
                    }
                }
                .padding(.leading, 13)
            }
        }
    }
}

private struct SourceRow: View {
    let source: AnswerSource
    @State private var isExpanded = false
    @ObservedObject private var contacts = ContactsResolver.shared

    private var chatTitle: String {
        contacts.map.chatTitle(
            rawName: source.chatName,
            participants: source.transcript.transcriptMessages
                .filter { !$0.isFromMe }
                .map(\.sender)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    if !source.chatName.hasPrefix("chat") {
                        ContactAvatar(handle: source.chatName, size: 16)
                    }
                    Text(chatTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(source.startDate, format: .dateTime.month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isExpanded {
                Text(source.transcript.transcriptResolved(using: contacts.map))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.leading, 23)
                    .padding(.bottom, 8)
            }
        }
    }
}
