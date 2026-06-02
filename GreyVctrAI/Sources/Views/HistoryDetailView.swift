import SwiftUI

/// Full detail view for a history entry.
///
/// Displays the complete generated output, mode, skill name (if applicable),
/// original user input, and timestamp. Provides copy and share buttons.
struct HistoryDetailView: View {
    let entry: HistoryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - Metadata
                metadataSection

                Divider()

                if entry.isConversation {
                    conversationSection
                } else {
                    // MARK: - User Input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Input")
                            .font(.headline)

                        Text(entry.userInput)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Divider()

                    // MARK: - Generated Output
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Output")
                                .font(.headline)
                            Spacer()
                            outputActions
                        }

                        MarkdownText(content: entry.generatedOutput)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Detail")
    }

    // MARK: - Subviews

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ModeBadge(mode: entry.mode)

                if let skillName = entry.skillName {
                    Text(skillName)
                        .font(.subheadline.weight(.medium))
                }

                if entry.isConversation {
                    Text("\(entry.turnCount) turns")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text(entry.timestamp, format: .dateTime.month().day().year().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputActions: some View {
        HStack(spacing: 12) {
            CopyButton(text: entry.generatedOutput)

            ShareLink(item: entry.generatedOutput) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share output")
        }
    }

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversation")
                    .font(.headline)
                Spacer()
                outputActions
            }

            let messages = HistoryConversationTranscriptParser.messages(from: entry.generatedOutput)
            if messages.isEmpty {
                MarkdownText(content: entry.generatedOutput)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 12) {
                    ForEach(messages) { message in
                        HistoryConversationTurnView(message: message)
                    }
                }
            }
        }
    }
}

private struct HistoryConversationTurnView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if message.role == .model {
                    MarkdownText(content: message.content)
                        .font(.body)
                } else {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(background)
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if message.role != .user {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var label: String {
        switch message.role {
        case .user:
            return "User"
        case .model:
            return "Assistant"
        case .system:
            return "System"
        }
    }

    private var background: Color {
        switch message.role {
        case .user:
            return .blue
        case .model:
            return Color.gray.opacity(0.2)
        case .system:
            return Color.gray.opacity(0.1)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HistoryDetailView(entry: {
            let entry = HistoryEntry(
                mode: .chatWithSkills,
                skillName: "Risk Matrix Helper",
                skillId: "risk-matrix-helper",
                userInput: "Evaluate risk for convoy movement through urban area.",
                generatedOutput: "Risk assessment: Medium-High. Recommend additional security measures."
            )
            return entry
        }())
    }
}
#endif
