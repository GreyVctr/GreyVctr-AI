import SwiftUI
import MarkdownUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders a single chat message as a styled bubble.
///
/// User messages appear right-aligned with a blue background.
/// Model messages appear left-aligned with a gray background.
/// When a skill was used for a model response, a compact indicator
/// is shown above the message content.
/// Completed model messages show copy/share action buttons.
struct ChatBubble: View {
    let message: ChatMessage
    var plainTextOnly: Bool = false
    var showActions: Bool = true
    var allowExpansion: Bool = true
    @State private var isExpanded = false

    var body: some View {
        HStack {
            if message.role == .user || isCenteredStatusMessage {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 8) {
                if isCenteredStatusMessage {
                    statusMessageView
                } else {
                // Tool-call indicator (model messages that used a skill)
                if message.role == .model,
                   let skillName = message.toolCallSkillName {
                    SkillToolCallIndicator(
                        skillName: skillName,
                        toolCallData: message.toolCallData,
                        events: message.toolEvents
                    )
                }

                // Message content
                Group {
                    if message.role == .model,
                       !message.content.isEmpty,
                       !message.isStreaming,
                       message.toolCallSkillName != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            selectableText(displayContent)

                            if isLongSkillResponse && allowExpansion {
                                Button {
                                    isExpanded.toggle()
                                } label: {
                                    Label(
                                        isExpanded ? "Show less" : "Show full response",
                                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    } else if plainTextOnly {
                        Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                            .font(.body)
                            .textSelection(.enabled)
                    } else if message.role == .model,
                              !message.content.isEmpty,
                              !message.isStreaming {
                        MarkdownText(content: message.content)
                            .font(.body)
                    } else {
                        Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }

                // Copy/Share actions for completed model messages
                if showActions && message.role == .model && !message.content.isEmpty && !message.isStreaming {
                    HStack(spacing: 16) {
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = message.content
                            #endif
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Copy response")

                        ShareLink(item: message.content) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Share response")
                    }
                    .padding(.top, 2)
                }
                }
            }
            .padding(12)
            .background(bubbleBackground)
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if message.role != .user && !isCenteredStatusMessage {
                Spacer(minLength: 48)
            }
        }
    }

    private var bubbleBackground: Color {
        if isCenteredStatusMessage {
            return Color.gray.opacity(0.12)
        }
        switch message.role {
        case .user: return .blue
        case .model: return Color.gray.opacity(0.2)
        case .system: return Color.gray.opacity(0.1)
        }
    }

    private var isCenteredStatusMessage: Bool {
        message.role == .system && message.isStatusMessage
    }

    private var isLongSkillResponse: Bool {
        message.role == .model &&
        message.toolCallSkillName != nil &&
        message.content.count > 1_500
    }

    private var displayContent: String {
        guard isLongSkillResponse, isExpanded && allowExpansion else {
            return collapsedSkillContent
        }

        return message.content
    }

    private var collapsedSkillContent: String {
        guard isLongSkillResponse else {
            return message.content
        }

        let prefix = message.content.prefix(1_500)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(prefix)
    }

    private var statusMessageView: some View {
        Text(message.content)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
            .accessibilityLabel(message.content)
    }

    @ViewBuilder
    private func selectableText(_ content: String) -> some View {
        if content.count > 2_500 {
            Text(content)
                .font(.body)
        } else {
            Text(content)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

extension ChatBubble: Equatable {
    static func == (lhs: ChatBubble, rhs: ChatBubble) -> Bool {
        lhs.message == rhs.message
    }
}
