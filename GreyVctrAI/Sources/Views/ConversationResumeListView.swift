import SwiftData
import SwiftUI

/// Chat-owned history picker used to restore a saved conversation in place.
struct ConversationResumeListView: View {
    let mode: AppMode
    let title: String
    let onSelect: (HistoryEntry) -> Void
    let onNewConversation: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HistoryEntry.timestamp, order: .reverse) private var entries: [HistoryEntry]
    @State private var searchText = ""
    @State private var showDeleteAllConfirmation = false

    private var matchingModeEntries: [HistoryEntry] {
        entries.filter {
            $0.isConversation && $0.mode == mode.rawValue
        }
    }

    private var filteredEntries: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return matchingModeEntries }

        return matchingModeEntries.filter {
            $0.userInput.localizedCaseInsensitiveContains(query)
                || $0.generatedOutput.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredEntries.isEmpty {
                    ContentUnavailableView {
                        Label("No Conversations", systemImage: "clock")
                    } description: {
                        Text("Saved \(title) conversations will appear here.")
                    }
                } else {
                    List {
                        ForEach(filteredEntries, id: \.id) { entry in
                            Button {
                                onSelect(entry)
                                dismiss()
                            } label: {
                                ConversationResumeRow(entry: entry)
                            }
                        }
                        .onDelete(perform: deleteEntries)
                    }
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search conversations")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            onNewConversation()
                            dismiss()
                        } label: {
                            Label("New Conversation", systemImage: "plus.message")
                        }

                        if !matchingModeEntries.isEmpty {
                            Button(role: .destructive) {
                                showDeleteAllConfirmation = true
                            } label: {
                                Label("Delete All", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Conversation actions")
                }
            }
            .alert("Delete All Conversations?", isPresented: $showDeleteAllConfirmation) {
                Button("Delete All", role: .destructive) {
                    deleteAllEntries()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes saved \(title) conversations.")
            }
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            let entry = filteredEntries[index]
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }

    private func deleteAllEntries() {
        for entry in matchingModeEntries {
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }
}

private struct ConversationResumeRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.userInput.isEmpty ? entry.generatedOutput : entry.userInput)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text("\(entry.turnCount) \(entry.turnCount == 1 ? "turn" : "turns")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
