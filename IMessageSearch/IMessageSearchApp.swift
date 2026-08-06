import AppKit
import SwiftUI

@main
struct IMessageSearchApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .defaultSize(width: 1_040, height: 720)
    }
}

private enum LaunchRoute: Equatable {
    case checking
    case onboarding
    case main
}

private struct AppRootView: View {
    private static let currentOnboardingVersion = 1
    private static let onboardingWindowSize = OnboardingView.windowSize

    @AppStorage("onboardingVersion") private var onboardingVersion = 0
    @StateObject private var appModel: AppModel
    @StateObject private var onboardingModel: OnboardingModel
    @State private var route = LaunchRoute.checking
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let engine: SearchEngine

    init() {
        let engine = SearchEngine()
        self.engine = engine
        _appModel = StateObject(wrappedValue: AppModel(engine: engine))
        _onboardingModel = StateObject(wrappedValue: OnboardingModel(engine: engine))
    }

    var body: some View {
        Group {
            switch route {
            case .checking:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking your setup…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .onboarding:
                OnboardingView(
                    model: onboardingModel,
                    onSetupCompleted: {
                        onboardingVersion = Self.currentOnboardingVersion
                    },
                    onComplete: {
                        onboardingVersion = Self.currentOnboardingVersion
                        route = .main
                    }
                )
                .transition(.opacity)
            case .main:
                ContentView(model: appModel)
                    .transition(.opacity)
            }
        }
        // SwiftUI owns all sizing. Setup/checking use one fixed content size;
        // the main app supplies its minimum and ideal size and remains
        // resizable. No NSWindow frame mutation is needed.
        .frame(
            width: route == .main ? nil : Self.onboardingWindowSize.width,
            height: route == .main ? nil : Self.onboardingWindowSize.height
        )
        .frame(
            minWidth: route == .main ? 840 : nil,
            idealWidth: route == .main ? 1_040 : nil,
            minHeight: route == .main ? 560 : nil,
            idealHeight: route == .main ? 720 : nil
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: route
        )
        .task {
            guard route == .checking else {
                return
            }
            let indexIsReady = await engine.isIndexReady()
            route = onboardingVersion >= Self.currentOnboardingVersion && indexIsReady
                ? .main
                : .onboarding
        }
        .onChange(of: onboardingVersion) {
            // Settings resets the stored version; drop back into onboarding.
            if onboardingVersion < Self.currentOnboardingVersion, route == .main {
                appModel.stop()
                onboardingModel.restart()
                route = .onboarding
            }
        }
        .onChange(of: route) { _, newRoute in
            switch newRoute {
            case .checking:
                break
            case .onboarding:
                resizeWindow(to: Self.onboardingWindowSize)
            case .main:
                resizeWindow(to: NSSize(width: 1_040, height: 720))
            }
        }
    }

    private func resizeWindow(to contentSize: NSSize) {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow
                ?? NSApp.windows.first(where: \.isVisible) else {
                return
            }
            window.minSize = contentSize.width == Self.onboardingWindowSize.width
                ? Self.onboardingWindowSize
                : NSSize(width: 840, height: 560)
            window.setContentSize(contentSize)
        }
    }
}

private struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
        } detail: {
            Group {
                switch model.section {
                case .search:
                    SearchView(model: model)
                case .ask:
                    AskView(model: model)
                case .settings:
                    SettingsView(model: model)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let errorMessage = model.errorMessage {
                    ErrorBanner(message: errorMessage, model: model)
                }
            }
            // Attached to the detail content (not the split view) so the
            // field belongs to the detail column's toolbar and sits at its
            // trailing edge.
            .searchable(
                text: $model.query,
                prompt: "Search your messages"
            )
            .toolbar {
                // The system places the search field leading by default in
                // this layout; a flexible spacer before the search item
                // pushes it to the trailing edge.
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                    DefaultToolbarItem(kind: .search)
                }
            }
        }
        .onSubmit(of: .search, model.search)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .modifier(RemoveTitleToolbarItem())
        .toolbar {
            // Sync happens automatically in the background; the toolbar
            // only surfaces progress while an index pass is running.
            if model.isIndexing {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView(value: model.progress)
                        .controlSize(.small)
                        .frame(width: 72)
                        .help("Indexing your messages…")
                }
            }
        }
        .onChange(of: model.query) {
            if model.query.isEmpty {
                model.exitSearch()
            }
        }
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}

private struct RemoveTitleToolbarItem: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedThreads, id: \.title) { group in
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                                .padding(.trailing, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)

                            ForEach(group.threads) { thread in
                                SidebarRow(
                                    title: thread.title,
                                    isSelected: model.section == .ask &&
                                        model.selectedThreadID == thread.id
                                ) {
                                    model.section = .ask
                                    model.selectThread(id: thread.id)
                                }
                                .contextMenu {
                                    Button("Delete Conversation", role: .destructive) {
                                        model.deleteThread(id: thread.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                QualityIndexPane(model: model)
                AccountPane(isSelected: model.section == .settings) {
                    model.toggleSettings()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
        .toolbar {
            ToolbarItem {
                Button {
                    model.createThread()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .help("New conversation")
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isGenerating)
            }
        }
    }

    /// Conversations grouped the way chat apps do it: date buckets with the
    /// newest first, instead of a date caption repeated on every row.
    private var groupedThreads: [(title: String, threads: [ChatThread])] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
        var buckets: [String: [ChatThread]] = [:]
        for thread in model.threads {
            let key: String
            if calendar.isDateInToday(thread.updatedAt) {
                key = "Today"
            } else if calendar.isDateInYesterday(thread.updatedAt) {
                key = "Yesterday"
            } else if thread.updatedAt > weekAgo {
                key = "Previous 7 Days"
            } else {
                key = "Earlier"
            }
            buckets[key, default: []].append(thread)
        }
        return ["Today", "Yesterday", "Previous 7 Days", "Earlier"]
            .compactMap { title in
                buckets[title].map { (title: title, threads: $0) }
            }
    }
}

private struct QualityIndexPane: View {
    @ObservedObject var model: AppModel

    @ViewBuilder
    var body: some View {
        switch model.qualityIndexState {
        case .ready:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking higher-quality search…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .paneInsets()
        case .installing(let fraction, let status):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading quality model")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if let fraction {
                        Text(
                            fraction,
                            format: .percent.precision(.fractionLength(0))
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.primary.opacity(0.55))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .paneInsets()
        case .building(let coverage):
            progressPane(
                coverage: coverage,
                detail: "Building an additional index in the background. Search is ready to use."
            )
        case .paused(let coverage):
            progressPane(
                coverage: coverage,
                detail: "Paused while you search."
            )
        case .needsModel:
            VStack(alignment: .leading, spacing: 6) {
                Text("Higher-quality search")
                    .font(.caption.weight(.semibold))
                Text("Install the Qwen3 4B model to improve results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                paneButton("Install", action: model.installQualityModel)
            }
            .paneInsets()
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("Search improvement paused")
                    .font(.caption.weight(.semibold))
                paneButton("Retry", action: model.retryQualityIndex)
            }
            .paneInsets()
        }
    }

    private func progressPane(
        coverage: EmbeddingCoverage,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Strengthening search")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(coverage.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: coverage.fraction)
                .progressViewStyle(.linear)
                .tint(Color.primary.opacity(0.55))
                .accessibilityLabel("Higher-quality search index")
                .accessibilityValue(
                    Text(coverage.fraction, format: .percent.precision(.fractionLength(0)))
                )
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .paneInsets()
    }

    private func paneButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .accessibilityLabel(title)
            .pointingHandCursor()
    }
}

private extension View {
    func paneInsets() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

/// Bottom-left identity pane: the user's contact card plus which account is
/// answering questions (ChatGPT via Codex, or the on-device model).
/// Clicking it opens Settings.
private struct AccountPane: View {
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject private var contacts = ContactsResolver.shared
    @State private var usesGPT = false
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(contacts.meName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
        // Reusing the row style keeps the pane's highlight pill identical to
        // the conversation rows above it: same radius, insets, and fills.
        .buttonStyle(
            SidebarRowButtonStyle(isSelected: isSelected, isHovered: isHovered)
        )
        .onHover { isHovered = $0 }
        .pointingHandCursor()
        .help("Settings")
        .accessibilityLabel("Settings")
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .task {
            // Resolving codex spawns a login shell once; keep it off main.
            usesGPT = await Task.detached { CodexAgent.locate() != nil }.value
        }
    }

    private var subtitle: String {
        guard usesGPT, let account = CodexAgent.account else {
            return "On-device · Qwen"
        }
        return account.email ?? account.planDisplayName ?? "ChatGPT"
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = contacts.meThumbnail,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                Text(String(contacts.meName.prefix(1)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
        }
    }
}

extension View {
    /// Shows the pointing-hand cursor while hovering, marking the view as clickable.
    func pointingHandCursor() -> some View {
        onHover { isInside in
            if isInside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

struct ContactAvatar: View {
    let handle: String
    var size: CGFloat = 20
    @ObservedObject private var contacts = ContactsResolver.shared

    var body: some View {
        Group {
            if let data = contacts.map.thumbnail(for: handle),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                    if let initial {
                        Text(initial)
                            .font(.system(size: size * 0.48, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initial: String? {
        let name = contacts.map.displayName(for: handle)
        guard name != handle, let first = name.first else {
            return nil
        }
        return String(first).uppercased()
    }
}

private struct SidebarRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(
            SidebarRowButtonStyle(isSelected: isSelected, isHovered: isHovered)
        )
        // Hover state applies instantly: animating it made the pill lag
        // behind the cursor while the sidebar collapses or expands.
        .onHover { isHovered = $0 }
        .pointingHandCursor()
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 1)
    }
}

private struct SidebarRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fill(isPressed: configuration.isPressed))
            )
            .padding(.leading, -10)
    }

    private func fill(isPressed: Bool) -> Color {
        if isSelected {
            return Color.primary.opacity(0.09)
        }
        if isPressed {
            return Color.primary.opacity(0.07)
        }
        if isHovered {
            return Color.primary.opacity(0.045)
        }
        return .clear
    }
}

private struct ErrorBanner: View {
    let message: String
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 12)
            if message.localizedCaseInsensitiveContains("Full Disk Access") {
                Button("Open Settings…") {
                    model.openFullDiskAccessSettings()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SearchView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.isSearching {
                ProgressView("Searching…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.results.isEmpty {
                VStack(spacing: 5) {
                    Text("No results")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("No indexed conversations match that search.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.results) { result in
                    SearchResultRow(result: result) {
                        model.openContext(for: result)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Search")
        .sheet(item: $model.contextResult) { result in
            ConversationContextSheet(model: model, result: result)
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One transcript bubble item; dimmed items render as surrounding context.
struct TranscriptBubbleItem: Identifiable {
    let id: String
    let message: TranscriptMessage
    let isDimmed: Bool
}

/// Shared bubble renderer used by search results and the context sheet.
struct TranscriptBubbleList: View {
    let items: [TranscriptBubbleItem]
    var lineLimit: Int?
    var isLazy = false
    var onReachTop: (() -> Void)?
    var onReachBottom: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var contacts = ContactsResolver.shared

    /// Group chats label who's speaking; one-on-one chats don't need to.
    private var showsSenders: Bool {
        Set(items.map(\.message).filter { !$0.isFromMe }.map(\.sender)).count > 1
    }

    var body: some View {
        if isLazy {
            LazyVStack(spacing: 3) {
                rows
            }
        } else {
            VStack(spacing: 3) {
                rows
            }
        }
    }

    private var rows: some View {
        ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            let isRunStart = index == 0 ||
                items[index - 1].message.sender != item.message.sender
            bubble(
                item,
                showSender: showsSenders && !item.message.isFromMe && isRunStart,
                showAvatar: showsSenders && !item.message.isFromMe && isRunStart
            )
            .id(item.id)
            .onAppear {
                if index == 0 {
                    onReachTop?()
                } else if index == items.count - 1 {
                    onReachBottom?()
                }
            }
        }
    }

    private func bubble(
        _ item: TranscriptBubbleItem,
        showSender: Bool,
        showAvatar: Bool
    ) -> some View {
        let message = item.message
        return HStack(alignment: .top, spacing: 6) {
            if message.isFromMe {
                Spacer(minLength: 60)
            } else if showsSenders {
                if showAvatar {
                    // Aligns the avatar with the bubble below the sender caption.
                    ContactAvatar(handle: message.sender, size: 20)
                        .padding(.top, showSender ? 14 : 0)
                } else {
                    Color.clear
                        .frame(width: 20, height: 1)
                }
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if showSender {
                    Text(contacts.map.displayName(for: message.sender))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 10)
                }
                Text(message.text)
                    .font(.callout)
                    .lineLimit(lineLimit)
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        message.isFromMe ? myBubbleFill : otherBubbleFill,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .textSelection(.enabled)
            }

            if !message.isFromMe {
                Spacer(minLength: 60)
            }
        }
        .opacity(item.isDimmed ? 0.55 : 1)
    }

    // Quoted transcripts stay muted grays on both sides so they read as
    // citations; the user's own prompt bubble (UserBubble) is the only
    // solid inverted bubble in the app.
    private var myBubbleFill: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12)
    }

    private var otherBubbleFill: Color {
        Color.primary.opacity(0.06)
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let onOpen: () -> Void
    @ObservedObject private var contacts = ContactsResolver.shared
    @State private var isHovered = false

    private var messages: [TranscriptMessage] {
        result.transcript.transcriptMessages
    }

    private var chatTitle: String {
        contacts.map.chatTitle(
            rawName: result.chatName,
            participants: messages.filter { !$0.isFromMe }.map(\.sender)
        )
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 7) {
                    if !result.chatName.hasPrefix("chat") {
                        ContactAvatar(handle: result.chatName, size: 18)
                    }
                    Text(chatTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(
                        result.startDate,
                        format: .dateTime.month(.abbreviated).day().hour().minute()
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                }

                TranscriptBubbleList(
                    items: messages.map {
                        TranscriptBubbleItem(
                            id: String($0.id),
                            message: $0,
                            isDimmed: false
                        )
                    },
                    lineLimit: 4
                )
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointingHandCursor()
        .help("Show surrounding conversation")
    }
}

struct ConversationContextSheet: View {
    @ObservedObject var model: AppModel
    let result: SearchResult
    @ObservedObject private var contacts = ContactsResolver.shared
    /// First item before a prepend; scrolling back to it keeps the view stable.
    @State private var pendingTopAnchorID: String?

    private var merged: (items: [TranscriptBubbleItem], firstMatchID: String?) {
        Self.mergeWindows(model.contextWindows, matchedID: result.id)
    }

    private var chatTitle: String {
        contacts.map.chatTitle(
            rawName: result.chatName,
            participants: result.transcript.transcriptMessages
                .filter { !$0.isFromMe }
                .map(\.sender)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !result.chatName.hasPrefix("chat") {
                    ContactAvatar(handle: result.chatName, size: 20)
                }
                Text(chatTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button("Done") {
                    model.contextResult = nil
                }
                .buttonStyle(QuietButtonStyle())
                .pointingHandCursor()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if model.isLoadingContext {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let merged = self.merged
                ScrollViewReader { proxy in
                    ScrollView {
                        TranscriptBubbleList(
                            items: merged.items,
                            isLazy: true,
                            onReachTop: {
                                guard model.canLoadEarlierContext,
                                      pendingTopAnchorID == nil else {
                                    return
                                }
                                pendingTopAnchorID = merged.items.first?.id
                                model.loadEarlierContext()
                            },
                            onReachBottom: {
                                model.loadLaterContext()
                            }
                        )
                        .padding(16)
                    }
                    .onAppear {
                        if let firstMatchID = merged.firstMatchID {
                            proxy.scrollTo(firstMatchID, anchor: .center)
                        }
                    }
                    .onChange(of: model.contextWindows.count) {
                        guard let anchorID = pendingTopAnchorID else {
                            return
                        }
                        pendingTopAnchorID = nil
                        Task { @MainActor in
                            proxy.scrollTo(anchorID, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 600)
    }

    /// Windows overlap by up to two messages; drop repeated leading messages
    /// while flattening so the conversation reads continuously. IDs are stable
    /// across prepends so scroll anchoring keeps working.
    private static func mergeWindows(
        _ windows: [SearchResult],
        matchedID: String
    ) -> (items: [TranscriptBubbleItem], firstMatchID: String?) {
        var items: [TranscriptBubbleItem] = []
        var firstMatchID: String?

        for window in windows {
            let messages = window.transcript.transcriptMessages
            var overlap = 0
            let maximumOverlap = min(3, items.count, messages.count)
            for candidate in stride(from: maximumOverlap, through: 1, by: -1) {
                let tail = items.suffix(candidate).map(\.message)
                let head = messages.prefix(candidate)
                if zip(tail, head).allSatisfy({
                    $0.sender == $1.sender && $0.text == $1.text
                }) {
                    overlap = candidate
                    break
                }
            }

            let isMatch = window.id == matchedID
            for message in messages.dropFirst(overlap) {
                let id = "\(window.id)#\(message.id)"
                if isMatch && firstMatchID == nil {
                    firstMatchID = id
                }
                items.append(
                    TranscriptBubbleItem(
                        id: id,
                        message: message,
                        isDimmed: !isMatch
                    )
                )
            }
        }
        return (items, firstMatchID)
    }
}
