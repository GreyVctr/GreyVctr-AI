import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Settings screen with model info, engine status, and advanced configuration.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAdvanced = false

    var body: some View {
        List {
            Section("Engine Status") {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        statusIndicator
                        Text(appState.engineStatus.displayText)
                            .foregroundStyle(.secondary)
                    }
                }

                row("Backend", value: appState.engineBackend?.displayText ?? "Not loaded")
                row("Backend setting", value: appState.userSettings.engineBackendPreference.displayText)

                if let fallbackReason = appState.engineBackendFallbackReason {
                    diagnosticRow("GPU fallback", value: fallbackReason)
                }
            }

            Section("Model") {
                row("Model", value: ModelDownloader.currentModel.name)
                row("Model version", value: modelVersionDisplay)
                row("Model status", value: modelStatusDisplay)
                row("LiteRT-LM", value: liteRTLMVersionDisplay)

                if case .updateAvailable = appState.downloader.modelUpdateState {
                    Text(ModelDownloader.currentModel.updateInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await appState.updateModelToLatest() }
                    } label: {
                        Label(
                            appState.isModelUpdating ? "Updating Model…" : "Update Model",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(appState.isModelUpdating || isModelDownloadActive)
                }

                if let updateError = appState.modelUpdateError {
                    diagnosticRow("Update error", value: updateError)
                }
            }

            // MARK: - Advanced Section
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    temperatureControl
                    topPControl
                    topKControl
                    backendControl
                    kvCacheControl
                    globalPromptField
                    perModePrompts
                    resetButton
                }
            }

            Section("About") {
                row("App", value: "GreyVctr AI")
                row("Version", value: appVersion)
                row("Build", value: buildNumber)
            }

            Section("Data") {
                NavigationLink {
                    HistoryListView(
                        title: "All History",
                        emptyTitle: "No History",
                        emptyDescription: "Saved conversations will appear here."
                    )
                } label: {
                    Label("All History", systemImage: "clock")
                }
            }

            Section("Diagnostics") {
                row("Inference", value: "On-device only")
                row("Runtime", value: "LiteRT-LM")
                row("Model status", value: modelStatusDisplay)
                row("KV cache", value: "\(activeKVCacheSize) tokens")
                row("Skills enabled", value: "\(appState.skillsManager.enabledCount)")

                Button {
                    copyDiagnostics()
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
            }

            Section {
                Text("All inference runs locally on your device. No data leaves this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Settings")
    }

    // MARK: - Advanced Controls

    private var temperatureControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Temperature")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.1f", appState.userSettings.effectiveTemperature(configDefault: defaultInferenceConfig.temperature)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { appState.userSettings.temperatureOverride ?? defaultInferenceConfig.temperature },
                    set: { appState.userSettings.temperatureOverride = $0 }
                ),
                in: 0.0...2.0,
                step: 0.1
            )

            Text("Lower = more focused, Higher = more creative")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var topPControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top P")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", appState.userSettings.effectiveTopP(configDefault: defaultInferenceConfig.topP)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { appState.userSettings.topPOverride ?? defaultInferenceConfig.topP },
                    set: { appState.userSettings.topPOverride = $0 }
                ),
                in: 0.0...1.0,
                step: 0.05
            )

            Text("Lower = narrower token choices, Higher = more varied")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var topKControl: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Top K")
                    .font(.subheadline)
                Text("Limits how many likely next tokens are considered")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("\(appState.userSettings.effectiveTopK(configDefault: defaultInferenceConfig.topK))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Stepper(
                "",
                value: Binding(
                    get: { appState.userSettings.topKOverride ?? defaultInferenceConfig.topK },
                    set: { appState.userSettings.topKOverride = $0 }
                ),
                in: 1...200,
                step: 5
            )
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private var globalPromptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Global System Prompt")
                .font(.subheadline)

            Text("Prepended to all modes. Example: \"I'm an E-7 in an aviation unit.\"")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextEditor(text: Binding(
                get: { appState.userSettings.globalSystemPrompt },
                set: { appState.userSettings.globalSystemPrompt = $0 }
            ))
            .frame(minHeight: 60)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.secondary.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }

    private var kvCacheControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("KV Cache")
                        .font(.subheadline)
                    Text("Active: \(activeKVCacheSize) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Configured: \(appState.userSettings.kvCacheSize)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("KV Cache", selection: Binding(
                get: { appState.userSettings.kvCacheSize },
                set: {
                    guard KVCacheMemoryPolicy.isAvailable($0) else { return }
                    appState.userSettings.kvCacheSize = $0
                }
            )) {
                ForEach(KVCacheMemoryPolicy.availableOptions) { option in
                    Text("\(option.label) - \(option.detail)")
                        .tag(option.value)
                }
            }
            .pickerStyle(.menu)

            Text("Device memory: \(KVCacheMemoryPolicy.physicalMemoryLabel). Larger values allow longer chats but use more memory. Changes apply after restarting the app because this cache is allocated at engine startup.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            ForEach(KVCacheMemoryPolicy.options.filter { !$0.isAvailable }) { option in
                Text("\(option.label) unavailable: \(option.unavailableReason ?? "Not supported on this device.")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasPendingKVCacheChange {
                Label("Restart the app to apply this KV cache size.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var backendControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backend")
                        .font(.subheadline)
                    Text("Active: \(appState.engineBackend?.displayText ?? "Not loaded")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Configured: \(appState.userSettings.engineBackendPreference.displayText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("Backend", selection: Binding(
                get: { appState.userSettings.engineBackendPreference },
                set: { appState.userSettings.engineBackendPreference = $0 }
            )) {
                ForEach(EngineBackendPreference.allCases) { preference in
                    Text(preference.displayText)
                        .tag(preference)
                }
            }
            .pickerStyle(.menu)

            Text(appState.userSettings.engineBackendPreference.detailText)
                .font(.caption)
                .foregroundStyle(.tertiary)

            #if targetEnvironment(simulator)
            Text("Simulator runs the LiteRT-LM backend on CPU. GPU/Metal requires a physical device.")
                .font(.caption)
                .foregroundStyle(.orange)
            #endif

            if hasPendingBackendChange {
                Label("Restart the app to apply this backend setting.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var perModePrompts: some View {
        DisclosureGroup("Per-Mode System Prompts") {
            promptEditor(
                title: "Ask Image",
                placeholder: "Adds instructions for image analysis mode",
                defaultPrompt: defaultSystemPrompt(for: .askImage),
                text: Binding(
                    get: { appState.userSettings.askImageSystemPrompt },
                    set: { appState.userSettings.askImageSystemPrompt = $0 }
                )
            )

            promptEditor(
                title: "AI Chat",
                placeholder: "Adds instructions for general chat mode",
                defaultPrompt: defaultSystemPrompt(for: .aiChat),
                text: Binding(
                    get: { appState.userSettings.aiChatSystemPrompt },
                    set: { appState.userSettings.aiChatSystemPrompt = $0 }
                )
            )

            promptEditor(
                title: "Chat with Skills",
                placeholder: "Adds instructions for skills mode",
                defaultPrompt: defaultSystemPrompt(for: .chatWithSkills),
                text: Binding(
                    get: { appState.userSettings.skillsSystemPrompt },
                    set: { appState.userSettings.skillsSystemPrompt = $0 }
                )
            )
        }
    }

    private func promptEditor(
        title: String,
        placeholder: String,
        defaultPrompt: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))

                Spacer()

                Button("Restore Default") {
                    text.wrappedValue = ""
                }
                .font(.caption)
                .disabled(text.wrappedValue.isEmpty)
            }

            TextEditor(text: Binding(
                get: {
                    if text.wrappedValue.isEmpty {
                        return defaultPrompt
                    }
                    return text.wrappedValue
                },
                set: { text.wrappedValue = $0 }
            ))
            .font(.caption.monospaced())
            .frame(minHeight: defaultPrompt.isEmpty ? 72 : 140)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.secondary.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty && defaultPrompt.isEmpty {
                    Text(placeholder)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var resetButton: some View {
        Button(role: .destructive) {
            appState.userSettings.resetAll()
        } label: {
            Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func diagnosticRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func defaultSystemPrompt(for mode: AppMode) -> String {
        let loader = appState.dependencies?.configLoader ?? InferenceConfigLoader()
        return loader.load(for: mode).systemPrompt
    }

    private var defaultInferenceConfig: InferenceConfig {
        let loader = appState.dependencies?.configLoader ?? InferenceConfigLoader()
        return loader.load()
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch appState.engineStatus {
        case .ready:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .loading:
            ProgressView().scaleEffect(0.6)
        case .failed:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .notStarted:
            Circle().fill(.gray).frame(width: 8, height: 8)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var liteRTLMVersionDisplay: String {
        "main (v0.13.1)"
    }

    private var modelVersionDisplay: String {
        guard let commitHash = appState.downloader.installedMetadata?.commitHash else {
            return "Unknown"
        }
        return String(commitHash.prefix(7))
    }

    private var modelStatusDisplay: String {
        switch appState.downloader.modelUpdateState {
        case .missing:
            return "Missing"
        case .current:
            return "Current"
        case .updateAvailable(let installedVersion):
            let targetHash = ModelDownloader.currentModel.commitHash
            if let installedVersion {
                return "Update available (\(String(installedVersion.prefix(7))) → \(String(targetHash.prefix(7))))"
            }
            return "Update available"
        }
    }

    private var isModelDownloadActive: Bool {
        switch appState.downloader.status {
        case .downloading:
            return true
        default:
            return false
        }
    }

    private var activeKVCacheSize: Int {
        appState.dependencies?.kvCacheSize ?? appState.userSettings.kvCacheSize
    }

    private var hasPendingKVCacheChange: Bool {
        activeKVCacheSize != appState.userSettings.kvCacheSize
    }

    private var hasPendingBackendChange: Bool {
        guard let active = appState.activeEngineBackendPreference else { return false }
        return active != appState.userSettings.engineBackendPreference
    }

    private var diagnosticsText: String {
        """
        GreyVctr AI Diagnostics
        App: GreyVctr AI
        Version: \(appVersion)
        Build: \(buildNumber)
        Engine status: \(appState.engineStatus.displayText)
        Backend: \(appState.engineBackend?.displayText ?? "Not loaded")
        Backend configured: \(appState.userSettings.engineBackendPreference.displayText)
        GPU fallback: \(appState.engineBackendFallbackReason ?? "None")
        Model: \(ModelDownloader.currentModel.name)
        Model status: \(modelStatusDisplay)
        Model version: \(modelVersionDisplay)
        Latest model: \(String(ModelDownloader.currentModel.commitHash.prefix(7)))
        Runtime: LiteRT-LM \(liteRTLMVersionDisplay)
        Device memory: \(KVCacheMemoryPolicy.physicalMemoryLabel)
        KV cache active: \(activeKVCacheSize) tokens
        KV cache configured: \(appState.userSettings.kvCacheSize) tokens
        Skills enabled: \(appState.skillsManager.enabledCount)
        Inference: On-device only
        """
    }

    private func copyDiagnostics() {
        #if canImport(UIKit)
        UIPasteboard.general.string = diagnosticsText
        #endif
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AppState())
}
#endif
