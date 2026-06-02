import SwiftUI
import SwiftData

/// Chronological list of past generated outputs.
///
/// Shows mode badge, skill name (if applicable), truncated preview, and timestamp.
/// Supports swipe-to-delete and navigates to HistoryDetailView on selection.
struct HistoryListView: View {
    let title: String
    let modes: Set<String>?
    let emptyTitle: String
    let emptyDescription: String

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HistoryEntry.timestamp, order: .reverse) private var entries: [HistoryEntry]
    @State private var showDeleteAllConfirmation = false
    @State private var searchText = ""

    init(
        title: String = "History",
        modes: Set<String>? = nil,
        emptyTitle: String = "No History",
        emptyDescription: String = "Generated outputs will appear here."
    ) {
        self.title = title
        self.modes = modes
        self.emptyTitle = emptyTitle
        self.emptyDescription = emptyDescription
    }

    var body: some View {
        Group {
            if scopedEntries.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "clock")
                } description: {
                    Text(emptyDescription)
                }
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                historyList
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search history")
        .toolbar {
            if !scopedEntries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                }
            }
        }
        .alert("Delete All History?", isPresented: $showDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                deleteAllEntries()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes \(deleteScopeDescription).")
        }
    }

    private var scopedEntries: [HistoryEntry] {
        guard let modes else {
            return entries
        }

        return entries.filter { modes.contains($0.mode) }
    }

    private var filteredEntries: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return scopedEntries
        }

        return scopedEntries.filter { entry in
            entry.matchesSearch(query)
        }
    }

    private var deleteScopeDescription: String {
        modes == nil ? "all saved history" : "the saved history shown here"
    }

    private var historyList: some View {
        List {
            ForEach(filteredEntries, id: \.id) { entry in
                NavigationLink(destination: HistoryDetailView(entry: entry)) {
                    HistoryRow(entry: entry)
                }
            }
            .onDelete(perform: deleteEntries)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - Actions

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            let entry = filteredEntries[index]
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }

    private func deleteAllEntries() {
        for entry in scopedEntries {
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }
}

private extension HistoryEntry {
    func matchesSearch(_ query: String) -> Bool {
        searchableText.localizedCaseInsensitiveContains(query)
    }

    private var searchableText: String {
        [
            modeDisplayName,
            mode,
            skillName,
            skillId,
            userInput,
            generatedOutput,
            isConversation ? "conversation \(turnCount) turns" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private var modeDisplayName: String {
        switch mode {
        case AppMode.askImage.rawValue:
            return "Image Ask Image"
        case AppMode.aiChat.rawValue:
            return "Chat AI Chat"
        case AppMode.chatWithSkills.rawValue:
            return "Skill Skills Chat"
        default:
            return mode
        }
    }
}

// MARK: - History Row

/// A single row in the history list showing mode, skill name, preview, and timestamp.
struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ModeBadge(mode: entry.mode)

                if let skillName = entry.skillName {
                    Text(skillName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if entry.isConversation {
                    Text("\(entry.turnCount) turns")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(entry.previewText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

private extension HistoryEntry {
    var previewText: String {
        if isConversation {
            return userInput.isEmpty ? generatedOutput : userInput
        }

        return generatedOutput
    }
}

// MARK: - Mode Badge

/// A small colored badge indicating the app mode (Ask Image, AI Chat, Skills).
struct ModeBadge: View {
    let mode: String

    var body: some View {
        Text(displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
    }

    private var displayName: String {
        switch mode {
        case AppMode.askImage.rawValue:
            return "Image"
        case AppMode.aiChat.rawValue:
            return "Chat"
        case AppMode.chatWithSkills.rawValue:
            return "Skill"
        default:
            return mode
        }
    }

    private var badgeColor: Color {
        switch mode {
        case AppMode.askImage.rawValue:
            return .blue
        case AppMode.aiChat.rawValue:
            return .green
        case AppMode.chatWithSkills.rawValue:
            return .orange
        default:
            return .gray
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HistoryListView()
    }
}
#endif
