import LiteRTLM
import Foundation
import OSLog

/// Errors thrown by `SessionCoordinator` during conversation lifecycle management.
enum SessionCoordinatorError: LocalizedError {
    case conversationNotAlive

    var errorDescription: String? {
        switch self {
        case .conversationNotAlive:
            return "Session lost. Tap Reload Engine to recover."
        }
    }
}

/// Ensures only one Conversation exists at a time across all app modes.
/// Manages conversation creation, release, and ownership tracking.
actor SessionCoordinator {

    /// The mode that can own the active conversation.
    enum Mode: String, Hashable, Sendable {
        case aiChat
        case skillsChat
        case askImage
    }

    private let logger = Logger(
        subsystem: "com.guardai.app",
        category: "SessionCoordinator"
    )

    private let engine: Engine
    private var activeConversation: Conversation?
    private var activeMode: Mode?
    private var activeConfigSignature: String?
    private var activeInferenceCount = 0
    private var releasePendingAfterInference = false
    private let activeInferenceDrainTimeoutNanoseconds: UInt64 = 3_000_000_000
    private let activeInferenceDrainPollNanoseconds: UInt64 = 50_000_000

    init(engine: Engine) {
        self.engine = engine
    }

    /// Acquires a new conversation for the given mode.
    /// Releases any existing conversation from another mode first.
    ///
    /// - Parameters:
    ///   - mode: The mode requesting the conversation.
    ///   - config: The configuration for the new conversation.
    ///   - configSignature: A stable signature of the effective prompt and generation settings.
    /// - Returns: A `Conversation` instance for the given mode.
    func acquireConversation(
        for mode: Mode,
        config: ConversationConfig,
        configSignature: String? = nil,
        forceNew: Bool = false
    ) async throws -> Conversation {
        let currentMode = self.activeMode?.rawValue ?? "nil"
        let hasConversation = self.activeConversation != nil
        logger.info(
            "acquireConversation entry mode=\(mode.rawValue) activeMode=\(currentMode) activeInference=\(self.activeInferenceCount) hasConversation=\(hasConversation) forceNew=\(forceNew)"
        )

        if releasePendingAfterInference, activeInferenceCount == 0 {
            logger.info("acquireConversation releasing pending conversation before reuse/create")
            releaseCurrentConversation()
        }

        if !forceNew,
           activeMode == mode,
           let existing = activeConversation,
           existing.isAlive,
           configSignature == nil || activeConfigSignature == configSignature {
            activeMode = mode
            logger.info("Reusing existing conversation for \(mode.rawValue)")
            return existing
        }

        if activeConversation != nil, activeInferenceCount > 0 {
            logger.info("Waiting for active inference before acquiring conversation for \(mode.rawValue)")
            try? cancelIfActive()
            releasePendingAfterInference = true
            try await waitForActiveInferenceToDrain()
        }

        // LiteRT-LM currently supports one live conversation for this engine in practice.
        // Drop the previous mode's prompt/context before creating a conversation for this mode.
        if activeConversation != nil {
            if activeMode == mode {
                if forceNew {
                    logger.info("Recreating conversation for \(mode.rawValue) for a fresh turn")
                } else {
                    logger.info("Recreating conversation for \(mode.rawValue) because configuration changed")
                }
            } else {
                logger.info("Switching conversation from \(self.activeMode?.rawValue ?? "nil") to \(mode.rawValue)")
            }
        }
        let hadPreviousConversation = activeConversation != nil
        logger.info("acquireConversation releasing current conversation; hadPrevious=\(hadPreviousConversation)")
        releaseCurrentConversation()

        // Brief pause to allow C++ engine resources to fully tear down
        // before creating a new conversation. Without this, createConversation
        // can fail with "A session already exists" on iOS devices.
        // Always sleep when forceNew is true — the engine may still be cleaning up
        // a session released at the end of the previous turn.
        if hadPreviousConversation || forceNew {
            logger.info("acquireConversation sleeping before createConversation")
            try await Task.sleep(nanoseconds: 600_000_000)
        }

        // Try to create conversation, retry with backoff if the engine reports
        // "session already exists" (common after cancel — the C++ session cleanup
        // is asynchronous and may not have completed yet).
        var conversation: Conversation!
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                if attempt == 0 {
                    logger.info("acquireConversation calling engine.createConversation")
                } else {
                    logger.info("acquireConversation retry #\(attempt) engine.createConversation")
                }
                conversation = try await engine.createConversation(with: config)
                logger.info("acquireConversation engine.createConversation returned")
                lastError = nil
                break
            } catch {
                lastError = error
                let desc = "\(error)"
                let localized = error.localizedDescription
                if desc.contains("session already exists")
                    || desc.contains("Failed to create")
                    || desc.contains("FAILED_PRECONDITION")
                    || localized.contains("session already exists")
                    || localized.contains("Failed to create")
                    || localized.contains("FAILED_PRECONDITION") {
                    // Engine still cleaning up — wait and retry
                    let backoff: UInt64 = UInt64(attempt + 1) * 800_000_000 // 800ms, 1600ms, 2400ms
                    logger.warning("createConversation attempt \(attempt) failed (session exists). Waiting \((attempt + 1) * 800)ms... desc=\(localized)")
                    try await Task.sleep(nanoseconds: backoff)
                    continue
                } else {
                    // Non-retryable error
                    logger.error("createConversation non-retryable error: \(localized)")
                    throw error
                }
            }
        }
        if let lastError {
            logger.error("All createConversation attempts failed")
            throw lastError
        }

        // Validate liveness after creation; retry once if the conversation is not alive
        if !conversation.isAlive {
            logger.warning("Conversation created but not alive. Retrying creation once...")
            try await Task.sleep(nanoseconds: 500_000_000)
            conversation = try await engine.createConversation(with: config)
            if !conversation.isAlive {
                logger.error("Conversation still not alive after retry")
                throw SessionCoordinatorError.conversationNotAlive
            }
        }

        logger.info("acquireConversation assigning activeConversation")
        activeConversation = conversation
        logger.info("acquireConversation assigned activeConversation")
        activeMode = mode
        activeConfigSignature = configSignature
        logger.info("Created conversation for \(mode.rawValue)")
        return conversation
    }

    /// Releases the conversation for the given mode.
    /// No-op if the mode doesn't own the active conversation.
    ///
    /// - Parameter mode: The mode requesting release.
    func releaseConversation(for mode: Mode) {
        guard activeMode == mode else { return }
        guard activeInferenceCount == 0 else {
            releasePendingAfterInference = true
            logger.info("Deferring release for \(mode.rawValue) until active inference ends")
            return
        }
        logger.info("Releasing conversation for \(mode.rawValue)")
        releaseCurrentConversation()
    }

    /// Releases any active conversation, deferring until the active stream unwinds if needed.
    /// Used during background transitions.
    func releaseWhenIdle() {
        if let mode = activeMode {
            logger.info("Releasing conversation from \(mode.rawValue) when idle")
        }

        guard activeInferenceCount == 0 else {
            releasePendingAfterInference = true
            return
        }

        releaseCurrentConversation()
    }

    /// Force-releases any active conversation regardless of inference state.
    /// Used for explicit engine reloads, model updates, and error recovery.
    func forceRelease() {
        if let mode = activeMode {
            logger.info("Force-releasing conversation from \(mode.rawValue)")
        }
        releaseCurrentConversation()
    }

    /// Returns the active conversation if owned by the given mode.
    ///
    /// - Parameter mode: The mode to check ownership for.
    /// - Returns: The active `Conversation` if the mode owns it, otherwise `nil`.
    func activeConversation(for mode: Mode) -> Conversation? {
        guard activeMode == mode else { return nil }
        return activeConversation
    }

    /// Returns whether the current conversation can be reused for a mode/config pair.
    func canReuseConversation(for mode: Mode, configSignature: String? = nil) -> Bool {
        logger.info(
            "canReuseConversation entry mode=\(mode.rawValue) activeMode=\(self.activeMode?.rawValue ?? "nil") activeInference=\(self.activeInferenceCount) hasConversation=\(self.activeConversation != nil)"
        )
        guard activeMode == mode,
              let conversation = activeConversation,
              conversation.isAlive else {
            logger.info("canReuseConversation returning false for \(mode.rawValue)")
            return false
        }

        let result = configSignature == nil || activeConfigSignature == configSignature
        logger.info("canReuseConversation returning \(result, privacy: .public) for \(mode.rawValue)")
        return result
    }

    /// Cancels in-progress inference on the active conversation.
    /// No-op if there is no active conversation.
    func cancelIfActive() throws {
        guard let mode = activeMode, let conversation = activeConversation else { return }
        try conversation.cancel()
        logger.info("Cancelled active conversation for \(mode.rawValue)")
    }

    /// Marks the start of a model response stream.
    func beginInference() {
        activeInferenceCount += 1
        logger.info("Begin inference; active count \(self.activeInferenceCount)")
    }

    /// Marks the end of a model response stream.
    func endInference() {
        activeInferenceCount = max(0, activeInferenceCount - 1)
        logger.info("End inference; active count \(self.activeInferenceCount)")
        if activeInferenceCount == 0, releasePendingAfterInference {
            logger.info("Running deferred conversation release")
            releaseCurrentConversation()
        }
    }

    /// Returns whether model inference is currently running.
    func hasActiveInference() -> Bool {
        activeInferenceCount > 0
    }

    /// Validates the current foreground-resumable conversation, if one exists.
    ///
    /// - Returns: `nil` when there is no active conversation to validate,
    ///   otherwise whether the native conversation still reports alive.
    func activeConversationIsAlive() -> Bool? {
        guard let conversation = activeConversation else {
            logger.info("Foreground health check skipped; no active conversation")
            return nil
        }

        let isAlive = conversation.isAlive
        logger.info("Foreground health check active conversation alive=\(isAlive, privacy: .public)")
        return isAlive
    }

    // MARK: - Private

    private func releaseCurrentConversation() {
        // Nil the conversation synchronously on the actor so the engine's internal
        // session tracking is updated immediately. The C++ destructor
        // (litert_lm_conversation_delete → ThreadPool::WaitUntilDone) runs here
        // on the cooperative thread pool — NOT the main thread — so it won't
        // cause a 0x8BADF00D kill. The actor is blocked until teardown completes,
        // but that's fine because acquireConversation awaits on this actor anyway.
        activeConversation = nil
        activeMode = nil
        activeConfigSignature = nil
        activeInferenceCount = 0
        releasePendingAfterInference = false
    }

    private func waitForActiveInferenceToDrain() async throws {
        var waitedNanoseconds: UInt64 = 0
        while activeInferenceCount > 0, waitedNanoseconds < activeInferenceDrainTimeoutNanoseconds {
            try await Task.sleep(nanoseconds: activeInferenceDrainPollNanoseconds)
            waitedNanoseconds += activeInferenceDrainPollNanoseconds
        }

        if activeInferenceCount > 0 {
            logger.warning("Timed out waiting for active inference to drain; forcing release")
            releaseCurrentConversation()
        }
    }
}
