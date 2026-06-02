import LiteRTLM
import Foundation
import SwiftData
import os

/// Central dependency container holding all app-level services.
///
/// Created once at app launch (after the engine is loaded) and injected into
/// the SwiftUI view hierarchy via `@Environment`. Views and view models can
/// access shared services through this container.
///
/// Usage:
/// ```swift
/// @Environment(AppDependencies.self) private var dependencies
/// ```
@Observable
final class AppDependencies {

    // MARK: - Services

    /// The official SDK Engine actor for on-device inference.
    let engine: Engine

    /// KV cache size used to initialize the current engine.
    let kvCacheSize: Int

    /// Coordinates conversation lifecycle across app modes (single active conversation).
    let sessionCoordinator: SessionCoordinator

    /// Loads inference configuration from the bundled JSON file.
    let configLoader: InferenceConfigLoaderProtocol

    /// Parses SKILL.md files from the app bundle.
    let skillParser: SkillParserProtocol

    /// Executes JavaScript companion scripts for JS-backed skills.
    let jsRuntime: JSRuntimeProtocol

    /// Manages persistence of generated output history entries.
    let historyStore: HistoryStoreProtocol

    /// Persists visible chat transcripts between launches.
    let conversationStore: ConversationStoreProtocol

    // MARK: - Init

    /// Creates the dependency container with all services wired together.
    ///
    /// - Parameters:
    ///   - engine: An initialized `Engine` actor instance.
    ///   - modelContext: The SwiftData model context for history persistence.
    init(engine: Engine, kvCacheSize: Int, modelContainer: ModelContainer) {
        self.engine = engine
        self.kvCacheSize = kvCacheSize
        self.sessionCoordinator = SessionCoordinator(engine: engine)

        let configLoader = InferenceConfigLoader()
        self.configLoader = configLoader

        let skillParser = SkillParser()
        self.skillParser = skillParser

        let jsRuntime = JSRuntime()
        self.jsRuntime = jsRuntime

        let historyStore = HistoryStore(modelContainer: modelContainer)
        self.historyStore = historyStore

        self.conversationStore = ConversationStore()
    }
}
