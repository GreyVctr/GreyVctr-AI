import SwiftUI

/// Multi-turn AI chat interface with streaming responses.
struct AIChatView: View {
    private let visibleMessageLimit = 15

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var appState
    @State private var viewModel: AIChatViewModel?
    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var showHistory = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        Group {
            if scenePhase == .active {
                VStack(spacing: 0) {
                    contextUsageView

                    messageList

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

                    inputBar
                }
            } else {
                Color(.systemBackground)
            }
        }
        .navigationTitle("AI Chat")
        .onAppear { setupViewModel() }
        .onDisappear {
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("Show conversation history")

                    Button {
                        viewModel?.newConversation()
                    } label: {
                        Image(systemName: "plus.message")
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("New conversation")
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            ConversationResumeListView(
                mode: .aiChat,
                title: "AI Chat",
                onSelect: restoreConversation,
                onNewConversation: { viewModel?.newConversation() }
            )
        }
    }

    private func setupViewModel() {
        guard viewModel == nil, let deps = appState.dependencies else { return }
        viewModel = AIChatViewModel(
            sessionCoordinator: deps.sessionCoordinator,
            configLoader: deps.configLoader,
            historyStore: deps.historyStore,
            conversationStore: deps.conversationStore,
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    let messages = viewModel?.messages ?? []

                    if messages.isEmpty {
                        emptyState
                    }

                    if hiddenMessageCount > 0 {
                        hiddenMessagesNotice
                    }

                    ForEach(visibleMessages) { message in
                        ChatBubble(message: message, plainTextOnly: true)
                            .equatable()
                            .id(message.id)
                    }

                    if let streamingContent = viewModel?.streamingContent,
                       viewModel?.isGenerating ?? false {
                        streamingBubble(content: streamingContent)
                            .id("streaming")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding()
            }
            .onChange(of: viewModel?.messages.count ?? 0) { _, _ in
                scheduleScrollToBottom(proxy, animated: true)
            }
            .onChange(of: viewModel?.streamingContent ?? "") { _, _ in
                if viewModel?.isGenerating ?? false {
                    scheduleScrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: viewModel?.isGenerating ?? false) { _, isGenerating in
                if isGenerating {
                    scheduleScrollToBottom(proxy, animated: false)
                } else {
                    scheduleScrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    private func streamingBubble(content: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(content.isEmpty ? "…" : content)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer(minLength: 48)
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
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Start a conversation")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Type a message below to chat with the on-device AI.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
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
                    Task { await viewModel?.sendMessage() }
                }

            if viewModel?.isGenerating ?? false {
                // Stop button while streaming
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
                // Send button
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

    private var canSendMessage: Bool {
        let input = (viewModel?.currentInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !input.isEmpty && !isBusy && !appState.isChatInputLocked
    }

    private var isBusy: Bool {
        (viewModel?.isGenerating ?? false)
            || (viewModel?.isStopping ?? false)
            || (viewModel?.isSendSettling ?? false)
    }

    private func sendMessage() {
        guard canSendMessage else { return }
        isInputFocused = false
        Task { @MainActor in
            await Task.yield()
            await viewModel?.sendMessage()
        }
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard scenePhase == .active else { return }
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(animated ? 80 : 20))
            guard !Task.isCancelled, scenePhase == .active else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func isSessionLostError(_ message: String) -> Bool {
        message.contains("Session lost") || message.contains("restart the app")
    }
}

struct ContextWindowBar: View {
    let percent: Int
    let warning: String?
    let startFresh: () -> Void

    private var normalizedProgress: Double {
        min(1.0, max(0.0, Double(percent) / 100.0))
    }

    private var tint: Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .blue
    }

    private var label: String {
        if let warning {
            return warning
        }
        return "Context window"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: warning == nil ? "memorychip" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                Text("\(percent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)

                if warning != nil {
                    Button("Start Fresh", action: startFresh)
                        .font(.caption.weight(.medium))
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * normalizedProgress))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AIChatView()
    }
    .environment(AppState())
}
#endif
