import Foundation
import SwiftData
import os

/// Manages CRUD operations for output history entries.
protocol HistoryStoreProtocol {
    /// Persist a new history entry to on-device storage.
    func save(entry: HistoryEntry) throws

    /// Create or update the single history record for an active chat conversation.
    func saveConversation(
        id: UUID,
        mode: AppMode,
        skillName: String?,
        skillId: String?,
        messages: [ChatMessage]
    ) throws

    /// Fetch all history entries, sorted by timestamp descending (newest first).
    func fetchAll() -> [HistoryEntry]

    /// Delete a specific history entry from on-device storage.
    func delete(entry: HistoryEntry) throws

    /// Delete all history entries from on-device storage.
    func deleteAll() throws
}

/// SwiftData-backed implementation of `HistoryStoreProtocol`.
///
/// Accepts a `ModelContainer` in its initializer for testability — the caller
/// (typically the app entry point) is responsible for creating and owning
/// the `ModelContainer`.
final class HistoryStore: HistoryStoreProtocol {

    private let modelContainer: ModelContainer
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GreyVctr AI",
        category: "HistoryStore"
    )

    /// Creates a store backed by the given SwiftData model container.
    /// - Parameter modelContainer: The container used to create per-operation contexts.
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - HistoryStoreProtocol

    func save(entry: HistoryEntry) throws {
        let modelContext = ModelContext(modelContainer)
        modelContext.insert(entry)
        try modelContext.save()
    }

    func saveConversation(
        id: UUID,
        mode: AppMode,
        skillName: String?,
        skillId: String?,
        messages: [ChatMessage]
    ) throws {
        let modelContext = ModelContext(modelContainer)
        let transcript = Self.transcript(from: messages)
        guard !transcript.isEmpty else { return }

        let userInput = messages
            .last { $0.role == .user }?
            .content ?? ""
        let turnCount = messages.filter { $0.role == .user }.count

        if let existing = fetchEntry(id: id, in: modelContext) {
            existing.mode = mode.rawValue
            existing.skillName = skillName
            existing.skillId = skillId
            existing.userInput = userInput
            existing.generatedOutput = transcript
            existing.timestamp = Date()
            existing.isConversation = true
            existing.turnCount = turnCount
        } else {
            let entry = HistoryEntry(
                id: id,
                mode: mode,
                skillName: skillName,
                skillId: skillId,
                userInput: userInput,
                generatedOutput: transcript,
                isConversation: true,
                turnCount: turnCount
            )
            modelContext.insert(entry)
        }

        try modelContext.save()
    }

    func fetchAll() -> [HistoryEntry] {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\HistoryEntry.timestamp, order: .reverse)]
        )
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch history entries: \(error.localizedDescription)")
            return []
        }
    }

    func delete(entry: HistoryEntry) throws {
        let modelContext = ModelContext(modelContainer)
        modelContext.delete(entry)
        try modelContext.save()
    }

    func deleteAll() throws {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<HistoryEntry>()
        let entries = try modelContext.fetch(descriptor)
        for entry in entries {
            modelContext.delete(entry)
        }
        try modelContext.save()
    }

    private func fetchEntry(id: UUID, in modelContext: ModelContext) -> HistoryEntry? {
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { entry in
                entry.id == id
            }
        )

        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            logger.error("Failed to fetch history entry \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    private static func transcript(from messages: [ChatMessage]) -> String {
        messages
            .filter {
                !$0.isStatusMessage &&
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map { message in
                let role: String
                switch message.role {
                case .user:
                    role = "User"
                case .model:
                    role = "Assistant"
                case .system:
                    role = "System"
                }

                return """
                **\(role)**

                \(message.content)
                """
            }
            .joined(separator: "\n\n---\n\n")
    }
}
