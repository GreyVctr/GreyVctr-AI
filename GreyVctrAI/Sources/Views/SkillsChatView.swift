import SwiftUI
import OSLog

/// Multi-skill chat interface where all enabled skills are loaded into the system prompt.
///
/// The user chats naturally and the LLM uses the appropriate skill based on the request.
/// A gear icon in the toolbar opens SkillsConfigView to manage which skills are active.
struct SkillsChatView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: SkillsChatViewModel?
    @State private var showConfig = false
    @State private var showHistory = false
    @FocusState private var isInputFocused: Bool
    private let visibleMessageLimit = 6
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GreyVctr AI",
        category: "SkillsChatView"
    )

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Enabled Skills Summary
            enabledSkillsBanner

            contextUsageView

            // MARK: - Messages
            messageList

            // MARK: - Error
            if let errorMessage = viewModel?.error {
                if isSessionLostError(errorMessage) {
                    ActionableErrorBanner(
                        message: errorMessage,
                        actionLabel: "Reload Engine",
                        systemImage: "arrow.clockwise"
                    ) {
                        viewModel?.newConversation()
                        appState.requestEngineReload()
                    }
                    .padding(.horizontal)
                } else {
                    ErrorBanner(message: errorMessage)
                        .padding(.horizontal)
                }
            }

            // MARK: - Input
            inputBar
        }
        .navigationTitle("Chat with Skills")
        .onAppear { setupViewModel() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("Show skill conversation history")

                    Button {
                        viewModel?.newConversation()
                    } label: {
                        Image(systemName: "plus.message")
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("New skill request")

                    Button {
                        showConfig = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Skills configuration")
                }
            }
        }
        .sheet(isPresented: $showConfig) {
            SkillsConfigView()
        }
        .sheet(isPresented: $showHistory) {
            ConversationResumeListView(
                mode: .chatWithSkills,
                title: "Skills Chat",
                onSelect: restoreConversation,
                onNewConversation: { viewModel?.newConversation() }
            )
        }
    }

    private func setupViewModel() {
        guard viewModel == nil, let deps = appState.dependencies else { return }
        viewModel = SkillsChatViewModel(
            sessionCoordinator: deps.sessionCoordinator,
            configLoader: deps.configLoader,
            historyStore: deps.historyStore,
            conversationStore: deps.conversationStore,
            jsRuntime: deps.jsRuntime,
            appState: appState,
            userSettings: appState.userSettings,
            kvCacheSize: deps.kvCacheSize
        )
    }

    private func restoreConversation(from entry: HistoryEntry) {
        setupViewModel()
        let messages = HistoryConversationTranscriptParser.messages(from: entry.generatedOutput)
        guard !messages.isEmpty else { return }
        viewModel?.restoreConversation(
            id: entry.id,
            messages: messages
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private var contextUsageView: some View {
        if let percent = viewModel?.contextUsagePercent, percent > 0 {
            ContextWindowBar(
                percent: percent,
                warning: viewModel?.contextWarning,
                startFresh: { viewModel?.newConversation() }
            )
        }
    }

    private var enabledSkillsBanner: some View {
        Group {
            let enabled = appState.skillsManager.enabledSkills
            if !enabled.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.orange)

                        ForEach(enabled) { skill in
                            Text(skill.name)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .background(.bar)
            }
        }
    }

    private var messageList: some View {
        ScrollView {
            VStack(spacing: 12) {
                if viewModel?.messages.isEmpty ?? true {
                    emptyState
                }

                if hiddenMessageCount > 0 {
                    hiddenMessagesNotice
                }

                ForEach(visibleMessages) { message in
                    ChatBubble(
                        message: message,
                        plainTextOnly: isBusy,
                        showActions: !isBusy,
                        allowExpansion: !isBusy
                    )
                }

                if let status = viewModel?.generationStatus,
                   viewModel?.isGenerating ?? false {
                    HStack(spacing: 8) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.secondary)
                        Text(status)
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                // Streaming content: collapsible "thinking" bubble for JS skills,
                // full streaming text for text skills / general assistant.
                if let streaming = viewModel?.streamingContent,
                   viewModel?.isGenerating ?? false {
                    ThinkingBubble(content: streaming)
                }
            }
            .padding()
        }
    }

    private var visibleMessages: [ChatMessage] {
        let messages = viewModel?.messages ?? []
        guard messages.count > visibleMessageLimit else { return messages }
        return Array(messages.suffix(visibleMessageLimit))
    }

    private var hiddenMessageCount: Int {
        max(0, (viewModel?.messages.count ?? 0) - visibleMessageLimit)
    }

    private var hiddenMessagesNotice: some View {
        Text("\(hiddenMessageCount) earlier message\(hiddenMessageCount == 1 ? "" : "s") saved in History")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Chat with Skills")
                .font(.headline)
                .foregroundStyle(.secondary)

            let count = appState.skillsManager.enabledCount
            if count > 0 {
                Text("\(count) skill\(count == 1 ? "" : "s") loaded. Ask anything and the AI will use the right skill.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No skills enabled. Tap the gear icon to enable skills.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 60)
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Message…", text: Binding(
                get: { viewModel?.currentInput ?? "" },
                set: { viewModel?.currentInput = $0 }
            ), axis: .vertical)
                .focused($isInputFocused)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .disabled(isBusy)
                .onSubmit {
                    sendMessage()
                }

            if viewModel?.isGenerating ?? false {
                Button {
                    isInputFocused = false
                    viewModel?.stopGenerating()
                } label: {
                    if viewModel?.isStopping ?? false {
                        Image(systemName: "hourglass")
                            .font(.title3)
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                }
                .disabled(viewModel?.isStopping ?? false)
                .accessibilityLabel((viewModel?.isStopping ?? false) ? "Stopping generation" : "Stop generating")
            } else {
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSendMessage)
                .accessibilityLabel("Send message")
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Actions

    private var canSendMessage: Bool {
        let input = (viewModel?.currentInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !input.isEmpty && !isBusy && !appState.isChatInputLocked
    }

    private var isBusy: Bool {
        (viewModel?.isGenerating ?? false) || (viewModel?.isStopping ?? false)
    }

    private func sendMessage() {
        guard canSendMessage else { return }
        isInputFocused = false
        let enabledSkills = appState.skillsManager.enabledSkills
        logger.info("SkillsChatView sendMessage tapped; enabled skills \(enabledSkills.count)")
        viewModel?.submitMessage(enabledSkills: enabledSkills)
    }

    private func isSessionLostError(_ message: String) -> Bool {
        message.contains("Session lost") || message.contains("Reload Engine")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SkillsChatView()
    }
    .environment(AppState())
}
#endif
