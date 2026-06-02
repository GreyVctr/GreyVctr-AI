import SwiftUI

/// A compact indicator on model response bubbles showing which skill was used.
///
/// When tool-call data is available, tapping expands to reveal the JSON data
/// that was passed to the skill. When no data is present, shows as a static label.
struct SkillToolCallIndicator: View {
    let skillName: String
    let toolCallData: String?
    var events: [SkillToolEvent] = []
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if toolCallData != nil || !events.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Used skill: \(skillName), \(isExpanded ? "expanded" : "collapsed")")
                .accessibilityAddTraits(.isButton)
            } else {
                header
                    .accessibilityLabel("Used skill: \(skillName)")
            }

            if isExpanded {
                if !events.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 0) {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 7, height: 7)
                                        .padding(.top, 6)
                                    if event.id != events.last?.id {
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.25))
                                            .frame(width: 1)
                                            .frame(maxHeight: .infinity)
                                            .padding(.top, 3)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    if let detail = event.detail {
                                        Text(detail)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    if let data = event.data {
                                        Text(data)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                            .padding(.top, 2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground).opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let data = toolCallData {
                    Text(data)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(12)
                        .background(Color(.secondarySystemBackground).opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars.inverse")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text(headerTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if toolCallData != nil || !events.isEmpty {
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headerTitle: String {
        if events.contains(where: { $0.title.localizedCaseInsensitiveContains("Call JS") }) {
            return "Called JS skill \"\(skillName)/index.html\""
        }

        return "Used skill: \(skillName)"
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        SkillToolCallIndicator(
            skillName: "grid-converter",
            toolCallData: "{\n  \"conversion\": \"mgrs_to_ll\",\n  \"mgrs\": \"18SUJ2339407395\"\n}"
        )
        .padding()
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 16))

        SkillToolCallIndicator(
            skillName: "risk-matrix-helper",
            toolCallData: nil
        )
        .padding()
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    .padding()
}
#endif
