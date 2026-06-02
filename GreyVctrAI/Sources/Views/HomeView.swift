import SwiftUI

/// Home screen presenting three large cards for the app's primary modes:
/// Ask Image, AI Chat, and Chat with Skills.
struct HomeView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                NavigationLink(destination: AIChatView()) {
                    ModeCard(
                        title: "AI Chat",
                        subtitle: "Free-form conversation",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        color: .green
                    )
                }

                NavigationLink(destination: AskImageView()) {
                    ModeCard(
                        title: "Ask Image",
                        subtitle: "Analyze photos with AI",
                        systemImage: "camera.fill",
                        color: .blue
                    )
                }

                NavigationLink(destination: SkillsChatView()) {
                    ModeCard(
                        title: "Chat with Skills",
                        subtitle: "Multi-skill AI chat",
                        systemImage: "sparkles",
                        color: .orange
                    )
                }
            }
            .padding()
        }
        .navigationTitle("GreyVctr AI")
    }
}

// MARK: - Mode Card

/// A large tappable card representing one of the three app modes.
/// Supports Dynamic Type and adapts to light/dark mode automatically.
struct ModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(color)
                .frame(width: 56, height: 56)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeView()
    }
}
#endif
