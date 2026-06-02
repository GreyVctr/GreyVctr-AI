import LiteRTLM
import Foundation
import OSLog

/// Manages the multi-skill chat interface.
///
/// Uses a generic system prompt with the enabled skills catalog, then lets the
/// model select the appropriate skill for the current request.
@Observable
final class SkillsChatViewModel {

    // MARK: - Published State

    var messages: [ChatMessage] = []
    var currentInput: String = ""
    var isGenerating: Bool = false
    /// True after the user taps stop and before LiteRT-LM finishes unwinding the stream.
    var isStopping: Bool = false
    /// Live streaming text shown in the current model bubble. Nil when not streaming.
    var streamingContent: String?
    /// Short status shown while hidden agent/tool-routing passes run.
    var generationStatus: String?
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
    private let jsRuntime: JSRuntimeProtocol
    private let appState: AppState
    private let userSettings: UserSettings
    private let kvCacheSize: Int
    private let logger = Logger(
        subsystem: "com.guardai.app",
        category: "SkillsChatViewModel"
    )
    private var needsNewConversation = false
    private var userRequestedCancellation = false
    private var shouldReplayPersistedTranscript = false
    private var activeConfigSignature: String?
    private var estimatedTokenCount: Int = 0
    private var historyConversationID: UUID
    /// Reference to the active inference task for cancellation propagation.
    private var activeTask: Task<Void, Never>?
    /// Stop state for the active turn. Stop should cancel LiteRT inference, not
    /// the Swift task that drains the SDK stream callback.
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
        jsRuntime: JSRuntimeProtocol,
        appState: AppState,
        userSettings: UserSettings,
        kvCacheSize: Int
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.configLoader = configLoader
        self.historyStore = historyStore
        self.conversationStore = conversationStore
        self.jsRuntime = jsRuntime
        self.appState = appState
        self.userSettings = userSettings
        self.kvCacheSize = kvCacheSize

        let restoredMessages = conversationStore.loadMessages(for: .chatWithSkills)
        self.messages = restoredMessages
        self.shouldReplayPersistedTranscript = !restoredMessages.isEmpty
        // The persisted transcript is visible history, not live KV cache state.
        // Start the active context estimate at zero and track only tokens sent
        // through the current conversation session.
        self.estimatedTokenCount = 0
        self.historyConversationID = conversationStore.loadHistoryEntryID(for: .chatWithSkills) ?? UUID()
        conversationStore.saveHistoryEntryID(historyConversationID, for: .chatWithSkills)
        updateContextUsage()
    }

    // MARK: - Actions

    @MainActor
    func sendMessage(enabledSkills: [SkillDefinition]) async {
        submitMessage(enabledSkills: enabledSkills)
    }

    @MainActor
    func submitMessage(enabledSkills: [SkillDefinition]) {
        logger.info("Skills submitMessage entered; generating=\(self.isGenerating ? "true" : "false"), stopping=\(self.isStopping ? "true" : "false")")
        guard !isGenerating, !isStopping else {
            logger.info("Skills submitMessage ignored because generation is already active")
            return
        }

        let trimmedInput = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            logger.info("Skills submitMessage ignored because input is empty")
            error = "Please enter a message."
            return
        }

        if needsNewConversation {
            needsNewConversation = false
        }

        error = nil
        isGenerating = true
        isStopping = false
        userRequestedCancellation = false
        appState.beginChatInputLock()
        defer { appState.endChatInputLock() }

        generationStatus = "Thinking…"

        let priorMessages = messages
        let userMessage = ChatMessage(role: .user, content: trimmedInput)
        messages.append(userMessage)
        scheduleConversationPersistence(messages: messages, historyConversationID: historyConversationID)
        currentInput = ""

        if Self.isSkillCatalogRequest(trimmedInput) {
            let catalogResponse = Self.skillCatalogResponse(enabledSkills: enabledSkills)
            let modelMessage = ChatMessage(role: .model, content: catalogResponse)
            messages.append(modelMessage)
            persistConversation()
            saveHistory(userInput: trimmedInput, response: catalogResponse, matchedSkill: nil)
            generationStatus = nil
            isGenerating = false
            logger.info("Skills catalog request answered without skill routing")
            return
        }

        let config = configLoader.load(for: .chatWithSkills)
        let effectiveConfig = InferenceConfig(
            temperature: userSettings.effectiveTemperature(configDefault: config.temperature),
            topK: userSettings.effectiveTopK(configDefault: config.topK),
            topP: userSettings.effectiveTopP(configDefault: config.topP),
            systemPrompt: userSettings.effectiveSystemPrompt(
                for: .chatWithSkills,
                configDefault: config.systemPrompt
            )
        )

        let selectedSkill = Self.selectSkill(
            for: trimmedInput,
            enabledSkills: enabledSkills
        )
        generationStatus = selectedSkill.map { "Using skill: \($0.name)" } ?? "Thinking…"
        let routingSystemPrompt = Self.buildSystemPrompt(
            enabledSkills: enabledSkills,
            config: effectiveConfig
        )
        let selectedSystemPrompt = Self.buildSkillsSystemPrompt(
            selectedSkill: selectedSkill,
            basePrompt: selectedSkill == nil ? routingSystemPrompt : effectiveConfig.systemPrompt
        )
        let configSignature = Self.configSignature(for: effectiveConfig, systemPrompt: selectedSystemPrompt)
        activeConfigSignature = configSignature
        let outboundText = selectedSkill.map {
            Self.skillLoadedPrompt(
                skill: $0,
                userInput: trimmedInput,
                priorMessages: priorMessages,
                systemPrompt: selectedSystemPrompt
            )
        } ?? Self.skillChatPrompt(
            userInput: trimmedInput,
            priorMessages: priorMessages,
            enabledSkills: enabledSkills,
            systemPrompt: selectedSystemPrompt
        )

        let state = SendStateSnapshot(
            messagesIncludingUser: messages,
            trimmedInput: trimmedInput,
            outboundText: outboundText,
            config: effectiveConfig,
            systemPrompt: selectedSystemPrompt,
            configSignature: configSignature,
            enabledSkills: enabledSkills,
            selectedSkill: selectedSkill,
            activeBackend: appState.engineBackend,
            historyConversationID: historyConversationID,
            kvCacheSize: kvCacheSize,
            userRequestedCancellation: userRequestedCancellation
        )
        let stopSignal = StopSignal()
        activeStopSignal = stopSignal

        logger.info("Skills submitMessage snapshot ready; prompt chars \(trimmedInput.count), outbound chars \(outboundText.count), selected skill \(selectedSkill?.name ?? "none")")
        logger.info("Skills submitMessage launching structured task")
        activeTask?.cancel()
        activeTask = Task(priority: .userInitiated) { [sessionCoordinator, historyStore, conversationStore, jsRuntime, logger, weak self] in
            logger.info("Skills structured task starting")
            await Self.runSend(
                state: state,
                sessionCoordinator: sessionCoordinator,
                historyStore: historyStore,
                conversationStore: conversationStore,
                jsRuntime: jsRuntime,
                logger: logger,
                stopSignal: stopSignal,
                update: { [weak self] batch in
                    guard let self else { return }
                    await MainActor.run {
                        self.applyBatch(batch)
                    }
                }
            )
        }
    }

    @MainActor
    func stopGenerating() {
        guard isGenerating, !isStopping else { return }
        userRequestedCancellation = true
        isStopping = true
        generationStatus = "Stopping…"
        // Call cancel() on the SDK conversation to stop the C++ inference and
        // release the internal StreamContext that retains the Conversation.
        // Required for the conversation to deinit and clear the engine session.
        // runSend is the sole owner that releases the conversation.
        let stopSignal = activeStopSignal
        Task {
            await stopSignal?.requestStop()
            try? await sessionCoordinator.cancelIfActive()
        }
    }

    @MainActor
    func newConversation() {
        messages = []
        activeTask?.cancel()
        activeTask = nil
        let stopSignal = activeStopSignal
        activeStopSignal = nil
        Task { await stopSignal?.requestStop() }
        currentInput = ""
        error = nil
        streamingContent = nil
        isStopping = false
        generationStatus = nil
        contextWarning = nil
        contextUsagePercent = 0
        needsNewConversation = false
        estimatedTokenCount = 0
        activeConfigSignature = nil
        shouldReplayPersistedTranscript = false
        historyConversationID = UUID()
        conversationStore.clearMessages(for: .chatWithSkills)
        conversationStore.clearHistoryEntryID(for: .chatWithSkills)
        Task { await sessionCoordinator.releaseConversation(for: .skillsChat) }
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
        error = nil
        streamingContent = nil
        isGenerating = false
        isStopping = false
        generationStatus = nil
        contextWarning = nil
        needsNewConversation = false
        activeConfigSignature = nil
        shouldReplayPersistedTranscript = !restoredMessages.isEmpty
        estimatedTokenCount = Self.estimatedTokenCount(for: restoredMessages)
        historyConversationID = id
        updateContextUsage()
        conversationStore.saveMessages(restoredMessages, for: .chatWithSkills)
        conversationStore.saveHistoryEntryID(id, for: .chatWithSkills)
        Task { await sessionCoordinator.releaseConversation(for: .skillsChat) }
    }

    // MARK: - Private

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

    private func initializeContextEstimateIfNeeded(systemPrompt: String) {
        guard estimatedTokenCount == 0 else { return }
        addEstimatedTokens(systemPrompt)
        updateContextUsage()
    }

    private func addEstimatedTokens(_ text: String) {
        estimatedTokenCount += Self.estimatedTokens(for: text)
    }

    private func persistConversation() {
        conversationStore.saveMessages(messages, for: .chatWithSkills)
        conversationStore.saveHistoryEntryID(historyConversationID, for: .chatWithSkills)
    }

    private func scheduleConversationPersistence(messages: [ChatMessage], historyConversationID: UUID) {
        let snapshot = messages
        let store = conversationStore
        Task.detached(priority: .utility) {
            store.saveMessages(snapshot, for: .chatWithSkills)
            store.saveHistoryEntryID(historyConversationID, for: .chatWithSkills)
        }
    }



    // MARK: - Batched State Updates

    /// Encapsulates context-window usage state for batched UI updates.
    private struct ContextState: Sendable {
        let estimatedTokenCount: Int
        let usagePercent: Int
        let warning: String?
    }

    /// Compound update applied in a single MainActor block to minimize render passes.
    /// Always applied on MainActor so does not need Sendable conformance.
    private enum BatchedUpdate {
        /// Progressive streaming update (during generation)
        case streaming(String)
        /// Generation status label
        case status(String?)
        /// Turn completed successfully — all terminal state in one shot
        case completed(message: ChatMessage, context: ContextState)
        /// Turn failed — all terminal state in one shot
        case failed(error: Error)
        /// Turn cancelled by user — all terminal state in one shot
        case cancelled(partialContent: String?, context: ContextState)
        /// Watchdog timeout or other system error
        case error(String)
    }

    @MainActor
    private func applyBatch(_ update: BatchedUpdate) {
        switch update {
        case .streaming(let content):
            streamingContent = content
        case .status(let label):
            generationStatus = label
        case .completed(let message, let context):
            streamingContent = nil
            generationStatus = nil
            messages.append(message)
            estimatedTokenCount = context.estimatedTokenCount
            contextUsagePercent = context.usagePercent
            contextWarning = context.warning
            isGenerating = false
            isStopping = false
            activeStopSignal = nil
        case .failed(let error):
            streamingContent = nil
            generationStatus = nil
            self.error = error.localizedDescription
            isGenerating = false
            isStopping = false
            activeStopSignal = nil
        case .cancelled(let partialContent, let context):
            streamingContent = nil
            generationStatus = nil
            if let partialContent, !partialContent.isEmpty {
                messages.append(ChatMessage(role: .model, content: partialContent))
            }
            messages.append(Self.stoppedNoticeMessage())
            estimatedTokenCount = context.estimatedTokenCount
            contextUsagePercent = context.usagePercent
            contextWarning = context.warning
            isGenerating = false
            isStopping = false
            activeStopSignal = nil
        case .error(let message):
            streamingContent = nil
            generationStatus = nil
            self.error = message
            isGenerating = false
            isStopping = false
            activeStopSignal = nil
        }
    }

    // MARK: - Send State

    private struct SendStateSnapshot: Sendable {
        let messagesIncludingUser: [ChatMessage]
        let trimmedInput: String
        let outboundText: String
        let config: InferenceConfig
        let systemPrompt: String
        let configSignature: String
        let enabledSkills: [SkillDefinition]
        let selectedSkill: SkillDefinition?
        let activeBackend: EngineBackend?
        let historyConversationID: UUID
        let kvCacheSize: Int
        let userRequestedCancellation: Bool
    }

    private struct ProcessedSkillResponse {
        let finalResponse: String
        let usedSkill: SkillDefinition?
        let rawToolCallData: String?
    }

    private static func runSend(
        state: SendStateSnapshot,
        sessionCoordinator: SessionCoordinator,
        historyStore: HistoryStoreProtocol,
        conversationStore: ConversationStoreProtocol,
        jsRuntime: JSRuntimeProtocol,
        logger: Logger,
        stopSignal: StopSignal,
        update: @escaping (BatchedUpdate) async -> Void
    ) async {
        let conversationConfig: ConversationConfig
        do {
            conversationConfig = try Self.buildConversationConfig(
                config: state.config,
                systemPrompt: state.systemPrompt
            )
        } catch {
            await update(.failed(error: error))
            return
        }

        logger.info("Skills acquireConversation starting; prompt chars \(state.outboundText.count), skills \(state.enabledSkills.count)")

        let watchdog = TurnWatchdog()
        let contextPressure = Self.contextPressure(
            messages: state.messagesIncludingUser,
            additionalText: state.outboundText,
            kvCacheSize: state.kvCacheSize
        )
        let firstTokenTimeout = Self.firstTokenTimeout(for: contextPressure)
        let tokenStallTimeout = Self.tokenStallTimeout(for: contextPressure)

        let watchdogTask = Task.detached(priority: .high) { [sessionCoordinator, logger, update] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                guard await watchdog.triggerTimeoutIfIdle(
                    firstTokenTimeout: firstTokenTimeout,
                    tokenStallTimeout: tokenStallTimeout
                ) else { continue }
                logger.error("Skills turn idle timed out")
                try? await sessionCoordinator.cancelIfActive()
                await sessionCoordinator.endInference()
                await sessionCoordinator.forceRelease()
                await update(.error("The model stopped responding. Reload Engine before continuing."))
                return
            }
        }

        do {
            let rawResponse = try await Self.runInferenceResponse(
                state: state,
                conversationConfig: conversationConfig,
                sessionCoordinator: sessionCoordinator,
                watchdog: watchdog,
                logger: logger,
                stopSignal: stopSignal,
                streamingUpdate: { content in
                    // Always pass streaming content — the view decides how to display it
                    // (collapsible thinking bubble for JS skills, full streaming for text skills)
                    await update(.streaming(content))
                }
            )

            await watchdog.finish()
            watchdogTask.cancel()

            if await stopSignal.isStopRequested() {
                logger.info("Skills stream completed after stop request")
                let stoppedContext = Self.contextState(
                    for: state.messagesIncludingUser,
                    additionalText: "",
                    kvCacheSize: state.kvCacheSize
                )
                await update(.cancelled(
                    partialContent: nil,
                    context: ContextState(
                        estimatedTokenCount: stoppedContext.estimatedTokenCount,
                        usagePercent: stoppedContext.usagePercent,
                        warning: stoppedContext.warning
                    )
                ))
                let stoppedMessages = state.messagesIncludingUser + [Self.stoppedNoticeMessage()]
                conversationStore.saveMessages(stoppedMessages, for: .chatWithSkills)
                conversationStore.saveHistoryEntryID(state.historyConversationID, for: .chatWithSkills)
                return
            }

            logger.info("Skills streamResponse completed; raw response chars \(rawResponse.count)")
            logger.info("[SkillsChat] Raw response (\(rawResponse.count) chars): \(rawResponse.prefix(200))")

            let processed = await Self.processSkillResponse(
                rawResponse: rawResponse,
                state: state,
                jsRuntime: jsRuntime,
                logger: logger
            )
            let modelMessage = ChatMessage(
                role: .model,
                content: processed.finalResponse,
                toolCallSkillName: processed.usedSkill?.name,
                toolCallData: processed.rawToolCallData
            )
            let completedMessages = state.messagesIncludingUser + [modelMessage]
            let completedContext = Self.contextState(
                for: completedMessages,
                additionalText: state.outboundText,
                kvCacheSize: state.kvCacheSize
            )

            logger.info("Skills post-processing: appending model message")
            await update(.completed(
                message: modelMessage,
                context: ContextState(
                    estimatedTokenCount: completedContext.estimatedTokenCount,
                    usagePercent: completedContext.usagePercent,
                    warning: completedContext.warning
                )
            ))

            logger.info("Skills post-processing: persisting conversation")
            conversationStore.saveMessages(completedMessages, for: .chatWithSkills)
            conversationStore.saveHistoryEntryID(state.historyConversationID, for: .chatWithSkills)
            logger.info("Skills post-processing: saving history")
            await Self.saveHistory(
                historyStore: historyStore,
                conversationID: state.historyConversationID,
                messages: completedMessages,
                matchedSkill: processed.usedSkill,
                logger: logger
            )
            logger.info("Skills post-processing: complete")
        } catch {
            watchdogTask.cancel()
            if await watchdog.hasTimedOut() {
                // Watchdog already sent the error update and released conversation
                return
            }

            let desc = "\(error)"
            let isStopRequested = await stopSignal.isStopRequested()
            if desc.localizedCaseInsensitiveContains("cancel")
                || Task.isCancelled
                || isStopRequested {
                let stoppedContext = Self.contextState(
                    for: state.messagesIncludingUser,
                    additionalText: "",
                    kvCacheSize: state.kvCacheSize
                )
                await update(.cancelled(
                    partialContent: nil,
                    context: ContextState(
                        estimatedTokenCount: stoppedContext.estimatedTokenCount,
                        usagePercent: stoppedContext.usagePercent,
                        warning: stoppedContext.warning
                    )
                ))
                let stoppedMessages = state.messagesIncludingUser + [Self.stoppedNoticeMessage()]
                conversationStore.saveMessages(stoppedMessages, for: .chatWithSkills)
                conversationStore.saveHistoryEntryID(state.historyConversationID, for: .chatWithSkills)
            } else {
                let message: String
                switch error {
                case is SessionCoordinatorError:
                    message = "Session lost. Tap Reload Engine to recover."
                case let runtimeErr as SkillsChatRuntimeError where runtimeErr.isConversationNotAlive:
                    message = "Session lost. Tap Reload Engine to recover."
                default:
                    if desc.contains("notAlive")
                        || desc.contains("failedToCreate")
                        || desc.contains("Failed to create")
                        || desc.contains("conversationNotAlive") {
                        message = "Session lost. Tap Reload Engine to recover."
                    } else {
                        message = error.localizedDescription
                    }
                }
                await update(.failed(error: SkillsChatRuntimeError.displayMessage(message)))
            }
        }
    }

    private static func isStaleNativeSessionError(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("session already exists")
            || text.localizedCaseInsensitiveContains("FAILED_PRECONDITION")
            || text.localizedCaseInsensitiveContains("Failed to create conversation")
            || text.localizedCaseInsensitiveContains("Failed to create")
    }

    private static func processSkillResponse(
        rawResponse: String,
        state: SendStateSnapshot,
        jsRuntime: JSRuntimeProtocol,
        logger: Logger
    ) async -> ProcessedSkillResponse {
        logger.info("Skills post-processing: stripping metadata")
        let stripped = ToolCallMetadataParser.stripMetadata(from: rawResponse)
        logger.info("Skills post-processing: metadata stripped; clean chars \(stripped.cleanContent.count), json chars \(stripped.jsonData?.count ?? 0)")

        var finalResponse: String
        var usedSkillName: String? = state.selectedSkill?.name

        if let selectedSkill = state.selectedSkill,
           selectedSkill.skillType == .jsBacked,
           let jsContent = selectedSkill.jsContent,
           let jsonData = stripped.jsonData {
            logger.info("Skills post-processing: executing selected JS skill \(selectedSkill.name)")
            usedSkillName = selectedSkill.name
            finalResponse = await Self.executeJSSkill(
                skill: selectedSkill,
                jsContent: jsContent,
                jsonData: jsonData,
                userInput: state.trimmedInput,
                jsRuntime: jsRuntime
            )
        } else if let selectedSkill = state.selectedSkill,
                  selectedSkill.skillType == .jsBacked,
                  let jsContent = selectedSkill.jsContent,
                  let inferredJSON = Self.inferJSInput(for: selectedSkill.name, from: state.trimmedInput) {
            logger.info("Skills post-processing: inferred JS input for selected skill \(selectedSkill.name)")
            usedSkillName = selectedSkill.name
            finalResponse = await Self.executeJSSkill(
                skill: selectedSkill,
                jsContent: jsContent,
                jsonData: inferredJSON,
                userInput: state.trimmedInput,
                jsRuntime: jsRuntime
            )
        } else if let jsonData = stripped.jsonData,
                  let detectedSkill = Self.detectSkillNameFromToolCall(
                      json: jsonData,
                      response: rawResponse,
                      enabledSkills: state.enabledSkills
                  ) {
            logger.info("Skills post-processing: detected JS tool skill \(detectedSkill.name)")
            usedSkillName = detectedSkill.name
            if let jsContent = detectedSkill.jsContent {
                logger.info("Skills post-processing: executing detected JS skill \(detectedSkill.name)")
                finalResponse = await Self.executeJSSkill(
                    skill: detectedSkill,
                    jsContent: jsContent,
                    jsonData: jsonData,
                    userInput: state.trimmedInput,
                    jsRuntime: jsRuntime
                )
            } else {
                finalResponse = stripped.cleanContent.isEmpty ? rawResponse : stripped.cleanContent
            }
        } else if let jsonData = stripped.jsonData,
                  let textSkill = Self.detectTextSkillFromResponse(
                      response: rawResponse,
                      enabledSkills: state.enabledSkills
                  ) {
            logger.info("Skills post-processing: detected text skill \(textSkill.name)")
            usedSkillName = textSkill.name
            let textContent = Self.extractTextFromJSON(jsonData) ?? stripped.cleanContent
            finalResponse = textContent.isEmpty ? rawResponse : textContent
        } else {
            logger.info("Skills post-processing: no tool metadata matched; using cleaned content")
            finalResponse = stripped.cleanContent.isEmpty ? rawResponse : stripped.cleanContent
        }

        logger.info("Skills post-processing: final response ready; chars \(finalResponse.count)")
        let usedSkill = usedSkillName.flatMap { name in
            state.enabledSkills.first { $0.name == name }
        }
        // Pass raw JSON data for the "View raw output" toggle in SkillToolCallIndicator
        let rawData = stripped.jsonData
        return ProcessedSkillResponse(finalResponse: finalResponse, usedSkill: usedSkill, rawToolCallData: rawData)
    }

    private static func executeJSSkill(
        skill: SkillDefinition,
        jsContent: String,
        jsonData: String,
        userInput: String,
        jsRuntime: JSRuntimeProtocol
    ) async -> String {
        var inputJSON = Self.extractRunJSData(from: jsonData) ?? jsonData

        // Attempt to repair truncated JSON before passing to JS runtime.
        // The model often generates incomplete JSON for complex payloads.
        if let data = inputJSON.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) == nil {
            // JSON is invalid — try to repair it
            if let repaired = repairTruncatedJSON(inputJSON) {
                inputJSON = repaired
            }
            // If repair failed, still try passing to JS — it may have its own error handling
        }

        do {
            let result = try await jsRuntime.execute(script: jsContent, inputJSON: inputJSON)
            return Self.formatJSResult(result, skillName: skill.name, userInput: userInput)
        } catch {
            return "The \(skill.name) skill could not complete: \(error.localizedDescription)"
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
        additionalText: String,
        kvCacheSize: Int
    ) -> (estimatedTokenCount: Int, usagePercent: Int, warning: String?) {
        let estimatedTokenCount = Self.estimatedTokenCount(for: messages)
            + (additionalText.isEmpty ? 0 : Self.estimatedTokens(for: additionalText))
        let usage = Double(estimatedTokenCount) / Double(kvCacheSize)
        let usagePercent = min(100, max(0, Int((usage * 100).rounded())))
        let warning: String?
        if usage >= 0.90 {
            warning = "Context is nearly full. Start fresh before continuing."
        } else if usage >= 0.70 {
            warning = "Context is getting long. Start fresh soon for better responses."
        } else {
            warning = nil
        }
        return (estimatedTokenCount, usagePercent, warning)
    }

    private func replayPrompt(priorMessages: [ChatMessage], newUserInput: String, systemPrompt: String) -> String {
        let transcriptBudget = replayTranscriptBudget(
            systemPrompt: systemPrompt,
            newUserInput: newUserInput
        )
        let transcript = boundedTranscript(
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

    private func replayTranscriptBudget(systemPrompt: String, newUserInput: String) -> Int {
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

    private func boundedTranscript(from priorMessages: [ChatMessage], tokenBudget: Int) -> String {
        guard tokenBudget > 0 else { return "" }

        var remainingTokens = tokenBudget
        var selectedLines: [String] = []

        let replayableMessages = priorMessages
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

    private static func configSignature(for config: InferenceConfig, systemPrompt: String) -> String {
        "\(config.temperature)|\(config.topK)|\(config.topP)|\(systemPrompt)"
    }

    private static func buildConversationConfig(config: InferenceConfig, systemPrompt: String) throws -> ConversationConfig {
        let samplerConfig = try SamplerConfig(
            topK: config.topK,
            topP: Float(config.topP),
            temperature: Float(config.temperature)
        )

        let systemMessage: Message? = systemPrompt.isEmpty
            ? nil
            : Message(systemPrompt, role: .system)

        return ConversationConfig(
            systemMessage: systemMessage,
            samplerConfig: samplerConfig
        )
    }

    private func saveHistory(userInput: String, response: String, matchedSkill: SkillDefinition?) {
        let messagesSnapshot = messages
        let skillName = matchedSkill?.name ?? messagesSnapshot.reversed().compactMap(\.skillName).first
        let skillId = matchedSkill?.id
        let conversationID = historyConversationID

        Task.detached(priority: .utility) { [historyStore] in
            await Task.yield()
            do {
                try historyStore.saveConversation(
                    id: conversationID,
                    mode: .chatWithSkills,
                    skillName: skillName,
                    skillId: skillId,
                    messages: messagesSnapshot
                )
            } catch {
                await MainActor.run {
                    self.error = "Response generated, but history could not be saved: \(error.localizedDescription)"
                }
            }
        }
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
        matchedSkill: SkillDefinition?,
        logger: Logger
    ) async {
        let skillName = matchedSkill?.name ?? messages.reversed().compactMap(\.skillName).first
        do {
            try historyStore.saveConversation(
                id: conversationID,
                mode: .chatWithSkills,
                skillName: skillName,
                skillId: matchedSkill?.id,
                messages: messages
            )
        } catch {
            logger.error("History save failed: \(error.localizedDescription)")
        }
    }

    private enum SkillsChatRuntimeError: LocalizedError {
        case inferenceTimedOut
        case conversationNotAlive
        case displayMessage(String)

        var isConversationNotAlive: Bool {
            if case .conversationNotAlive = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .inferenceTimedOut:
                return "The skill response timed out. Try the request again."
            case .conversationNotAlive:
                return "Session lost. Tap Reload Engine to recover."
            case .displayMessage(let message):
                return message
            }
        }
    }



    private static func runInferenceResponse(
        state: SendStateSnapshot,
        conversationConfig: ConversationConfig,
        sessionCoordinator: SessionCoordinator,
        watchdog: TurnWatchdog,
        logger: Logger,
        stopSignal: StopSignal,
        streamingUpdate: @escaping (String) async -> Void
    ) async throws -> String {
        let conversation = try await sessionCoordinator.acquireConversation(
            for: .skillsChat,
            config: conversationConfig,
            configSignature: state.configSignature,
            forceNew: true
        )
        logger.info("Skills acquireConversation finished")

        await watchdog.markProgress()
        await sessionCoordinator.beginInference()
        var didBeginInference = true

        do {
            let response = try await Self.streamResponse(
                for: state.outboundText,
                conversation: conversation,
                sessionCoordinator: sessionCoordinator,
                watchdog: watchdog,
                logger: logger,
                streamingUpdate: streamingUpdate
            )

            await sessionCoordinator.endInference()
            didBeginInference = false
            await sessionCoordinator.releaseConversation(for: .skillsChat)

            if Task.isCancelled, !(await stopSignal.isStopRequested()) {
                logger.info("Skills stream completed but task was cancelled; treating as stop")
                throw CancellationError()
            }

            return response
        } catch {
            if didBeginInference {
                await sessionCoordinator.endInference()
            }
            await sessionCoordinator.releaseConversation(for: .skillsChat)
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

    private static func streamResponse(
        for prompt: String,
        conversation: Conversation,
        sessionCoordinator: SessionCoordinator,
        watchdog: TurnWatchdog,
        logger: Logger,
        streamingUpdate: @escaping (String) async -> Void
    ) async throws -> String {
        let message = Message(prompt)
        var accumulated = ""
        var lastUIUpdate = Date.distantPast

        logger.info("Skills stream begin; prompt characters \(prompt.count)")

        for try await chunk in conversation.sendMessageStream(message) {
            try Task.checkCancellation()

            if let firstContent = chunk.contents.first {
                switch firstContent {
                case .text(let text):
                    await watchdog.markTokenProgress()
                    accumulated += text
                    let now = Date()
                    if now.timeIntervalSince(lastUIUpdate) >= Self.streamUIUpdateInterval {
                        lastUIUpdate = now
                        await streamingUpdate(accumulated)
                    }
                default:
                    break
                }
            }
        }

        // Final UI update to ensure the last tokens are rendered
        await streamingUpdate(accumulated)

        logger.info("Skills stream completed; response characters \(accumulated.count)")
        return accumulated
    }

    // MARK: - TurnWatchdog

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

    private static func skillLoadedPrompt(
        skill: SkillDefinition,
        userInput: String,
        priorMessages: [ChatMessage] = [],
        systemPrompt: String = ""
    ) -> String {
        let transcript = skillTranscriptContext(
            priorMessages: priorMessages,
            systemPrompt: systemPrompt,
            newUserInput: userInput
        )
        let priorConversationSection = transcript.isEmpty
            ? ""
            : """

        Prior conversation context:
        \(transcript)
        """
        let instructions = Self.promptInstructions(for: skill)
        let examples = skill.skillType == .jsBacked ? Self.skillExamplesText(from: skill.instructions) : ""
        let examplesSection = examples.isEmpty
            ? ""
            : """

        Examples:
        \(examples)
        """

        return """
        You are GreyVctr AI in Skills Chat.

        The app selected this skill for the latest user request.

        Skill name: \(skill.name)
        Skill type: \(Self.skillTypeDescription(skill.skillType))
        Description: \(skill.description)

        Skill instructions:
        \(instructions)

        \(examplesSection)
        \(priorConversationSection)

        Latest user request:
        \(userInput)

        Rules:
        - Use the prior conversation only as context.
        - Do not expose internal planning, tool tags, XML tags, or markdown code fences unless the skill explicitly requires them.
        - If this is a JavaScript-backed skill, output only one JSON object matching the skill's expected input.
        - If this is a text-only skill, output only the final user-facing answer.
        """
    }

    private static func skillChatPrompt(
        userInput: String,
        priorMessages: [ChatMessage],
        enabledSkills: [SkillDefinition],
        systemPrompt: String
    ) -> String {
        let transcript = skillTranscriptContext(
            priorMessages: priorMessages,
            systemPrompt: systemPrompt,
            newUserInput: userInput
        )
        let priorConversationSection = transcript.isEmpty
            ? "No prior conversation."
            : transcript
        let skillsList = enabledSkills.map { skill in
            """
            - Skill name: \(skill.name)
              Type: \(Self.skillTypeDescription(skill.skillType))
              Description: \(skill.description)
            """
        }.joined(separator: "\n")

        return """
        You are GreyVctr AI in Skills Chat.

        You can either answer normally or use one of the enabled skills.
        Use prior conversation context to understand follow-up questions.

        Enabled skills:
        \(skillsList)

        Prior conversation:
        \(priorConversationSection)

        Latest user request:
        \(userInput)

        Rules:
        - If no skill is needed, answer normally.
        - If a text-only skill is needed, use that skill's purpose and produce the final user-facing answer.
        - If a JavaScript-backed skill is needed, output the selected skill and one JSON object for its expected input:
          [Using skill: skill-name]
          {"data": <input JSON>}
        - Do not emit native LiteRT tool calls, XML-like tags, or hidden metadata.
        """
    }

    private static func skillTypeDescription(_ skillType: SkillType) -> String {
        switch skillType {
        case .jsBacked:
            return "JavaScript-backed"
        case .textOnly:
            return "Text-only"
        }
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



    private static func promptInstructions(for skill: SkillDefinition) -> String {
        switch skill.skillType {
        case .jsBacked:
            return skill.instructions
        case .textOnly:
            return compactTextSkillInstructions(from: skill.instructions)
        }
    }

    private static func compactTextSkillInstructions(from instructions: String) -> String {
        let lines = instructions.components(separatedBy: .newlines)
        let startIndex = lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("## instructions")
        } ?? lines.startIndex

        var collected: [String] = []
        for line in lines[startIndex...] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("## examples") { continue }
            if trimmed.isEmpty {
                if collected.last?.isEmpty != true {
                    collected.append("")
                }
                continue
            }
            collected.append(trimmed)
            if collected.joined(separator: "\n").count >= 1_600 {
                break
            }
        }

        let compact = collected.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? truncatedMiddle(instructions, maxCharacters: 1_600) : compact
    }

    private static func toolCallRepairPrompt(
        skill: SkillDefinition,
        userInput: String,
        rawResponse: String
    ) -> String {
        """
        The previous response exposed an internal tool-call instead of a user-facing answer.
        Do not emit tool calls, JSON, XML-like tags, or metadata.

        Use the "\(skill.name)" skill instructions already loaded in this conversation.

        Original user request:
        \(userInput)

        Internal draft to convert:
        \(rawResponse)

        Write the final answer only in mobile-friendly bullets and short sections.
        """
    }

    private static func skillTranscriptContext(
        priorMessages: [ChatMessage],
        systemPrompt: String,
        newUserInput: String
    ) -> String {
        let maxUserTurns = 3
        let maxModelCharacters = 900
        var lines: [String] = []
        var userTurns = 0
        var includedModelExcerpt = false

        for message in priorMessages.reversed() {
            switch message.role {
            case .user:
                guard userTurns < maxUserTurns else { continue }
                lines.insert("User: \(message.content)", at: 0)
                userTurns += 1
            case .model:
                guard !includedModelExcerpt else { continue }
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                let excerpt = Self.truncatedMiddle(
                    content,
                    maxCharacters: maxModelCharacters
                )
                lines.insert("Previous answer excerpt: \(excerpt)", at: 0)
                includedModelExcerpt = true
            case .system:
                continue
            }
        }

        return lines.joined(separator: "\n\n")
    }

    private static func truncatedMiddle(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let headCount = maxCharacters / 2
        let tailCount = maxCharacters - headCount
        return "\(text.prefix(headCount))\n[...]\n\(text.suffix(tailCount))"
    }

    /// Extracts JSON data from a LiteRT-LM tool call parser error message.
    /// The error contains the raw tool call text which includes the JSON payload.
    /// Handles Gemma 4's <|"|> escape tokens by replacing them with actual quotes.
    private static func extractJSONFromToolCallError(_ errorDescription: String) -> String? {
        // Look for JSON object in the error text
        // The error contains something like: call:run_js{data:<|"|>{"conversion": "mgrs_to_ll", ...}<tool_call|>
        // We need to extract the JSON between the first { after "data:" and the matching }

        // First, try to find the data payload
        guard let dataRange = errorDescription.range(of: "data:") else {
            // Try alternate format: look for any JSON object
            guard let jsonStart = errorDescription.firstIndex(of: "{"),
                  let jsonEnd = errorDescription.lastIndex(of: "}") else {
                return nil
            }
            let raw = String(errorDescription[jsonStart...jsonEnd])
            return raw.replacingOccurrences(of: "<|\"|>", with: "\"")
                .replacingOccurrences(of: "<|'|>", with: "'")
        }

        let afterData = errorDescription[dataRange.upperBound...]

        // Skip the <|"|> token that wraps the JSON string
        let cleaned = String(afterData)
            .replacingOccurrences(of: "<|\"|>", with: "\"")
            .replacingOccurrences(of: "<|'|>", with: "'")
            .replacingOccurrences(of: "<tool_call|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the JSON object
        guard let jsonStart = cleaned.firstIndex(of: "{") else { return nil }
        var depth = 0
        var jsonEnd: String.Index?
        for index in cleaned[jsonStart...].indices {
            if cleaned[index] == "{" { depth += 1 }
            if cleaned[index] == "}" {
                depth -= 1
                if depth == 0 {
                    jsonEnd = index
                    break
                }
            }
        }

        guard let end = jsonEnd else { return nil }
        let json = String(cleaned[jsonStart...end])

        // Validate it's parseable JSON
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return nil
        }

        return json
    }

    /// Infers the JS input JSON from the user's original message when the SDK
    /// parser fails and we can't extract data from the error message.
    /// This is a generic approach that works for grid-converter and risk-matrix.
    private static func inferJSInput(for skillName: String, from userInput: String) -> String? {
        let lowered = userInput.lowercased()

        switch skillName {
        case "grid-converter":
            // Detect MGRS coordinate
            let compact = userInput.uppercased()
                .replacingOccurrences(of: #"[^A-Z0-9]"#, with: "", options: .regularExpression)
            if let match = compact.firstMatch(of: /[0-9]{1,2}[C-HJ-NP-X][A-HJ-NP-Z]{2}[0-9]{2,10}/) {
                let mgrs = String(match.output)
                let conversion = lowered.contains("utm") ? "mgrs_to_utm" : "mgrs_to_ll"
                return "{\"conversion\": \"\(conversion)\", \"mgrs\": \"\(mgrs)\"}"
            }

            let hasLatLonHint = lowered.contains("lat") || lowered.contains("lon") || lowered.contains("long") || lowered.contains("latitude") || lowered.contains("longitude")
            let hasUtmHint = lowered.contains("utm")
            let hasConversionHint = lowered.contains("convert") || lowered.contains("what is") || lowered.contains("what's")

            // Detect lat/lon only when the prompt clearly looks like a coordinate conversion request.
            if hasLatLonHint || (hasConversionHint && lowered.contains("coordinate")) {
                let numbers = userInput.matches(of: /[-+]?\d+(?:\.\d+)?/)
                    .compactMap { Double($0.output) }
                if numbers.count >= 2 {
                    let lat = numbers[0]
                    let lon = numbers[1]
                    if (-90...90).contains(lat), (-180...180).contains(lon) {
                        let conversion = hasUtmHint ? "ll_to_utm" : "ll_to_mgrs"
                        return "{\"conversion\": \"\(conversion)\", \"lat\": \(lat), \"lon\": \(lon)}"
                    }
                }
            }

            // Detect UTM only when the prompt explicitly mentions UTM and provides the required components.
            if hasUtmHint {
                let numbers = userInput.matches(of: /[-+]?\d+(?:\.\d+)?/)
                    .compactMap { Double($0.output) }
                if numbers.count >= 3,
                   lowered.contains("zone"),
                   lowered.contains("easting"),
                   lowered.contains("northing") {
                    let zoneNumber = Int(numbers[0])
                    let easting = numbers[1]
                    let northing = numbers[2]
                    let zoneLetter = userInput.firstMatch(of: /[A-HJ-NP-Z]/).map { String($0.output) } ?? "N"
                    let conversion = lowered.contains("to mgrs") ? "utm_to_mgrs" : "utm_to_ll"
                    return "{\"conversion\": \"\(conversion)\", \"zoneNumber\": \(zoneNumber), \"zoneLetter\": \"\(zoneLetter)\", \"easting\": \(easting), \"northing\": \(northing)}"
                }
            }
            return nil

        default:
            return nil
        }
    }

    /// Detects if the model's response indicates it wants to use a specific skill.
    /// Looks for skill name mentions alongside tool-call patterns.
    private static func detectSkillSelection(from response: String, enabledSkills: [SkillDefinition]) -> SkillDefinition? {
        let lowered = response.lowercased()

        // Check for any skill name mentioned in the response
        for skill in enabledSkills {
            let nameVariants = [
                skill.name.lowercased(),
                skill.name.lowercased().replacingOccurrences(of: "-", with: " "),
                skill.id.lowercased().replacingOccurrences(of: "-", with: " ")
            ]

            for variant in nameVariants {
                guard lowered.contains(variant) else { continue }

                // Skill name is mentioned — check if it's in a tool-call context
                if lowered.contains("load_skill") ||
                   lowered.contains("run_js") ||
                   lowered.contains("tool_name") ||
                   lowered.contains("tool_call") ||
                   lowered.contains("call:") ||
                   lowered.contains("using skill") ||
                   lowered.contains("most relevant skill") ||
                   lowered.contains("skill is") {
                    return skill
                }
            }
        }

        return nil
    }

    /// Detects the target JS-backed skill from a parsed tool-call JSON or the response header.
    ///
    /// Strategy:
    /// 1. Parse `json` and look for `tool_name`, `name`, or `skill_name` fields.
    /// 2. Match the extracted name against enabled JS-backed skills (case-insensitive, dash/space normalized).
    /// 3. If no JSON match, fall back to extracting the skill name from a `[Using skill: X]` header in `response`.
    /// 4. Returns `nil` when no JS-backed skill matches (text-only skills, no-match cases).
    static func detectSkillNameFromToolCall(
        json: String,
        response: String,
        enabledSkills: [SkillDefinition]
    ) -> SkillDefinition? {
        let jsSkills = enabledSkills.filter { $0.skillType == .jsBacked }
        guard !jsSkills.isEmpty else { return nil }

        // --- Step 1: Try to extract a skill/tool name from the JSON ---
        if let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let candidateKeys = ["tool_name", "name", "skill_name"]
            for key in candidateKeys {
                if let value = object[key] as? String, !value.isEmpty {
                    if let match = matchSkill(name: value, in: jsSkills) {
                        return match
                    }
                }
            }
        }

        // --- Step 2: Fall back to [Using skill: X] header in the response ---
        if let headerName = extractUsingSkillHeader(from: response) {
            if let match = matchSkill(name: headerName, in: jsSkills) {
                return match
            }
        }

        return nil
    }

    // MARK: - detectSkillNameFromToolCall Helpers

    /// Matches a candidate name against JS-backed skills using case-insensitive, dash/space-normalized comparison.
    private static func matchSkill(name: String, in skills: [SkillDefinition]) -> SkillDefinition? {
        let normalized = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for skill in skills {
            let skillNameNormalized = skill.name.lowercased()
            let skillIdNormalized = skill.id.lowercased()

            // Direct match on name or id
            if normalized == skillNameNormalized || normalized == skillIdNormalized {
                return skill
            }

            // Dash/space normalized match
            let dashNormalized = normalized.replacingOccurrences(of: " ", with: "-")
            let spaceNormalized = normalized.replacingOccurrences(of: "-", with: " ")

            if dashNormalized == skillNameNormalized || dashNormalized == skillIdNormalized {
                return skill
            }
            if spaceNormalized == skillNameNormalized || spaceNormalized == skillIdNormalized {
                return skill
            }

            // Also try normalizing the skill name/id with the same transforms
            let skillNameDash = skillNameNormalized.replacingOccurrences(of: " ", with: "-")
            let skillNameSpace = skillNameNormalized.replacingOccurrences(of: "-", with: " ")
            if normalized == skillNameDash || normalized == skillNameSpace {
                return skill
            }
        }

        return nil
    }

    /// Extracts the skill name from a `[Using skill: X]` header line in the response.
    private static func extractUsingSkillHeader(from response: String) -> String? {
        let lines = response.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Match both "[Using skill: X]" and "[Using Skill: X]"
            let prefixes = ["[Using skill:", "[Using Skill:"]
            for prefix in prefixes {
                if trimmed.hasPrefix(prefix), trimmed.hasSuffix("]") {
                    let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
                    let end = trimmed.index(before: trimmed.endIndex)
                    let name = String(trimmed[start..<end])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        return name
                    }
                }
            }
        }
        return nil
    }

    /// Detects a text skill from the [Using skill: X] header in the response.
    /// Unlike `detectSkillNameFromToolCall` which only matches JS-backed skills,
    /// this matches ANY skill type (primarily text skills).
    private static func detectTextSkillFromResponse(response: String, enabledSkills: [SkillDefinition]) -> SkillDefinition? {
        guard let headerName = extractUsingSkillHeader(from: response) else { return nil }
        let normalized = headerName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return enabledSkills.first { skill in
            skill.name.lowercased() == normalized ||
            skill.id.lowercased() == normalized ||
            skill.name.lowercased().replacingOccurrences(of: "-", with: " ") == normalized ||
            normalized.replacingOccurrences(of: " ", with: "-") == skill.name.lowercased()
        }
    }

    /// Extracts human-readable text from a JSON string produced by a text skill.
    /// Text skills may wrap their output in JSON with keys like "notes", "text", "content", "response", etc.
    private static func extractTextFromJSON(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            // Not valid JSON — return the raw string as text
            return json
        }

        if let dict = object as? [String: Any] {
            // Look for common text content keys
            let textKeys = ["notes", "text", "content", "response", "output", "result", "answer", "mobileText"]
            for key in textKeys {
                if let value = dict[key] as? String, !value.isEmpty {
                    return value
                }
            }
            // If there's only one string value, use it
            let stringValues = dict.values.compactMap { $0 as? String }.filter { !$0.isEmpty }
            if stringValues.count == 1 {
                return stringValues[0]
            }
            // Fall back to pretty-printing the JSON
            if let prettyData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                return prettyString
            }
        }

        if let stringValue = object as? String {
            return stringValue
        }

        return json
    }

    // MARK: - extractRunJSData Helper

    /// Extracts the `data` payload from various JSON formats the model may emit for JS skill execution.
    ///
    /// Supported formats (checked in order):
    /// 1. `{"tool_args": {"data": ...}}` — Gemma tool call format from `ToolCallMetadataParser.normalizeGemmaToolCall`
    /// 2. `{"args": {"data": ...}}`
    /// 3. `{"data": ...}` — direct format from system prompt instructions
    /// 4. Falls back to returning the entire JSON string as-is (lets the JS runtime try parsing it directly)
    ///
    /// - Parameter json: The JSON string extracted by `ToolCallMetadataParser`.
    /// - Returns: The extracted data payload serialized as a JSON string, or `nil` for non-JSON input.
    static func extractRunJSData(from json: String) -> String? {
        guard let jsonData = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) else {
            return nil
        }

        guard let topLevel = parsed as? [String: Any] else {
            // Valid JSON but not a dictionary — return the entire JSON as-is
            return json
        }

        // 1. {"tool_args": {"data": ...}}
        if let toolArgs = topLevel["tool_args"] as? [String: Any],
           let dataValue = toolArgs["data"] {
            return serializeValue(dataValue)
        }

        // 2. {"args": {"data": ...}}
        if let args = topLevel["args"] as? [String: Any],
           let dataValue = args["data"] {
            return serializeValue(dataValue)
        }

        // 3. {"data": ...}
        if let dataValue = topLevel["data"] {
            return serializeValue(dataValue)
        }

        // 4. No `data` field found — return the entire JSON as-is for the JS runtime
        return json
    }

    /// Serializes a JSON value back to a string representation.
    /// Handles dictionaries, arrays, strings, numbers, booleans, and null.
    /// For strings that look like JSON (double-encoded), validates and returns them directly.
    /// If the string is malformed JSON, attempts basic repair (closing brackets/braces).
    private static func serializeValue(_ value: Any) -> String? {
        if let stringValue = value as? String {
            // If the string itself looks like JSON (double-encoded by the model),
            // validate it and return directly if valid.
            if stringValue.hasPrefix("{") || stringValue.hasPrefix("[") {
                // Try to parse — if valid, return as-is
                if let data = stringValue.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    return stringValue
                }
                // Malformed JSON string — attempt basic repair
                if let repaired = repairTruncatedJSON(stringValue) {
                    return repaired
                }
                // Can't repair — return as-is and let the JS runtime try
                return stringValue
            }
            // Otherwise wrap it as a JSON string
            if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
               let arrayStr = String(data: data, encoding: .utf8) {
                // Strip the surrounding [ and ]
                let trimmed = arrayStr.dropFirst().dropLast()
                return String(trimmed)
            }
            return "\"\(value)\""
        }

        if JSONSerialization.isValidJSONObject(value) {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }

        // For primitives (numbers, booleans) that aren't valid top-level JSON objects
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let arrayStr = String(data: data, encoding: .utf8) {
            // Strip the surrounding [ and ]
            let trimmed = arrayStr.dropFirst().dropLast()
            return String(trimmed)
        }

        return nil
    }

    /// Attempts to repair truncated JSON by closing unclosed brackets and braces.
    /// The model sometimes generates JSON that's cut off mid-stream due to token limits.
    /// This repairs common patterns: missing `]`, `}`, or combinations thereof.
    private static func repairTruncatedJSON(_ json: String) -> String? {
        var repaired = json.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing comma if present (common truncation artifact)
        while repaired.hasSuffix(",") {
            repaired = String(repaired.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove trailing colon (truncated mid-key-value)
        if repaired.hasSuffix(":") {
            repaired = String(repaired.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if repaired.hasSuffix("\"") {
                if let quoteRange = repaired.dropLast().range(of: "\"", options: .backwards) {
                    repaired = String(repaired[..<quoteRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if repaired.hasSuffix(",") {
                        repaired = String(repaired.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }

        // Count unclosed brackets and braces
        var braceDepth = 0
        var bracketDepth = 0
        var inString = false
        var escaped = false

        for char in repaired {
            if escaped { escaped = false; continue }
            if char == "\\" && inString { escaped = true; continue }
            if char == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            switch char {
            case "{": braceDepth += 1
            case "}": braceDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            default: break
            }
        }

        // Close any unclosed strings
        if inString {
            repaired += "\""
        }

        // Append missing closing brackets/braces
        for _ in 0..<max(0, bracketDepth) {
            repaired += "]"
        }
        for _ in 0..<max(0, braceDepth) {
            repaired += "}"
        }

        // Validate the repaired JSON
        guard let data = repaired.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return nil
        }

        return repaired
    }

    /// Formats a JS execution result into a user-friendly string.
    static func formatJSResult(_ outputJSON: String, skillName: String, userInput: String) -> String {
        guard let data = outputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return outputJSON
        }

        if let error = dict["error"] {
            return "The \(skillName) skill could not complete: \(error)"
        }

        let result = dict["result"]

        if let resultDict = result as? [String: Any] {
            if let mobileText = resultDict["mobileText"] as? String {
                return mobileText
            }

            if let lat = resultDict["lat"] as? NSNumber,
               let lon = resultDict["lon"] as? NSNumber {
                return "Latitude: \(String(format: "%.6f", lat.doubleValue))\nLongitude: \(String(format: "%.6f", lon.doubleValue))"
            }

            if let mgrs = resultDict["mgrs"] as? String {
                return "MGRS: \(mgrs)"
            }

            if let zoneNumber = resultDict["zoneNumber"],
               let zoneLetter = resultDict["zoneLetter"],
               let easting = resultDict["easting"],
               let northing = resultDict["northing"] {
                return "UTM Zone: \(zoneNumber)\(zoneLetter)\nEasting: \(easting)\nNorthing: \(northing)"
            }
        }

        if let result {
            return "\(result)"
        }

        return outputJSON
    }

    @MainActor
    private func updateModelMessage(
        id: UUID,
        content: String,
        isStreaming: Bool,
        toolCallSkillName: String? = nil,
        toolCallData: String? = nil
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = ChatMessage(
            id: id,
            role: .model,
            content: content,
            timestamp: messages[index].timestamp,
            isStreaming: isStreaming,
            toolCallSkillName: toolCallSkillName,
            toolCallData: toolCallData
        )
    }

    @MainActor
    private func removeEmptyPlaceholder(id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }),
           messages[index].content.isEmpty {
            messages.remove(at: index)
        }
    }

    private static func selectSkill(
        for prompt: String,
        enabledSkills: [SkillDefinition]
    ) -> SkillDefinition? {
        guard !enabledSkills.isEmpty else { return nil }

        let promptTokens = Self.routingTokens(for: prompt)
        let promptNormalized = Self.normalizedRoutingText(prompt)

        var scored: [(skill: SkillDefinition, score: Int)] = enabledSkills.map { skill in
            (skill, Self.routingScore(
                skill: skill,
                promptTokens: promptTokens,
                promptNormalized: promptNormalized,
            ))
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.skill.name.localizedCaseInsensitiveCompare(rhs.skill.name) == .orderedAscending
            }
            return lhs.score > rhs.score
        }

        guard let best = scored.first, best.score > 0 else { return nil }
        if let second = scored.dropFirst().first,
           best.score < 4,
           best.score <= second.score + 1 {
            return nil
        }

        return best.skill
    }

    private static func isSkillCatalogRequest(_ prompt: String) -> Bool {
        let normalized = normalizedRoutingText(prompt)

        return [
            "what skills",
            "which skills",
            "list skills",
            "show skills",
            "show me skills",
            "available skills",
            "skills available",
            "skills do you",
            "skills can you",
            "skills you have",
            "skills have access",
            "what can you do",
            "what are you able to do",
            "what do you have access to",
            "what capabilities",
            "which capabilities",
            "list capabilities",
            "available capabilities"
        ].contains { normalized.contains($0) }
    }

    private static func skillCatalogResponse(enabledSkills: [SkillDefinition]) -> String {
        guard !enabledSkills.isEmpty else {
            return "No skills are currently enabled."
        }

        let skillsList = enabledSkills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { skill in
                let typeLabel = skill.skillType == .jsBacked ? "JS-backed" : "Text"
                return "- **\(skill.name)** (\(typeLabel)): \(skill.description)"
            }
            .joined(separator: "\n")

        return """
        I have access to these enabled skills:

        \(skillsList)
        """
    }

    private static func routingScore(
        skill: SkillDefinition,
        promptTokens: Set<String>,
        promptNormalized: String
    ) -> Int {
        var score = 0
        let routeText = routingCorpus(for: skill)
        let nameTokens = routingTokens(for: skill.name)
        let descriptionTokens = routingTokens(for: skill.description)
        let routeTokens = routingTokens(for: routeText)

        if !skill.name.isEmpty, promptNormalized.contains(normalizedRoutingText(skill.name)) {
            score += 24
        }
        if !skill.id.isEmpty, promptNormalized.contains(normalizedRoutingText(skill.id)) {
            score += 18
        }

        score += 6 * overlapCount(promptTokens, nameTokens)
        score += 4 * overlapCount(promptTokens, descriptionTokens)
        score += 2 * overlapCount(promptTokens, routeTokens)

        return score
    }

    private static func overlapCount(_ lhs: Set<String>, _ rhs: Set<String>) -> Int {
        lhs.intersection(rhs).count
    }

    private static func routingTokens(for text: String) -> Set<String> {
        let lower = text.lowercased()
        let candidates = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let stopwords: Set<String> = [
            "a", "an", "and", "the", "to", "for", "of", "in", "on", "with", "from", "by", "at", "as", "is",
            "are", "be", "become", "this", "that", "these", "those", "it", "its", "your", "you", "use", "using",
            "do", "not", "no", "or", "if", "when", "then", "than", "into", "out", "up", "down", "over", "under",
            "skill", "skills", "assistant", "answer", "help", "draft", "update"
        ]
        return Set(candidates.compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if stopwords.contains(trimmed) { return nil }
            if trimmed.count == 1, trimmed.rangeOfCharacter(from: .decimalDigits) == nil {
                return nil
            }
            return trimmed
        })
    }

    private static func normalizedRoutingText(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
    }

    private static func routingCorpus(for skill: SkillDefinition) -> String {
        let examples = skillExamplesText(from: skill.instructions)
        if examples.isEmpty {
            return "\(skill.name) \(skill.description)"
        }
        return "\(skill.name) \(skill.description) \(examples)"
    }

    private static func skillExamplesText(from instructions: String) -> String {
        let lines = instructions.components(separatedBy: .newlines)
        guard let examplesIndex = lines.firstIndex(where: { line in
            let lowered = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered.hasPrefix("## examples") || lowered.hasPrefix("### examples") || lowered == "# examples"
        }) else {
            return ""
        }

        var collected: [String] = []
        for line in lines[lines.index(after: examplesIndex)...] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") && !trimmed.hasPrefix("-") && !trimmed.hasPrefix(">") {
                break
            }
            if !trimmed.isEmpty {
                collected.append(trimmed)
            }
            if collected.joined(separator: " ").count >= 800 {
                break
            }
        }

        return collected.joined(separator: " ")
    }

    private static func buildSkillsSystemPrompt(
        selectedSkill: SkillDefinition?,
        basePrompt: String
    ) -> String {
        let base = basePrompt
            .replacingOccurrences(of: "___SKILLS___", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let skill = selectedSkill else {
            if !base.isEmpty { return base }
            return """
            You are GreyVctr AI, an on-device AI assistant.
            Return clear, direct answers and do not emit internal tool metadata.
            """
        }

        let skillPrompt: String
        switch skill.skillType {
        case .jsBacked:
            skillPrompt = """
            You are executing the skill "\(skill.name)".
            Follow the skill instructions below and produce only a tool-call payload when you need the skill's JSON input.
            Do not answer the user directly if the skill requires JavaScript execution.

            Skill instructions:
            \(skill.instructions)

            Output format for JS skills:
            [Using skill: \(skill.name)]
            ```json
            {"data": <input JSON matching the skill's expected parameters>}
            ```
            """
        case .textOnly:
            skillPrompt = """
            You are executing the skill "\(skill.name)".
            Follow the skill instructions below and return only the final user-facing answer.
            Do not emit JSON, tool calls, or internal metadata unless the skill instructions explicitly require it.

            Skill instructions:
            \(promptInstructions(for: skill))
            """
        }

        if base.isEmpty {
            return skillPrompt
        }

        return """
        \(base)

        --- ACTIVE SKILL ---
        \(skillPrompt)
        """
    }

    private static func buildSystemPrompt(enabledSkills: [SkillDefinition], config: InferenceConfig) -> String {
        let skillsList = enabledSkills
            .map { "- Skill name: \"\($0.name)\"\n- Description: \($0.description)" }
            .joined(separator: "\n\n")

        if config.systemPrompt.contains("___SKILLS___") {
            return config.systemPrompt.replacingOccurrences(of: "___SKILLS___", with: skillsList)
        }

        if !config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return """
            \(config.systemPrompt)

            --- SKILLS ---
            \(skillsList)
            """
        }

        return """
        You are GreyVctr AI, an on-device AI assistant for the National Guard.

        --- SKILLS ---
        \(skillsList)

        Use the appropriate skill when the user's request matches. Follow the skill's output format and guardrails. If no skill matches, respond as a helpful general assistant.
        """
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
