import LiteRTLM
import Foundation
import SwiftUI
import SwiftData
import os

/// GreyVctr AI — On-device AI skills for the National Guard.
/// Runs entirely offline using LiteRT-LM for local LLM inference.
@main
struct GreyVctrAIApp: App {

    #if canImport(UIKit) && !os(watchOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    /// The SwiftData model container for history persistence.
    private let modelContainer: ModelContainer

    /// Shared app state for engine loading status and model download.
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GreyVctr AI",
        category: "AppLifecycle"
    )

    init() {
        let container: ModelContainer
        do {
            let storeURL = try Self.historyStoreURL()
            let configuration = ModelConfiguration(url: storeURL)
            container = try ModelContainer(for: HistoryEntry.self, configurations: configuration)
        } catch {
            Self.logger.error("Failed to create ModelContainer: \(error.localizedDescription)")
            fatalError("Failed to create ModelContainer: \(error.localizedDescription)")
        }
        self.modelContainer = container
    }

    private static func historyStoreURL() throws -> URL {
        let applicationSupportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )

        return applicationSupportDirectory.appending(path: "default.store")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch appState.launchPhase {
                case .checkingModel:
                    ProgressView("Checking model…")
                        .task { await checkModelStatus() }

                case .needsDownload:
                    ModelDownloadView(downloader: appState.downloader) {
                        appState.launchPhase = .loadingEngine
                    }

                case .loadingEngine:
                    EngineLoadingOverlay()
                        .task {
                            guard scenePhase == .active else { return }
                            await loadEngine()
                        }

                case .ready:
                    MainTabView()
                        .environment(appState)
                }
            }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await handleBecameActive() }
            default:
                break
            }
        }
        .onChange(of: appState.engineReloadRequestID) { _, _ in
            Task { await reloadEngine() }
        }
    }

    // MARK: - Lifecycle

    @MainActor
    private func checkModelStatus() async {
        if appState.downloader.isDownloaded {
            Self.logger.info("Model already downloaded — loading engine")
            appState.launchPhase = .loadingEngine
        } else {
            Self.logger.info("Model not downloaded — showing download view")
            appState.launchPhase = .needsDownload
        }
    }

    @MainActor
    private func loadEngine() async {
        guard appState.launchPhase == .loadingEngine else { return }
        guard appState.engineStatus != .loading else { return }

        appState.engineStatus = .loading
        appState.engineBackend = nil
        appState.engineBackendFallbackReason = nil
        appState.activeEngineBackendPreference = nil

        do {
            let modelPath = appState.downloader.modelPath.path
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.path

            // Use the configured KV cache to support multi-turn conversations with skill instructions.
            // Changes take effect on the next engine load.
            let kvCacheSize = appState.userSettings.kvCacheSize
            let backendPreference = appState.userSettings.engineBackendPreference

            let engine: Engine
            let backend: EngineBackend

            // Experimental flags are silently ignored unless we opt in first.
            // Every ExperimentalFlags setter is guarded by `optedIn`; without this
            // call, the assignments below (including speculative decoding) are no-ops.
            // Idempotent, so safe to call on every engine (re)load.
            ExperimentalFlags.optIntoExperimentalAPIs()

            // Enable Multi-Token Prediction for faster decode on GPU.
            // Read when the Engine is created below.
            ExperimentalFlags.enableSpeculativeDecoding = true

            // Force well-formed tool-call output from Gemma 4. Without constrained
            // decoding the model can drop the closing `<|"|>` token when a tool
            // parameter contains JSON-as-a-string, which breaks tool-call parsing
            // (LiteRT-LM issue #2418). Read when each Conversation is created.
            ExperimentalFlags.enableConversationConstrainedDecoding = true

            #if targetEnvironment(simulator)
            Self.logger.info("Simulator detected; loading CPU backend")
            let cpuConfig = try EngineConfig(
                modelPath: modelPath,
                backend: .cpu(),
                visionBackend: .cpu(),
                maxNumTokens: kvCacheSize,
                cacheDir: cacheDir
            )
            let cpuEngine = Engine(engineConfig: cpuConfig)
            try await cpuEngine.initialize()
            engine = cpuEngine
            backend = .cpu
            if backendPreference != .cpu {
                appState.engineBackendFallbackReason = "Simulator uses CPU; GPU/Metal requires a physical device."
            }
            Self.logger.info("Engine loaded with CPU backend in Simulator")
            #else
            switch backendPreference {
            case .cpu:
                Self.logger.info("Loading user-selected CPU backend")
                let cpuConfig = try EngineConfig(
                    modelPath: modelPath,
                    backend: .cpu(),
                    visionBackend: .cpu(),
                    maxNumTokens: kvCacheSize,
                    cacheDir: cacheDir
                )
                let cpuEngine = Engine(engineConfig: cpuConfig)
                try await cpuEngine.initialize()
                engine = cpuEngine
                backend = .cpu
                Self.logger.info("Engine loaded with user-selected CPU backend")

            case .automatic, .gpu:
                // Tier 1: Full GPU (text + vision)
                do {
                    Self.logger.info("Trying Tier 1: GPU text + GPU vision")
                    let gpuConfig = try EngineConfig(
                        modelPath: modelPath,
                        backend: .gpu,
                        visionBackend: .gpu,
                        maxNumTokens: kvCacheSize,
                        cacheDir: cacheDir
                    )
                    let gpuEngine = Engine(engineConfig: gpuConfig)
                    try await gpuEngine.initialize()
                    engine = gpuEngine
                    backend = .gpu
                    Self.logger.info("Engine loaded with full GPU backend")
                } catch {
                    let tier1Reason = error.localizedDescription
                    Self.logger.error("Tier 1 (full GPU) failed: \(tier1Reason)")

                    // Tier 2: GPU text + CPU vision
                    do {
                        Self.logger.info("Trying Tier 2: GPU text + CPU vision")
                        let hybridConfig = try EngineConfig(
                            modelPath: modelPath,
                            backend: .gpu,
                            visionBackend: .cpu(),
                            maxNumTokens: kvCacheSize,
                            cacheDir: cacheDir
                        )
                        let hybridEngine = Engine(engineConfig: hybridConfig)
                        try await hybridEngine.initialize()
                        engine = hybridEngine
                        backend = .gpu
                        appState.engineBackendFallbackReason = "Vision using CPU (GPU vision unavailable: \(tier1Reason))"
                        Self.logger.info("Engine loaded with GPU text + CPU vision")
                    } catch {
                        let tier2Reason = error.localizedDescription
                        Self.logger.error("Tier 2 (GPU text + CPU vision) failed: \(tier2Reason)")

                        // Tier 3: Full CPU
                        Self.logger.info("Trying Tier 3: full CPU")
                        let cpuConfig = try EngineConfig(
                            modelPath: modelPath,
                            backend: .cpu(),
                            visionBackend: .cpu(),
                            maxNumTokens: kvCacheSize,
                            cacheDir: cacheDir
                        )
                        let cpuEngine = Engine(engineConfig: cpuConfig)
                        try await cpuEngine.initialize()
                        engine = cpuEngine
                        backend = .cpu
                        appState.engineBackendFallbackReason = "GPU text failed: \(tier2Reason)"
                        Self.logger.info("Engine loaded with full CPU backend")
                    }
                }
            }
            #endif

            let deps = AppDependencies(
                engine: engine,
                kvCacheSize: kvCacheSize,
                modelContainer: modelContainer
            )
            appState.dependencies = deps
            appState.engineBackend = backend
            appState.activeEngineBackendPreference = backendPreference
            appState.engineStatus = .ready
            appState.launchPhase = .ready

            // Create background inference guard to cancel GPU work before the app suspends.
            appState.backgroundGuard = BackgroundInferenceGuard(sessionCoordinator: deps.sessionCoordinator)

            // Load skills and restore enabled state
            appState.skillsManager.loadSkills(parser: deps.skillParser)

            // Always refresh model metadata so Settings can ask users to update
            // when their installed model is behind the app's target model.
            Task.detached(priority: .utility) { [downloader = appState.downloader] in
                await downloader.checkForRemoteUpdate()
            }

            Self.logger.info("Engine loaded successfully")
        } catch {
            appState.engineStatus = .failed(error.localizedDescription)
            Self.logger.error("Engine loading failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleBecameActive() async {
        // Continue startup if the app became active while the launch screen was waiting.
        if appState.launchPhase == .loadingEngine {
            await loadEngine()
            return
        }

        guard appState.launchPhase == .ready,
              appState.engineStatus == .ready,
              !appState.isEngineReloading,
              let deps = appState.dependencies else {
            return
        }

        guard let isAlive = await deps.sessionCoordinator.activeConversationIsAlive() else {
            Self.logger.info("Foreground resume: no active conversation to validate")
            return
        }

        guard !isAlive else {
            Self.logger.info("Foreground resume: active conversation is still valid")
            return
        }

        Self.logger.warning("Foreground resume detected an invalid conversation; reloading engine")
        appState.forceNextEngineReload = true
        await reloadEngine()
    }

    @MainActor
    private func reloadEngine() async {
        guard !appState.isEngineReloading else {
            Self.logger.info("Engine reload already in progress; ignoring duplicate request")
            return
        }

        guard appState.downloader.isDownloaded else {
            appState.launchPhase = .needsDownload
            return
        }

        if !appState.forceNextEngineReload,
           appState.engineBackend == .cpu,
           appState.userSettings.engineBackendPreference != .cpu {
            appState.engineBackendFallbackReason = "Restart the app to switch from CPU back to GPU or Automatic."
            Self.logger.warning("CPU to GPU/Automatic backend change requires app restart")
            return
        }

        appState.isEngineReloading = true
        defer { appState.isEngineReloading = false }

        appState.engineStatus = .loading
        appState.launchPhase = .loadingEngine
        appState.forceNextEngineReload = false

        if let deps = appState.dependencies {
            try? await deps.sessionCoordinator.cancelIfActive()
            await deps.sessionCoordinator.forceRelease()
        }

        // Move old dependencies to a background task for deallocation.
        // litert_lm_engine_delete and litert_lm_conversation_delete call
        // ThreadPool::WaitUntilDone() which can block indefinitely.
        // Deallocating on the main thread causes 0x8BADF00D watchdog kills.
        let oldDeps = appState.dependencies
        let oldGuard = appState.backgroundGuard
        appState.backgroundGuard = nil
        appState.dependencies = nil
        appState.engineBackend = nil
        appState.engineBackendFallbackReason = nil
        appState.activeEngineBackendPreference = nil
        appState.engineStatus = .notStarted

        if oldDeps != nil || oldGuard != nil {
            Task.detached(priority: .background) {
                _ = oldDeps
                _ = oldGuard
            }
        }

        // LiteRT-LM/Metal resource teardown happens in native deinit paths.
        // Give the old engine a short quiescence window before constructing a
        // new backend, especially when switching CPU -> GPU/Automatic.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        await loadEngine()
    }
}

#if canImport(UIKit) && !os(watchOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == ModelDownloader.backgroundSessionIdentifier else {
            completionHandler()
            return
        }

        BackgroundDownloadSessionEvents.setCompletionHandler(completionHandler)
    }
}
#endif

// MARK: - App State

/// Observable app-level state shared across the view hierarchy.
@Observable
final class AppState {
    var launchPhase: LaunchPhase = .checkingModel
    var engineStatus: EngineStatus = .notStarted
    var engineBackend: EngineBackend?
    var engineBackendFallbackReason: String?
    var activeEngineBackendPreference: EngineBackendPreference?
    var dependencies: AppDependencies?
    var backgroundGuard: BackgroundInferenceGuard?
    var engineReloadRequestID = 0
    var isEngineReloading = false
    var forceNextEngineReload = false
    var isModelUpdating = false
    var modelUpdateError: String?
    var chatInputLockCount = 0
    let downloader = ModelDownloader()
    let skillsManager = SkillsManager()
    let userSettings = UserSettings()

    var isChatInputLocked: Bool {
        chatInputLockCount > 0
    }

    func beginChatInputLock() {
        chatInputLockCount += 1
    }

    func endChatInputLock() {
        chatInputLockCount = max(0, chatInputLockCount - 1)
    }

    func requestEngineReload(force: Bool = false) {
        forceNextEngineReload = force
        engineReloadRequestID += 1
    }

    @MainActor
    func updateModelToLatest() async {
        guard !isModelUpdating else { return }

        isModelUpdating = true
        modelUpdateError = nil
        defer { isModelUpdating = false }

        if let deps = dependencies {
            try? await deps.sessionCoordinator.cancelIfActive()
            await deps.sessionCoordinator.forceRelease()
        }

        // Move old dependencies to background for deallocation (same as reloadEngine)
        let oldDeps = dependencies
        let oldGuard = backgroundGuard
        dependencies = nil
        backgroundGuard = nil
        engineBackend = nil
        engineBackendFallbackReason = nil
        activeEngineBackendPreference = nil
        engineStatus = .notStarted
        launchPhase = .needsDownload

        if oldDeps != nil || oldGuard != nil {
            Task.detached(priority: .background) {
                _ = oldDeps
                _ = oldGuard
            }
        }

        do {
            try await downloader.updateToLatestModel()
            requestEngineReload(force: true)
            launchPhase = .loadingEngine
        } catch {
            modelUpdateError = error.localizedDescription
            engineStatus = .failed(error.localizedDescription)
            if downloader.isDownloaded {
                launchPhase = .loadingEngine
                requestEngineReload(force: true)
            } else {
                launchPhase = .needsDownload
            }
        }
    }

}

/// Tracks the app's launch progression.
enum LaunchPhase {
    case checkingModel
    case needsDownload
    case loadingEngine
    case ready
}

enum EngineStatus: Equatable {
    case notStarted
    case loading
    case ready
    case failed(String)

    var displayText: String {
        switch self {
        case .notStarted: return "Initializing…"
        case .loading: return "Loading model…"
        case .ready: return "Model ready"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    var isReady: Bool {
        self == .ready
    }
}

enum EngineBackend: String, Equatable {
    case gpu
    case cpu

    var displayText: String {
        switch self {
        case .gpu: return "GPU (Metal)"
        case .cpu: return "CPU"
        }
    }
}

// MARK: - Engine Loading Overlay

/// Full-screen overlay shown while the LLM model is loading.
struct EngineLoadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)

                Text("Loading Gemma 4 E2B…")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("This may take a moment on first launch.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(40)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

// MARK: - Main Tab View

/// Root tab-based navigation with primary app entry points and settings.
struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var hasCheckedStartupModelUpdate = false
    @State private var showStartupModelUpdatePrompt = false

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .task {
            guard !hasCheckedStartupModelUpdate else { return }
            hasCheckedStartupModelUpdate = true
            if appState.downloader.modelUpdateState.isUpdateAvailable {
                showStartupModelUpdatePrompt = true
            }
        }
        .alert("New Model Available", isPresented: $showStartupModelUpdatePrompt) {
            Button("Later", role: .cancel) { }
            Button("Update Model") {
                Task { await appState.updateModelToLatest() }
            }
        } message: {
            Text(startupModelUpdateMessage)
        }
    }

    private var startupModelUpdateMessage: String {
        switch appState.downloader.modelUpdateState {
        case .missing, .current:
            return ""
        case .updateAvailable(let installedVersion):
            let targetVersion = String(ModelDownloader.currentModel.commitHash.prefix(7))
            if let installedVersion {
                return "Your installed on-device model is \(String(installedVersion.prefix(7))). Update to \(targetVersion) for the latest bundled model."
            }
            return "Your installed on-device model needs metadata refresh. Update to \(targetVersion) for the latest bundled model."
        }
    }
}

#if DEBUG
#Preview {
    EngineLoadingOverlay()
}
#endif
