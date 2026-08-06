import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var section = AppSection.ask
    @Published var query = ""
    @Published var answerPrompt = ""
    @Published private(set) var isIndexing = false
    @Published private(set) var isSearching = false
    @Published private(set) var isGenerating = false
    @Published private(set) var progress = 0.0
    @Published private(set) var indexStatus = ""
    @Published private(set) var indexSummary: IndexSummary?
    @Published private(set) var isIndexReady = false
    @Published private(set) var qualityIndexState = QualityIndexState.checking
    @Published private(set) var errorMessage: String?
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var threads: [ChatThread] = []
    @Published private(set) var selectedThreadID: String?
    @Published private(set) var chatMessages: [ChatMessage] = []
    @Published private(set) var pendingAnswer = ""
    @Published private(set) var pendingSources: [AnswerSource] = []
    @Published private(set) var pendingActivities: [AgentActivity] = []
    @Published var contextResult: SearchResult?
    @Published private(set) var contextWindows: [SearchResult] = []
    @Published private(set) var isLoadingContext = false
    @Published private(set) var canLoadEarlierContext = true
    @Published private(set) var canLoadLaterContext = true
    private var isExtendingContext = false

    /// Shared with PeopleModel so thread-scoped search reuses the same
    /// index store and embedding cache.
    let engine: SearchEngine
    private var generationTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var qualityInstallTask: Task<Void, Never>?
    private var hasStarted = false

    init(engine: SearchEngine = SearchEngine()) {
        self.engine = engine
    }

    deinit {
        syncTask?.cancel()
        generationTask?.cancel()
        qualityInstallTask?.cancel()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        Task {
            await loadInitialThread()
        }
        Task {
            await engine.warmUp()
        }
        Task {
            await ContactsResolver.shared.loadIfAuthorized()
            await engine.setContactNames(ContactsResolver.shared.map)
        }

        startAutoSync()
    }

    /// Indexing is fully automatic: a first launch builds the index with
    /// visible progress, and afterwards new messages sync quietly while the
    /// app is open.
    private func startAutoSync() {
        syncTask = Task { [weak self] in
            guard let self else {
                return
            }
            await runMaintenanceLoop()
        }
    }

    private func runMaintenanceLoop() async {
        isIndexReady = await engine.isIndexReady()
        while !Task.isCancelled {
            if !isIndexReady {
                await buildIndex()
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            if isIndexing || isGenerating || isSearching {
                if let coverage = try? await engine.qualityIndexCoverage(),
                   !coverage.isComplete {
                    qualityIndexState = .paused(coverage)
                }
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            do {
                _ = try await engine.syncIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }

            if qualityInstallTask != nil {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            do {
                let coverage = try await engine.qualityIndexCoverage()
                if coverage.isComplete {
                    qualityIndexState = .ready
                    try? await Task.sleep(for: .seconds(30))
                } else {
                    qualityIndexState = .building(coverage)
                    let updated = try await engine.buildNextQualityBatch()
                    qualityIndexState = updated.isComplete
                        ? .ready
                        : .building(updated)
                    await Task.yield()
                }
            } catch is CancellationError {
                return
            } catch let error as OllamaError {
                if case .missingModels(let models) = error,
                   models.contains(EmbeddingModel.quality.rawValue) {
                    qualityIndexState = .needsModel
                } else {
                    errorMessage = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(30))
            } catch {
                qualityIndexState = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func retryQualityIndex() {
        let previousTask = syncTask
        previousTask?.cancel()
        qualityIndexState = .checking
        syncTask = Task { [weak self] in
            await previousTask?.value
            guard let self else {
                return
            }
            await runMaintenanceLoop()
        }
    }

    func installQualityModel() {
        guard qualityInstallTask == nil else {
            return
        }
        qualityIndexState = .installing(
            fraction: nil,
            status: "Starting download…"
        )
        qualityInstallTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await engine.installQualityModel { [weak self] fraction, status in
                    await self?.applyQualityInstallProgress(
                        fraction: fraction,
                        status: status
                    )
                }
                qualityInstallTask = nil
                retryQualityIndex()
            } catch is CancellationError {
                qualityInstallTask = nil
            } catch {
                qualityInstallTask = nil
                qualityIndexState = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        generationTask?.cancel()
        qualityInstallTask?.cancel()
        syncTask = nil
        generationTask = nil
        qualityInstallTask = nil
        hasStarted = false
    }

    private func buildIndex() async {
        guard !isIndexing else {
            return
        }

        isIndexing = true
        errorMessage = nil
        progress = 0
        indexStatus = "Preparing your messages…"

        do {
            indexSummary = try await engine.buildIndex { [weak self] update in
                await self?.apply(update)
            }
            isIndexReady = true
            qualityIndexState = .checking
        } catch {
            isIndexReady = false
            errorMessage = error.localizedDescription
        }
        isIndexing = false
    }

    func search() {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              isIndexReady,
              !isIndexing,
              !isSearching else {
            return
        }

        section = .search
        isSearching = true
        errorMessage = nil
        results = []

        Task {
            do {
                results = try await engine.search(query: trimmedQuery)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    func exitSearch() {
        guard section == .search else {
            return
        }
        section = .ask
        results = []
    }

    func openContext(for source: AnswerSource) {
        openContext(
            for: SearchResult(
                id: source.windowID,
                chatName: source.chatName,
                startDate: source.startDate,
                endDate: source.endDate,
                transcript: source.transcript,
                messageIDs: [],
                score: 0
            )
        )
    }

    func openContext(for result: SearchResult) {
        contextResult = result
        contextWindows = []
        isLoadingContext = true
        canLoadEarlierContext = true
        canLoadLaterContext = true
        Task {
            do {
                contextWindows = try await engine.conversationContext(windowID: result.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingContext = false
        }
    }

    func loadEarlierContext() {
        guard !isExtendingContext,
              canLoadEarlierContext,
              let first = contextWindows.first else {
            return
        }
        isExtendingContext = true
        Task {
            do {
                let windows = try await engine.conversationContext(
                    windowID: first.id,
                    before: 3,
                    after: 0
                )
                let existingIDs = Set(contextWindows.map(\.id))
                let newWindows = windows.filter { !existingIDs.contains($0.id) }
                if newWindows.isEmpty {
                    canLoadEarlierContext = false
                } else {
                    contextWindows.insert(contentsOf: newWindows, at: 0)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isExtendingContext = false
        }
    }

    func loadLaterContext() {
        guard !isExtendingContext,
              canLoadLaterContext,
              let last = contextWindows.last else {
            return
        }
        isExtendingContext = true
        Task {
            do {
                let windows = try await engine.conversationContext(
                    windowID: last.id,
                    before: 0,
                    after: 3
                )
                let existingIDs = Set(contextWindows.map(\.id))
                let newWindows = windows.filter { !existingIDs.contains($0.id) }
                if newWindows.isEmpty {
                    canLoadLaterContext = false
                } else {
                    contextWindows.append(contentsOf: newWindows)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isExtendingContext = false
        }
    }

    func createThread() {
        guard !isGenerating else {
            return
        }

        // Reuse an existing empty conversation instead of stacking new ones.
        if let empty = threads.first(where: { $0.title == "New conversation" }) {
            section = .ask
            if empty.id != selectedThreadID {
                selectThread(id: empty.id)
            }
            return
        }

        Task {
            do {
                let thread = try await engine.createThread()
                threads.insert(thread, at: 0)
                selectedThreadID = thread.id
                section = .ask
                chatMessages = []
                pendingAnswer = ""
                pendingSources = []
                pendingActivities = []
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectThread(id: String) {
        guard id != selectedThreadID, !isGenerating else {
            return
        }
        selectedThreadID = id
        pendingAnswer = ""
        pendingSources = []
        pendingActivities = []
        Task {
            await loadMessages(threadID: id)
        }
    }

    func deleteThread(id: String) {
        guard !isGenerating else {
            return
        }
        Task {
            do {
                try await engine.deleteThread(id: id)
                threads = try await engine.threads()
                guard id == selectedThreadID else {
                    return
                }
                if let next = threads.first {
                    selectedThreadID = next.id
                    await loadMessages(threadID: next.id)
                } else {
                    let thread = try await engine.createThread()
                    threads = [thread]
                    selectedThreadID = thread.id
                    chatMessages = []
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func sendAnswerPrompt() {
        let question = answerPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,
              let threadID = selectedThreadID,
              isIndexReady,
              !isIndexing,
              !isGenerating else {
            return
        }

        let history = chatMessages
        answerPrompt = ""
        errorMessage = nil
        pendingAnswer = ""
        pendingSources = []
        pendingActivities = []
        withAnimation(.easeOut(duration: 0.22)) {
            isGenerating = true
        }

        generationTask = Task {
            do {
                let userMessage = try await engine.saveMessage(
                    threadID: threadID,
                    role: .user,
                    content: question
                )
                withAnimation(.easeOut(duration: 0.22)) {
                    chatMessages.append(userMessage)
                }
                threads = try await engine.threads()

                let generated = try await engine.generateAnswer(
                    question: question,
                    history: history,
                    onSources: { [weak self] sources in
                        await self?.setPendingSources(sources)
                    },
                    onActivity: { [weak self] activity in
                        await self?.appendPendingActivity(activity)
                    },
                    onReset: { [weak self] in
                        await self?.resetPendingAnswer()
                    },
                    onToken: { [weak self] token in
                        await self?.appendPendingAnswer(token)
                    }
                )
                let assistantMessage = try await engine.saveMessage(
                    threadID: threadID,
                    role: .assistant,
                    content: generated.content,
                    sources: generated.sources,
                    activities: generated.activities
                )
                withAnimation(.easeOut(duration: 0.22)) {
                    chatMessages.append(assistantMessage)
                }
                pendingAnswer = ""
                pendingSources = []
                pendingActivities = []
                threads = try await engine.threads()
            } catch is CancellationError {
                pendingAnswer = ""
                pendingSources = []
                pendingActivities = []
            } catch {
                pendingAnswer = ""
                pendingSources = []
                pendingActivities = []
                errorMessage = error.localizedDescription
            }
            withAnimation(.easeOut(duration: 0.22)) {
                isGenerating = false
            }
            generationTask = nil
        }
    }

    func stopGenerating() {
        generationTask?.cancel()
    }

    /// The profile pane behaves like a toggle: it opens Settings, and a
    /// second click dismisses it back to the selected conversation.
    func toggleSettings() {
        section = section == .settings ? .ask : .settings
    }

    func openFullDiskAccessSettings() {
        FullDiskAccessGuide.shared.show()
    }

    func openContactsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func connectContacts() {
        Task {
            await ContactsResolver.shared.requestAccess()
            await engine.setContactNames(ContactsResolver.shared.map)
        }
    }

    private func apply(_ update: IndexProgress) {
        progress = update.fraction
        indexStatus = update.status
    }

    private func applyQualityInstallProgress(
        fraction: Double?,
        status: String
    ) {
        qualityIndexState = .installing(fraction: fraction, status: status)
    }

    private func loadInitialThread() async {
        do {
            threads = try await engine.threads()
            let thread: ChatThread
            if let existing = threads.first {
                thread = existing
            } else {
                thread = try await engine.createThread()
                threads = [thread]
            }
            selectedThreadID = thread.id
            await loadMessages(threadID: thread.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMessages(threadID: String) async {
        do {
            chatMessages = try await engine.messages(threadID: threadID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setPendingSources(_ sources: [AnswerSource]) {
        pendingSources = sources
    }

    private func appendPendingAnswer(_ token: String) {
        pendingAnswer += token
    }

    private func resetPendingAnswer() {
        pendingAnswer = ""
    }

    private func appendPendingActivity(_ activity: AgentActivity) {
        pendingActivities.append(activity)
    }
}
