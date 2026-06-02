import LiteRTLM
import Foundation
import OSLog

/// Manages AI Chat mode state.
@Observable
final class AIChatViewModel {
    private let logger = Logger(
        subsystem: "com.guardai.app",
        category: "AIChatViewModel"
    )

    // MARK: - Published State

    var messages: [ChatMessage] = []
    var currentInput: String = ""
    var isGenerating: Bool = false
    /// True after the user taps stop and before LiteRT-LM finishes unwinding the stream.
    var isStopping: Bool = false
    /// Active streamed response text. Kept separate from `messages` so token
    /// updates do not repeatedly diff and relayout the transcript.
    var streamingContent: String?
    /// Briefly keeps Send disabled after a turn completes so SwiftUI can finish
    /// flushing the completed layout before the next prompt mutates the tree.
    var isSendSettling: Bool = false
    var error: String?
    /// Warning shown when context window is getting full.
    var contextWarning: String?
    /// Approximate percentage of the active KV cache used by this conversation.
    var contextUsagePercent: Int = 0

    // MARK: - Dependencies

    private let sessionCoordinator: SessionCoordinator
    private let configLoader: InferenceConfigLoaderProtocol
    private let historyStore: HistoryStoreProtocol
    private let conversationStore: ConversationStoreProtocol
    private let appState: AppState
    private let userSettings: UserSettings
    private let kvCacheSize: Int
    /// Approximate token count used in the current conversation.
    private var estimatedTokenCount: Int = 0
    private var historyConversationID: UUID
    /// Reference to the active inference task for cancellation propagation.
    private var activeTask: Task<Void, Never>?
    /// Stop state for the active turn. This lets the stream unwind normally
    /// after `conversation.cancel()` without cancelling the Swift task.
    private var activeStopSignal: StopSignal?
    private static let minimumFirstTokenTimeout: TimeInterval = 45
    private static let maximumFirstTokenTimeout: TimeInterval = 180
    private static let minimumTokenStallTimeout: TimeInterval = 30
    private static let maximumTokenStallTimeout: TimeInterval = 90
    private static let streamUIUpdateInterval: TimeInterval = 0.08

    init(
        sessionCoordinator: SessionCoordinator,
        configLoader: InferenceConfigLoaderProtocol,
        historyStore: HistoryStoreProtocol,
        conversationStore: ConversationStoreProtocol,
        appState: AppState,
        userSettings: UserSettings,
        kvCacheSize: Int
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.configLoader = configLoader
        self.historyStore = historyStore
        self.conversationStore = conversationStore
        self.appState = appState
        self.userSettings = userSettings
        self.kvCacheSize = kvCacheSize

        let restoredMessages = conversationStore.loadMessages(for: .aiChat)
        self.messages = restoredMessages
        self.estimatedTokenCount = Self.estimatedTokenCount(for: restoredMessages)
        self.historyConversationID = conversationStore.loadHistoryEntryID(for: .aiChat) ?? UUID()
        conversationStore.saveHistoryEntryID(historyConversationID, for: .aiChat)
        updateContextUsage()
    }

    // MARK: - Actions

    @MainActor
    func sendMessage() async {
        guard !isGenerating, !isStopping, !isSendSettling else { return }

        let trimmedInput = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            error = "Please enter a message."
            return
        }

        // LiteRT conversation reuse is intermittently hanging on device after a
        // successful first turn. Keep conversational context by replaying a
        // bounded transcript instead of keeping the native session alive.
        error = nil
        isGenerating = true
        isStopping = false
        streamingContent = ""
        isSendSettling = false
        appState.beginChatInputLock()
        let stateSnapshot = SendStateSnapshot(
            messagesBeforeSend: messages,
            trimmedInput: trimmedInput,
            config: effectiveConfig(),
            historyConversationID: historyConversationID,
            kvCacheSize: kvCacheSize,
            assistantMessageID: UUID()
        )
        let stopSignal = StopSignal()
        activeStopSignal = stopSignal
        messages.append(ChatMessage(role: .user, content: trimmedInput))
        scheduleConversationPersistence(messages: messages, historyConversationID: historyConversationID)
        currentInput = ""
        defer { appState.endChatInputLock() }

        activeTask?.cancel()
        activeTask = Task(priority: .userInitiated) { [sessionCoordinator, historyStore, logger] in
            await Self.runSend(
                state: stateSnapshot,
                sessionCoordinator: sessionCoordinator,
                historyStore: historyStore,
                logger: logger,
                stopSignal: stopSignal,
                update: { [weak self] update in
                    guard let self else { return }
                    Task { @MainActor in
                        self.apply(update)
                    }
                }
            )
        }
    }

    @MainActor
    func stopGenerating() {
        guard isGenerating, !isStopping else { return }
        isStopping = true
        // Call cancel() on the SDK conversation to stop the C++ inference.
        // This is REQUIRED: the SDK's sendMessageStream AsyncThrowingStream has no
        // onTermination handler, so cancelling the Swift Task alone does NOT stop
        // the C++ work. cancel() triggers the stream's isFinal callback, which
        // releases the internal StreamContext that retains the Conversation —
        // allowing it to deinit and call litert_lm_conversation_delete (clearing
        // the engine session). We do NOT release the conversation here; runSend is
        // the sole owner and releases it after the stream loop ends.
        let stopSignal = activeStopSignal
        Task {
            await stopSignal?.requestStop()
            try? await sessionCoordinator.cancelIfActive()
        }
    }

    @MainActor
    func newConversation() {
        activeTask?.cancel()
        activeTask = nil
        let stopSignal = activeStopSignal
        activeStopSignal = nil
        Task { await stopSignal?.requestStop() }
        messages = []
        currentInput = ""
        streamingContent = nil
        error = nil
        isGenerating = false
        isStopping = false
        isSendSettling = false
        contextWarning = nil
        contextUsagePercent = 0
        estimatedTokenCount = 0
        historyConversationID = UUID()
        conversationStore.clearMessages(for: .aiChat)
        conversationStore.clearHistoryEntryID(for: .aiChat)
        Task { await sessionCoordinator.releaseConversation(for: .aiChat) }
    }

    @MainActor
    func restoreConversation(id: UUID, messages restoredMessages: [ChatMessage]) {
        activeTask?.cancel()
        activeTask = nil
        let stopSignal = activeStopSignal
        activeStopSignal = nil
        Task { await stopSignal?.requestStop() }

        messages = restoredMessages
        currentInput = ""
        streamingContent = nil
        error = nil
        isGenerating = false
        isStopping = false
        isSendSettling = false
        estimatedTokenCount = Self.estimatedTokenCount(for: restoredMessages)
        historyConversationID = id
        updateContextUsage()
        conversationStore.saveMessages(restoredMessages, for: .aiChat)
        conversationStore.saveHistoryEntryID(id, for: .aiChat)
        Task { await sessionCoordinator.releaseConversation(for: .aiChat) }
    }

    // MARK: - Private

    private func effectiveConfig() -> InferenceConfig {
        let config = configLoader.load(for: .aiChat)
        return InferenceConfig(
            temperature: userSettings.effectiveTemperature(configDefault: config.temperature),
            topK: userSettings.effectiveTopK(configDefault: config.topK),
            topP: userSettings.effectiveTopP(configDefault: config.topP),
            systemPrompt: userSettings.effectiveSystemPrompt(
                for: .aiChat,
                configDefault: config.systemPrompt
            )
        )
    }

    private static func configSignature(for config: InferenceConfig) -> String {
        "\(config.temperature)|\(config.topK)|\(config.topP)|\(config.systemPrompt)"
    }

    private func updateContextUsage() {
        let usagePercent = Double(estimatedTokenCount) / Double(kvCacheSize)
        contextUsagePercent = min(100, max(0, Int((usagePercent * 100).rounded())))

        if usagePercent >= 0.90 {
            contextWarning = "Context is nearly full. Start fresh before continuing."
        } else if usagePercent >= 0.70 {
            contextWarning = "Context is getting long. Start fresh soon for better responses."
        } else {
            contextWarning = nil
        }
    }

    private func scheduleConversationPersistence(messages: [ChatMessage], historyConversationID: UUID) {
        let snapshot = messages
        let store = conversationStore
        Task.detached(priority: .utility) {
            store.saveMessages(snapshot, for: .aiChat)
            store.saveHistoryEntryID(historyConversationID, for: .aiChat)
        }
    }

    private enum SendUpdate: Sendable {
        case setGenerating(Bool)
        case setStopping(Bool)
        case setError(String?)
        case appendMessage(ChatMessage)
        case setStreamingContent(String?)
        case completed(message: ChatMessage, context: ContextState, messages: [ChatMessage], historyConversationID: UUID)
        case cancelled(partialContent: String?, notice: ChatMessage, context: ContextState, messages: [ChatMessage], historyConversationID: UUID)
        case failed(error: String, messages: [ChatMessage], historyConversationID: UUID)
        case saveActiveConversation(messages: [ChatMessage], historyConversationID: UUID)
        case setContextEstimate(estimatedTokenCount: Int, usagePercent: Int, warning: String?)
    }

    private struct ContextState: Sendable {
        let estimatedTokenCount: Int
        let usagePercent: Int
        let warning: String?
    }

    @MainActor
    private func apply(_ update: SendUpdate) {
        switch update {
        case .setGenerating(let value):
            isGenerating = value
            if !value {
                streamingContent = nil
                activeStopSignal = nil
                beginSendSettling()
            }
        case .setStopping(let value):
            isStopping = value
        case .setError(let message):
            error = message
        case .appendMessage(let message):
            messages.append(message)
        case .setStreamingContent(let content):
            streamingContent = content
        case .completed(let message, let context, let messages, let historyConversationID):
            streamingContent = nil
            self.messages.append(message)
            estimatedTokenCount = context.estimatedTokenCount
            contextUsagePercent = context.usagePercent
            contextWarning = context.warning
            scheduleConversationPersistence(messages: messages, historyConversationID: historyConversationID)
            isGenerating = false
            isStopping = false
            activeStopSignal = nil
            beginSendSettling()
        case .cancelled(let partialContent, let notice, let context, let messages, let historyConversationID):
            streamingContent = nil
            if let partialContent, !partialContent.isEmpty {
                self.messages.append(ChatMessage(role: .model, content: partialContent))
            }
            self.messages.append(notice)
            estimatedTokenCount = context.estimatedTokenCount
            contextUsagePercent = context.usagePercent
            contextWarning = context.warning
            scheduleConversationPersistence(messages: messages, historyConversationID: historyConversationID)
            isGenerating = false
            isStopping = false
            activeStopSignal = nil
            beginSendSettling()
        case .failed(let message, let messages, let historyConversationID):
            streamingContent = nil
            error = message
            scheduleConversationPersistence(messages: messages, historyConversationID: historyConversationID)
            isGenerating = false
            isStopping = false
            activeStopSignal = nil
            beginSendSettling()
        case .saveActiveConversation(let messages, let historyConversationID):
            scheduleConversationPersistence(messages: messages, historyConversationID: historyConversationID)
        case .setContextEstimate(let estimatedTokenCount, let usagePercent, let warning):
            self.estimatedTokenCount = estimatedTokenCount
            self.contextUsagePercent = usagePercent
            self.contextWarning = warning
        }
    }

    @MainActor
    private func beginSendSettling() {
        isSendSettling = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !self.isGenerating, !self.isStopping else { return }
            self.isSendSettling = false
        }
    }

    private struct SendStateSnapshot: Sendable {
        let messagesBeforeSend: [ChatMessage]
        let trimmedInput: String
        let config: InferenceConfig
        let historyConversationID: UUID
        let kvCacheSize: Int
        let assistantMessageID: UUID
    }

    private static func runSend(
        state: SendStateSnapshot,
        sessionCoordinator: SessionCoordinator,
        historyStore: HistoryStoreProtocol,
        logger: Logger,
        stopSignal: StopSignal,
        update: @escaping (SendUpdate) -> Void
    ) async {
        let configSignature = Self.configSignature(for: state.config)
        var latestStreamedOutput = ""
        let shouldReplayTranscript = !state.messagesBeforeSend.isEmpty
        let conversationConfig: ConversationConfig
        do {
            conversationConfig = try Self.buildConversationConfig(config: state.config)
        } catch {
            await MainActor.run {
                update(.setError(error.localizedDescription))
                update(.setGenerating(false))
                update(.setStopping(false))
            }
            return
        }
        logger.info("AIChat acquireConversation starting; prompt chars \(state.trimmedInput.count), replay=\(shouldReplayTranscript, privacy: .public)")
        let watchdog = TurnWatchdog()
        let contextPressure = Self.contextPressure(
            messages: state.messagesBeforeSend,
            additionalText: state.trimmedInput,
            kvCacheSize: state.kvCacheSize
        )
        let firstTokenTimeout = Self.firstTokenTimeout(for: contextPressure)
        let tokenStallTimeout = Self.tokenStallTimeout(for: contextPressure)
        let watchdogTask = Task.detached(priority: .high) { [sessionCoordinator, logger] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }

                guard await watchdog.triggerTimeoutIfIdle(
                    firstTokenTimeout: firstTokenTimeout,
                    tokenStallTimeout: tokenStallTimeout
                ) else { continue }
                logger.error("AIChat turn idle timed out; cancelling active session")
                // Attempt cancel with a 2-second timeout — if the SDK is blocking,
                // cancelIfActive() itself may hang. Force-release regardless.
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        try? await sessionCoordinator.cancelIfActive()
                        return true
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(2))
                        return false
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
                await sessionCoordinator.endInference()
                await sessionCoordinator.forceRelease()
                await MainActor.run {
                    update(.setError("Session lost. The model stopped responding. Reload Engine before continuing."))
                    update(.setGenerating(false))
                    update(.setStopping(false))
                }
                return
            }
        }

        do {
            let outboundText = shouldReplayTranscript
                ? Self.replayPrompt(
                    priorMessages: state.messagesBeforeSend,
                    newUserInput: state.trimmedInput,
                    systemPrompt: state.config.systemPrompt,
                    kvCacheSize: state.kvCacheSize
                )
                : state.trimmedInput
            latestStreamedOutput = try await Self.streamResponse(
                outboundText: outboundText,
                conversationConfig: conversationConfig,
                configSignature: configSignature,
                sessionCoordinator: sessionCoordinator,
                watchdog: watchdog,
                logger: logger,
                stopSignal: stopSignal,
                update: update
            )

            guard !(await watchdog.hasTimedOut()) else { return }

            if await stopSignal.isStopRequested() {
                logger.info("AIChat stream completed after stop request")
                await watchdog.finish()
                watchdogTask.cancel()
                var stoppedMessages = state.messagesBeforeSend
                    + [ChatMessage(role: .user, content: state.trimmedInput)]
                if !latestStreamedOutput.isEmpty {
                    stoppedMessages.append(ChatMessage(
                        id: state.assistantMessageID,
                        role: .model,
                        content: latestStreamedOutput
                    ))
                }
                let stoppedNotice = Self.stoppedNoticeMessage()
                stoppedMessages.append(stoppedNotice)
                let stoppedContext = Self.contextState(
                    for: stoppedMessages,
                    kvCacheSize: state.kvCacheSize
                )
                let stoppedOutput = latestStreamedOutput
                let stoppedMessagesSnapshot = stoppedMessages
                await MainActor.run {
                    update(.cancelled(
                        partialContent: stoppedOutput,
                        notice: stoppedNotice,
                        context: ContextState(
                            estimatedTokenCount: stoppedContext.estimatedTokenCount,
                            usagePercent: stoppedContext.usagePercent,
                            warning: stoppedContext.warning
                        ),
                        messages: stoppedMessagesSnapshot,
                        historyConversationID: state.historyConversationID
                    ))
                }
                return
            }

            logger.info("AIChat stream completed; response chars \(latestStreamedOutput.count)")
            let finalResponse = latestStreamedOutput
            let completedMessages = state.messagesBeforeSend
                + [ChatMessage(role: .user, content: state.trimmedInput)]
                + [ChatMessage(
                    id: state.assistantMessageID,
                    role: .model,
                    content: finalResponse.isEmpty ? "(done)" : finalResponse
                )]
            let completedContext = Self.contextState(
                for: completedMessages,
                kvCacheSize: state.kvCacheSize
            )

            await MainActor.run {
                update(.completed(
                    message: ChatMessage(
                        id: state.assistantMessageID,
                        role: .model,
                        content: finalResponse.isEmpty ? "(done)" : finalResponse
                    ),
                    context: ContextState(
                        estimatedTokenCount: completedContext.estimatedTokenCount,
                        usagePercent: completedContext.usagePercent,
                        warning: completedContext.warning
                    ),
                    messages: completedMessages,
                    historyConversationID: state.historyConversationID
                ))
            }
            logger.info("AIChat post-processing: persisting conversation")
            await Self.saveHistory(
                historyStore: historyStore,
                conversationID: state.historyConversationID,
                messages: completedMessages,
                update: update
            )
            logger.info("AIChat post-processing: saving history")
            await watchdog.finish()
            watchdogTask.cancel()
        } catch {
            watchdogTask.cancel()
            if await watchdog.hasTimedOut() {
                return
            }
            let isStopRequested = await stopSignal.isStopRequested()
            let isCancelledError = "\(error)".localizedCaseInsensitiveContains("cancel")
                || Task.isCancelled
                || isStopRequested
            if isCancelledError {
                var stoppedMessages = state.messagesBeforeSend
                    + [ChatMessage(role: .user, content: state.trimmedInput)]
                if !latestStreamedOutput.isEmpty {
                    stoppedMessages.append(ChatMessage(
                        id: state.assistantMessageID,
                        role: .model,
                        content: latestStreamedOutput
                    ))
                }
                let stoppedNotice = Self.stoppedNoticeMessage()
                stoppedMessages.append(stoppedNotice)
                let stoppedContext = Self.contextState(
                    for: stoppedMessages,
                    kvCacheSize: state.kvCacheSize
                )
                let stoppedOutput = latestStreamedOutput
                let stoppedMessagesSnapshot = stoppedMessages
                await MainActor.run {
                    update(.cancelled(
                        partialContent: stoppedOutput,
                        notice: stoppedNotice,
                        context: ContextState(
                            estimatedTokenCount: stoppedContext.estimatedTokenCount,
                            usagePercent: stoppedContext.usagePercent,
                            warning: stoppedContext.warning
                        ),
                        messages: stoppedMessagesSnapshot,
                        historyConversationID: state.historyConversationID
                    ))
                }
            } else {
                let errorText = "\(error)"
                let shouldReload = Self.isStaleNativeSessionError(errorText)
                let failedMessages = state.messagesBeforeSend
                    + [ChatMessage(role: .user, content: state.trimmedInput)]
                await MainActor.run {
                    if shouldReload {
                        update(.failed(
                            error: "Session lost. Tap Reload Engine to recover.",
                            messages: failedMessages,
                            historyConversationID: state.historyConversationID
                        ))
                    } else {
                        update(.failed(
                            error: error.localizedDescription,
                            messages: failedMessages,
                            historyConversationID: state.historyConversationID
                        ))
                    }
                }
            }
        }
    }

    private static func isStaleNativeSessionError(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("session already exists")
            || text.localizedCaseInsensitiveContains("FAILED_PRECONDITION")
            || text.localizedCaseInsensitiveContains("Failed to create conversation")
            || text.localizedCaseInsensitiveContains("Failed to create")
    }

    private static func streamResponse(
        outboundText: String,
        conversationConfig: ConversationConfig,
        configSignature: String,
        sessionCoordinator: SessionCoordinator,
        watchdog: TurnWatchdog,
        logger: Logger,
        stopSignal: StopSignal,
        update: @escaping (SendUpdate) -> Void
    ) async throws -> String {
        let conversation = try await sessionCoordinator.acquireConversation(
            for: .aiChat,
            config: conversationConfig,
            configSignature: configSignature,
            forceNew: true
        )
        var didBeginInference = false

        await watchdog.markProgress()
        guard !(await watchdog.hasTimedOut()) else {
            await sessionCoordinator.releaseConversation(for: .aiChat)
            return ""
        }
        logger.info("AIChat acquireConversation finished")
        let message = Message(outboundText)
        var streamedOutput = ""

        await sessionCoordinator.beginInference()
        didBeginInference = true
        logger.info("AIChat stream begin; prompt chars \(outboundText.count)")

        do {
            var lastUIUpdate = Date.distantPast
            for try await chunk in conversation.sendMessageStream(message) {
                if let firstContent = chunk.contents.first {
                    switch firstContent {
                    case .text(let text):
                        await watchdog.markTokenProgress()
                        streamedOutput += text
                        let now = Date()
                        if now.timeIntervalSince(lastUIUpdate) >= Self.streamUIUpdateInterval {
                            lastUIUpdate = now
                            let snapshot = streamedOutput
                            await MainActor.run {
                                update(.setStreamingContent(snapshot))
                            }
                        }
                    default:
                        break
                    }
                }
            }

            let finalSnapshot = streamedOutput
            await MainActor.run {
                update(.setStreamingContent(finalSnapshot))
            }

            if Task.isCancelled, !(await stopSignal.isStopRequested()) {
                logger.info("AIChat stream completed but task was cancelled; treating as stop")
                throw CancellationError()
            }

            await sessionCoordinator.endInference()
            didBeginInference = false
            await sessionCoordinator.releaseConversation(for: .aiChat)
            return streamedOutput
        } catch {
            if didBeginInference {
                await sessionCoordinator.endInference()
            }
            await sessionCoordinator.releaseConversation(for: .aiChat)
            throw error
        }
    }

    private actor StopSignal {
        private var stopRequested = false

        func requestStop() {
            stopRequested = true
        }

        func isStopRequested() -> Bool {
            stopRequested
        }
    }

    private actor TurnWatchdog {
        private var completed = false
        private var timedOut = false
        private var didReceiveToken = false
        private var lastProgress = Date()

        func markProgress() {
            guard !completed, !timedOut else { return }
            lastProgress = Date()
        }

        func markTokenProgress() {
            guard !completed, !timedOut else { return }
            lastProgress = Date()
            didReceiveToken = true
        }

        func triggerTimeoutIfIdle(
            firstTokenTimeout: TimeInterval,
            tokenStallTimeout: TimeInterval
        ) -> Bool {
            guard !completed, !timedOut else { return false }
            let timeout = didReceiveToken ? tokenStallTimeout : firstTokenTimeout
            guard Date().timeIntervalSince(lastProgress) >= timeout else { return false }
            timedOut = true
            return true
        }

        func hasTimedOut() -> Bool {
            timedOut
        }

        func finish() {
            completed = true
        }
    }

    private static func estimatedTokenCount(for messages: [ChatMessage]) -> Int {
        messages.reduce(0) { partial, message in
            guard !message.isStatusMessage else { return partial }
            return partial + estimatedTokens(for: message.content)
        }
    }

    private static func estimatedTokens(for text: String) -> Int {
        // Gemma 4's tokenizer averages ~3.5 characters per token for English text.
        max(1, Int(Double(text.count) / 3.5))
    }

    private static func contextState(
        for messages: [ChatMessage],
        kvCacheSize: Int
    ) -> (estimatedTokenCount: Int, usagePercent: Int, warning: String?) {
        let estimatedTokenCount = Self.estimatedTokenCount(for: messages)
        let usagePercent = Double(estimatedTokenCount) / Double(kvCacheSize)
        var percent = min(100, max(0, Int((usagePercent * 100).rounded())))
        if estimatedTokenCount > 0, percent == 0 {
            percent = 1
        }

        let warning: String?
        if usagePercent >= 0.90 {
            warning = "Context is nearly full. Start fresh before continuing."
        } else if usagePercent >= 0.70 {
            warning = "Context is getting long. Start fresh soon for better responses."
        } else {
            warning = nil
        }

        return (estimatedTokenCount, percent, warning)
    }

    private static func contextPressure(
        messages: [ChatMessage],
        additionalText: String,
        kvCacheSize: Int
    ) -> Double {
        guard kvCacheSize > 0 else { return 0 }
        let estimatedTokenCount = Self.estimatedTokenCount(for: messages)
            + Self.estimatedTokens(for: additionalText)
        return min(max(Double(estimatedTokenCount) / Double(kvCacheSize), 0), 1)
    }

    private static func firstTokenTimeout(for contextPressure: Double) -> TimeInterval {
        minimumFirstTokenTimeout
            + ((maximumFirstTokenTimeout - minimumFirstTokenTimeout) * contextPressure)
    }

    private static func tokenStallTimeout(for contextPressure: Double) -> TimeInterval {
        minimumTokenStallTimeout
            + ((maximumTokenStallTimeout - minimumTokenStallTimeout) * contextPressure)
    }

    private static func replayPrompt(
        priorMessages: [ChatMessage],
        newUserInput: String,
        systemPrompt: String,
        kvCacheSize: Int
    ) -> String {
        let transcriptBudget = Self.replayTranscriptBudget(
            kvCacheSize: kvCacheSize,
            systemPrompt: systemPrompt,
            newUserInput: newUserInput
        )
        let transcript = Self.boundedTranscript(
            from: priorMessages,
            tokenBudget: transcriptBudget
        )

        guard !transcript.isEmpty else {
            return newUserInput
        }

        return """
        Continue this prior conversation. Use it as context, then answer the latest user message.

        Prior conversation:
        \(transcript)

        Latest user message:
        \(newUserInput)
        """
    }

    private static func replayTranscriptBudget(
        kvCacheSize: Int,
        systemPrompt: String,
        newUserInput: String
    ) -> Int {
        let responseReserve = min(max(kvCacheSize / 4, 1_024), 4_096)
        let fixedPromptReserve = 160
        return max(
            0,
            kvCacheSize
                - Self.estimatedTokens(for: systemPrompt)
                - Self.estimatedTokens(for: newUserInput)
                - responseReserve
                - fixedPromptReserve
        )
    }

    private static func boundedTranscript(from priorMessages: [ChatMessage], tokenBudget: Int) -> String {
        guard tokenBudget > 0 else { return "" }

        var remainingTokens = tokenBudget
        var selectedLines: [String] = []

        let replayableMessages = priorMessages
            .filter {
                !$0.isStatusMessage &&
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .reversed()

        for message in replayableMessages {
            let line = "\(message.role.transcriptLabel): \(message.content)"
            let tokens = Self.estimatedTokens(for: line)

            if tokens <= remainingTokens {
                selectedLines.insert(line, at: 0)
                remainingTokens -= tokens
                continue
            }

            guard selectedLines.isEmpty, remainingTokens > 64 else {
                continue
            }

            let prefix = "\(message.role.transcriptLabel): [Earlier content truncated]\n"
            let availableCharacters = max(0, (remainingTokens * 4) - prefix.count)
            guard availableCharacters > 0 else { break }

            let suffix = String(message.content.suffix(availableCharacters))
            selectedLines.insert(prefix + suffix, at: 0)
            break
        }

        return selectedLines.joined(separator: "\n\n")
    }

    private static func buildConversationConfig(config: InferenceConfig) throws -> ConversationConfig {
        let samplerConfig = try SamplerConfig(
            topK: config.topK,
            topP: Float(config.topP),
            temperature: Float(config.temperature)
        )

        let systemPrompt = Self.systemPromptWithCurrentDateTime(config.systemPrompt)
        let systemMessage: Message? = systemPrompt.isEmpty
            ? nil
            : Message(systemPrompt, role: .system)

        return ConversationConfig(
            systemMessage: systemMessage,
            samplerConfig: samplerConfig
        )
    }

    private static func systemPromptWithCurrentDateTime(_ systemPrompt: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let dateContext = "Current date-time (local, ISO-8601): \(now)"

        if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return dateContext
        }

        return systemPrompt + "\n\n" + dateContext
    }

    private static func stoppedNoticeMessage() -> ChatMessage {
        ChatMessage(
            role: .system,
            content: "Stopped by user",
            isStatusMessage: true
        )
    }

    private static func saveHistory(
        historyStore: HistoryStoreProtocol,
        conversationID: UUID,
        messages: [ChatMessage],
        update: @escaping (SendUpdate) -> Void
    ) async {
        do {
            try historyStore.saveConversation(
                id: conversationID,
                mode: .aiChat,
                skillName: nil,
                skillId: nil,
                messages: messages
            )
        } catch {
            await MainActor.run {
                update(.setError("Response generated, but history could not be saved: \(error.localizedDescription)"))
            }
        }
    }

}

private extension MessageRole {
    var transcriptLabel: String {
        switch self {
        case .user:
            return "User"
        case .model:
            return "Assistant"
        case .system:
            return "System"
        }
    }
}
