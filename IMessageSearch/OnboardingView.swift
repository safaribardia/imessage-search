import AppKit
import Contacts
import Foundation
import SwiftUI

@MainActor
final class OnboardingModel: ObservableObject {
    private static let savedStepKey = "onboardingStep"

    enum Step: Int, CaseIterable, Hashable {
        case welcome
        case messages
        case contacts
        case intelligence
        case sync
        case ready
    }

    enum CheckState: Equatable {
        case idle
        case checking
        case ready
        case error(String)
    }

    enum ContactState: Equatable {
        case notDetermined
        case requesting
        case authorized
        case denied
    }

    @Published private(set) var step: Step {
        didSet {
            UserDefaults.standard.set(step.rawValue, forKey: Self.savedStepKey)
        }
    }
    @Published private(set) var messagesState = CheckState.idle
    @Published private(set) var messagesError: MessagesReaderError?
    @Published private(set) var contactState = ContactState.notDetermined
    @Published private(set) var intelligenceState = CheckState.idle
    @Published private(set) var provider: AnswerProvider?
    @Published private(set) var missingModels: [String] = []
    @Published private(set) var syncState = CheckState.idle
    @Published private(set) var syncProgress = 0.0
    @Published private(set) var syncStatus = "Preparing your messages…"
    @Published private(set) var summary: IndexSummary?

    private let engine: SearchEngine
    private var workTask: Task<Void, Never>?

    init(engine: SearchEngine) {
        self.engine = engine
        let savedStep = Step(
            rawValue: UserDefaults.standard.integer(forKey: Self.savedStepKey)
        ) ?? .welcome
        step = savedStep == .sync || savedStep == .ready
            ? .intelligence
            : savedStep
        refreshContactState()
    }

    deinit {
        workTask?.cancel()
    }

    var requiresFullDiskAccess: Bool {
        if case .fullDiskAccessRequired? = messagesError {
            return true
        }
        return false
    }

    var installCommand: String {
        missingModels
            .map { "ollama pull \($0)" }
            .joined(separator: " && ")
    }

    /// Rewinds the flow to the first step after a settings-triggered reset,
    /// discarding any in-flight checks and stale results.
    func restart() {
        workTask?.cancel()
        workTask = nil
        FullDiskAccessGuide.shared.dismiss()
        step = .welcome
        messagesState = .idle
        messagesError = nil
        intelligenceState = .idle
        provider = nil
        missingModels = []
        syncState = .idle
        syncProgress = 0
        syncStatus = "Preparing your messages…"
        summary = nil
        refreshContactState()
    }

    func resumeCurrentStep() {
        switch step {
        case .welcome:
            break
        case .messages:
            checkMessagesAccess()
        case .contacts:
            refreshContactState()
            if contactState == .authorized {
                loadAuthorizedContacts()
            }
        case .intelligence:
            verifyIntelligence()
        case .sync, .ready:
            step = .intelligence
            verifyIntelligence()
        }
    }

    func continueFromWelcome() {
        step = .messages
        checkMessagesAccess()
    }

    func checkMessagesAccess() {
        guard messagesState != .checking else {
            return
        }
        replaceWork {
            self.messagesState = .checking
            self.messagesError = nil
            let error = await Task.detached(priority: .userInitiated) {
                do {
                    try MessagesReader().checkAccess()
                    return nil as MessagesReaderError?
                } catch let readerError as MessagesReaderError {
                    return readerError
                } catch {
                    return MessagesReaderError.databaseError(error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled else {
                return
            }
            if let error {
                self.messagesError = error
                self.messagesState = .error(error.localizedDescription)
            } else {
                FullDiskAccessGuide.shared.dismiss()
                self.messagesState = .ready
            }
        }
    }

    func continueFromMessages() {
        guard messagesState == .ready else {
            return
        }
        FullDiskAccessGuide.shared.dismiss()
        step = .contacts
        refreshContactState()
        if contactState == .authorized {
            loadAuthorizedContacts()
        }
    }

    func requestContacts() {
        guard contactState == .notDetermined else {
            return
        }
        contactState = .requesting
        replaceWork {
            _ = await ContactsResolver.shared.requestAccess()
            self.refreshContactState()
            if self.contactState == .authorized {
                await self.engine.setContactNames(ContactsResolver.shared.map)
            }
        }
    }

    func continueFromContacts() {
        guard contactState != .requesting else {
            return
        }
        step = .intelligence
        verifyIntelligence()
    }

    func verifyIntelligence() {
        guard intelligenceState != .checking else {
            return
        }
        replaceWork {
            self.intelligenceState = .checking
            self.provider = nil
            self.missingModels = []
            do {
                self.provider = try await self.engine.verifyPrerequisites()
                self.intelligenceState = .ready
            } catch let error as OllamaError {
                if case .missingModels(let models) = error {
                    self.missingModels = models
                }
                self.intelligenceState = .error(error.localizedDescription)
            } catch {
                self.intelligenceState = .error(error.localizedDescription)
            }
        }
    }

    func startSync() {
        guard intelligenceState == .ready,
              syncState != .checking else {
            return
        }
        step = .sync
        replaceWork {
            self.syncState = .checking
            self.syncProgress = 0
            self.syncStatus = "Preparing your messages…"
            self.summary = nil
            do {
                self.summary = try await self.engine.buildIndex { [weak self] update in
                    await self?.apply(update)
                }
                self.syncState = .ready
                self.step = .ready
            } catch {
                self.syncState = .error(error.localizedDescription)
            }
        }
    }

    func retrySync() {
        syncState = .idle
        startSync()
    }

    func goBack() {
        workTask?.cancel()
        switch step {
        case .welcome:
            break
        case .messages:
            FullDiskAccessGuide.shared.dismiss()
            messagesState = .idle
            messagesError = nil
            step = .welcome
        case .contacts:
            if contactState == .requesting {
                refreshContactState()
            }
            step = .messages
        case .intelligence:
            if intelligenceState == .checking {
                intelligenceState = .idle
            }
            step = .contacts
        case .sync:
            if syncState != .checking {
                syncState = .idle
                step = .intelligence
            }
        case .ready:
            break
        }
    }

    func appDidBecomeActive() {
        switch step {
        case .messages:
            if messagesState != .checking {
                checkMessagesAccess()
            }
        case .contacts:
            let previousState = contactState
            refreshContactState()
            if contactState == .authorized, previousState != .authorized {
                loadAuthorizedContacts()
            }
        case .welcome, .intelligence, .sync, .ready:
            break
        }
    }

    func openFullDiskAccessSettings() {
        FullDiskAccessGuide.shared.show()
    }

    func openContactsSettings() {
        open(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        )
    }

    func openOllamaDownload() {
        open("https://ollama.com/download")
    }

    func copyInstallCommand() {
        guard !installCommand.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }

    private func replaceWork(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        workTask?.cancel()
        workTask = Task {
            await operation()
        }
    }

    private func refreshContactState() {
        ContactsResolver.shared.refreshAuthorizationStatus()
        switch ContactsResolver.shared.authorizationStatus {
        case .notDetermined:
            contactState = .notDetermined
        case .authorized:
            contactState = .authorized
        case .denied, .restricted:
            contactState = .denied
        @unknown default:
            contactState = .denied
        }
    }

    private func loadAuthorizedContacts() {
        replaceWork {
            await ContactsResolver.shared.loadIfAuthorized()
            await self.engine.setContactNames(ContactsResolver.shared.map)
            self.refreshContactState()
        }
    }

    private func apply(_ update: IndexProgress) {
        syncProgress = update.fraction
        syncStatus = update.status
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct OnboardingView: View {
    /// Single source of truth for the compact onboarding window size.
    static let windowSize = NSSize(width: 720, height: 640)

    @ObservedObject var model: OnboardingModel
    let onSetupCompleted: () -> Void
    let onComplete: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The window is fixed-size and every step fits, so the content fills
        // the height directly; each step's internal Spacer pins its action
        // row to the bottom. No ScrollView — it triggered the system's
        // scroll-edge band at the bottom of the window.
        stepContent
            .id(model.step)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .transition(stepTransition)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .background(OnboardingWindowChrome())
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: model.step
        )
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.appDidBecomeActive()
            }
        }
        .onChange(of: model.syncState) {
            if model.syncState == .ready {
                onSetupCompleted()
            }
        }
        .task {
            model.resumeCurrentStep()
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .identity
            : .opacity
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome:
            WelcomeStep(model: model)
        case .messages:
            MessagesAccessStep(model: model)
        case .contacts:
            ContactsAccessStep(model: model)
        case .intelligence:
            IntelligenceStep(model: model)
        case .sync:
            SyncStep(model: model)
        case .ready:
            ReadyStep(model: model, onComplete: onComplete)
        }
    }
}

/// Hides the titlebar chrome for the window hosting onboarding: no title
/// text, transparent titlebar, no separator line. Applied per-window so the
/// main app keeps the standard toolbar layout (and its trailing search).
private struct OnboardingWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView {
        ChromeView()
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {}

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                return
            }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

private struct OnboardingStepLayout<Content: View, Actions: View>: View {
    let icon: String
    let title: String
    let content: Content
    let actions: Actions

    init(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        ZStack {
            VStack(spacing: 36) {
                StepHero(icon: icon, title: title)
                content
            }
            .frame(maxWidth: 460)

            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Spacer()
                    actions
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingStepLayout(
            icon: "bubble.left.and.text.bubble.right.fill",
            title: "Better search for your iMessage"
        ) {
            EmptyView()
        } actions: {
            Button("Get Started") {
                model.continueFromWelcome()
            }
            .buttonStyle(.onboardingPrimary)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Get Started")
        }
    }
}

private struct MessagesAccessStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingStepLayout(icon: "message.fill", title: "Enable Full Disk Access") {
            content
        } actions: {
            BackButton(action: model.goBack)
            actions
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.messagesState {
        case .idle, .checking:
            CheckingPanel(
                title: "Checking Messages access…",
                detail: "This only verifies that the database can be opened read-only."
            )
        case .ready:
            StatusPanel(
                icon: "checkmark.circle.fill",
                title: "Messages is connected",
                detail: "You can remove access anytime.",
                tint: .green
            )
        case .error(let message):
            if model.requiresFullDiskAccess {
                VStack(alignment: .leading, spacing: 28) {
                    PermissionNotice()
                    VStack(alignment: .leading, spacing: 18) {
                        InstructionRow(number: 1, text: "Open System Settings.")
                        InstructionRow(number: 2, text: "Drag iMessage Search into Full Disk Access, then reopen the app.")
                    }
                }
            } else {
                StatusPanel(
                    icon: "exclamationmark.triangle.fill",
                    title: "Messages is not available",
                    detail: message,
                    tint: .orange
                )
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.messagesState {
        case .ready:
            Button("Continue") {
                model.continueFromMessages()
            }
            .buttonStyle(.onboardingPrimary)
            .keyboardShortcut(.defaultAction)
        case .error:
            if model.requiresFullDiskAccess {
                Button("Open System Settings") {
                    model.openFullDiskAccessSettings()
                }
                .buttonStyle(.onboardingPrimary)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Check Again") {
                    model.checkMessagesAccess()
                }
                .buttonStyle(.onboardingPrimary)
                .keyboardShortcut(.defaultAction)
            }
        case .idle, .checking:
            Button("Checking…") {}
                .buttonStyle(.onboardingPrimary)
                .disabled(true)
        }
    }
}

private struct ContactsAccessStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingStepLayout(
            icon: "person.crop.circle.badge.checkmark",
            title: "Recognize people"
        ) {
            content
        } actions: {
            BackButton(action: model.goBack)
            actions
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.contactState {
        case .notDetermined:
            StatusPanel(
                icon: "person.text.rectangle",
                title: "Show contact names in the app",
                detail: "Contact details are used only to label handles in the app.",
                tint: .primary
            )
        case .requesting:
            CheckingPanel(
                title: "Requesting Contacts access…",
                detail: "Choose Allow in the macOS permission dialog."
            )
        case .authorized:
            StatusPanel(
                icon: "checkmark.circle.fill",
                title: "Contacts is connected",
                detail: "Names and photos will appear throughout search results and answers.",
                tint: .green
            )
        case .denied:
            StatusPanel(
                icon: "person.crop.circle.badge.xmark",
                title: "Continuing without Contacts",
                detail: "Search still works normally. Raw phone numbers or email addresses will be shown instead.",
                tint: .orange
            )
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.contactState {
        case .notDetermined:
            Button("Not Now") {
                model.continueFromContacts()
            }
            .buttonStyle(.onboardingSecondary)
            Button("Use Contacts") {
                model.requestContacts()
            }
            .buttonStyle(.onboardingPrimary)
            .keyboardShortcut(.defaultAction)
        case .requesting:
            Button("Waiting for Permission…") {}
                .buttonStyle(.onboardingPrimary)
                .disabled(true)
        case .authorized:
            Button("Continue") {
                model.continueFromContacts()
            }
            .buttonStyle(.onboardingPrimary)
            .keyboardShortcut(.defaultAction)
        case .denied:
            Button("Open Contacts Settings") {
                model.openContactsSettings()
            }
            .buttonStyle(.onboardingSecondary)
            Button("Continue") {
                model.continueFromContacts()
            }
            .buttonStyle(.onboardingPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct IntelligenceStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingStepLayout(icon: "sparkles", title: "Prepare intelligence") {
            content
        } actions: {
            BackButton(action: model.goBack)
            actions
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.intelligenceState {
        case .idle, .checking:
            CheckingPanel(
                title: "Checking ChatGPT and Ollama…",
                detail: "Verifying the embedding model and the best available answer provider."
            )
        case .ready:
            if let provider = model.provider {
                ProviderPanel(provider: provider)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 12) {
                StatusPanel(
                    icon: "exclamationmark.triangle.fill",
                    title: "Ollama needs attention",
                    detail: message,
                    tint: .orange
                )
                if !model.installCommand.isEmpty {
                    HStack(spacing: 10) {
                        Text(model.installCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button {
                            model.copyInstallCommand()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.intelligenceState {
        case .ready:
            Button("Start indexing my messages") {
                model.startSync()
            }
            .buttonStyle(.onboardingPrimary)
            .keyboardShortcut(.defaultAction)
        case .error:
            Button("Get Ollama") {
                model.openOllamaDownload()
            }
            .buttonStyle(.onboardingSecondary)
            Button("Check Again") {
                model.verifyIntelligence()
            }
            .buttonStyle(.onboardingPrimary)
            .keyboardShortcut(.defaultAction)
        case .idle, .checking:
            Button("Checking…") {}
                .buttonStyle(.onboardingPrimary)
                .disabled(true)
        }
    }
}

private struct SyncStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingStepLayout(
            icon: "arrow.triangle.2.circlepath",
            title: "Building your search index"
        ) {
            switch model.syncState {
            case .idle, .checking:
                VStack(spacing: 12) {
                    ProgressView(value: model.syncProgress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(model.syncStatus)
                        .accessibilityValue(
                            Text(model.syncProgress, format: .percent.precision(.fractionLength(0)))
                        )
                    HStack {
                        Text(model.syncStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(model.syncProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            case .error(let message):
                StatusPanel(
                    icon: "exclamationmark.arrow.triangle.2.circlepath",
                    title: "Indexing stopped",
                    detail: message,
                    tint: .orange
                )
            case .ready:
                StatusPanel(
                    icon: "checkmark.circle.fill",
                    title: "Index is ready",
                    detail: "Your message history is ready to search.",
                    tint: .green
                )
            }
        } actions: {
            if case .error = model.syncState {
                BackButton(action: model.goBack)
                Button("Retry") {
                    model.retrySync()
                }
                .buttonStyle(.onboardingPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ReadyStep: View {
    @ObservedObject var model: OnboardingModel
    let onComplete: () -> Void

    var body: some View {
        OnboardingStepLayout(icon: "checkmark.seal.fill", title: "Ready to go") {
            if let summary = model.summary {
                HStack(spacing: 14) {
                    SummaryMetric(
                        value: summary.messageCount.formatted(),
                        label: "messages read",
                        icon: "message.fill"
                    )
                    SummaryMetric(
                        value: summary.windowCount.formatted(),
                        label: "search passages",
                        icon: "rectangle.stack.fill"
                    )
                }
            }
        } actions: {
            Button("Open iMessage Search") {
                onComplete()
            }
            .buttonStyle(.onboardingPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct StepHero: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: 58, height: 58)
                .background(
                    Color.primary.opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionNotice: View {
    var body: some View {
        // Single wrapped paragraph: center the icon on the block.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(
                "We need Full Disk Access to access your messages. " +
                "We store your messages in a local database, not on our servers."
            )
            .font(.callout.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(
            Color.orange,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct StatusPanel: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        // Icon and title share a row so the icon is centered on the title
        // line; the detail indents to the title's leading edge.
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                // SF symbol frames carry baseline padding that floats the
                // glyph slightly above frame center; the 1pt nudge makes it
                // optically level with the title.
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 24)
                    .offset(y: 1)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(.semibold))
            }
            Text(detail)
                .font(.callout)
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(foreground)
        .padding(16)
        .background(background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var foreground: Color {
        tint == .primary ? Color(nsColor: .windowBackgroundColor) : .white
    }

    private var background: Color {
        tint == .primary ? Color.primary.opacity(0.9) : tint
    }
}

private struct CheckingPanel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 20)
                Text(title)
                    .font(.body.weight(.semibold))
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ProviderPanel: View {
    let provider: AnswerProvider
    var compact = false

    var body: some View {
        StatusPanel(
            icon: icon,
            title: title,
            detail: detail,
            tint: tint
        )
        .frame(maxWidth: compact ? 460 : nil)
    }

    private var icon: String {
        switch provider {
        case .chatGPT:
            "cloud.fill"
        case .ollama:
            "desktopcomputer"
        }
    }

    private var title: String {
        switch provider {
        case .chatGPT(let accountLabel):
            "Answers via \(accountLabel)"
        case .ollama(let modelName):
            "On-device answers via \(modelName)"
        }
    }

    private var detail: String {
        switch provider {
        case .chatGPT:
            "Relevant excerpts may be sent to Codex to answer your question. It connects to your ChatGPT account to use limits directly."
        case .ollama:
            "Search and answer generation stay on this Mac through Ollama."
        }
    }

    private var tint: Color {
        switch provider {
        case .chatGPT:
            .primary
        case .ollama:
            .green
        }
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.07), in: Circle())
            Text(text)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}

private struct SummaryMetric: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button("Back", action: action)
            .buttonStyle(.onboardingSecondary)
            .keyboardShortcut(.cancelAction)
    }
}

/// Monochrome primary action matching the app's send button: white on dark
/// mode, black on light mode.
private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.92)
                            : Color.black.opacity(0.85)
                    )
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Quiet secondary action: subtle neutral fill, primary text.
private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.06))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == OnboardingPrimaryButtonStyle {
    static var onboardingPrimary: OnboardingPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == OnboardingSecondaryButtonStyle {
    static var onboardingSecondary: OnboardingSecondaryButtonStyle { .init() }
}
