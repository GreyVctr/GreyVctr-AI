import SwiftUI

/// A collapsible "thinking" bubble that shows streaming model output.
/// Starts collapsed with a "Thinking…" label and chevron.
/// Users can tap to expand and see the raw tokens being generated.
struct ThinkingBubble: View {
    let content: String
    @State private var isExpanded = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                // Header — always visible
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                // Expanded raw content
                if isExpanded {
                    Text(content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(20)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer(minLength: 48)
        }
        .padding(.horizontal)
    }
}
