import SwiftUI

/// Detail view for a selected skill.
///
/// Shows the skill description, instructions, JavaScript source, and bundled assets.
struct SkillDetailView: View {
    let skill: SkillDefinition
    var readOnly: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - Skill Info
                skillInfoSection

                // MARK: - JS Source (read-only, JS-backed skills only)
                if let jsContent = skill.jsContent, !jsContent.isEmpty {
                    jsSourceSection(content: jsContent)
                }

                if !skill.assetPaths.isEmpty || skill.webViewContent != nil {
                    assetSection
                }
            }
            .padding()
        }
        .navigationTitle(skill.name)
    }

    // MARK: - Subviews

    private var skillInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(skill.description)
                .font(.body)
                .foregroundStyle(.secondary)

            if skill.skillType == .jsBacked {
                Label("Computation-backed skill", systemImage: "gearshape.2")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            DisclosureGroup("Skill Instructions") {
                Text(skill.instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func jsSourceSection(content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("JavaScript Source") {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(content)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var assetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Assets") {
                VStack(alignment: .leading, spacing: 8) {
                    if !skill.assetPaths.isEmpty {
                        ForEach(skill.assetPaths, id: \.self) { path in
                            Text(path)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let webViewContent = skill.webViewContent {
                        Divider()
                        Text("WebView Source")
                            .font(.caption.weight(.medium))
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(webViewContent)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

}

#if DEBUG
#Preview {
    NavigationStack {
        SkillDetailView(skill: SkillDefinition(
            id: "preview-skill",
            name: "Preview Skill",
            description: "A sample skill for preview purposes.",
            instructions: "Follow these instructions to generate output.",
            skillType: .textOnly,
            jsContent: nil
        ))
    }
}
#endif
