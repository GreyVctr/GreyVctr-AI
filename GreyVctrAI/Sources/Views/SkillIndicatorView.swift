import SwiftUI
import MarkdownUI

/// A collapsible indicator that shows which skill is being used for a message.
///
/// Displays a compact "Using skill: [Skill Name]" label with a sparkles icon
/// and a chevron toggle. Tapping expands to reveal the full skill instructions
/// rendered as markdown.
struct SkillIndicatorView: View {
    let skillName: String
    let skillInstructions: String
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Using skill: \(skillName)")
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Using skill: \(skillName), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                Divider()
                    .background(.white.opacity(0.3))
                MarkdownText(content: skillInstructions)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        SkillIndicatorView(
            skillName: "Risk Matrix Helper",
            skillInstructions: "**Bold instructions** with `code` and lists:\n- Item 1\n- Item 2"
        )
        .padding()
        .background(Color.blue)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    .padding()
}
#endif
