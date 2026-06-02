import Foundation

/// Stores per-mode conversation metadata used by the chat screens.
protocol ConversationStoreProtocol: Sendable {
    func loadMessages(for mode: AppMode) -> [ChatMessage]
    func saveMessages(_ messages: [ChatMessage], for mode: AppMode)
    func clearMessages(for mode: AppMode)
    func loadHistoryEntryID(for mode: AppMode) -> UUID?
    func saveHistoryEntryID(_ id: UUID, for mode: AppMode)
    func clearHistoryEntryID(for mode: AppMode)
}

final class ConversationStore: ConversationStoreProtocol {
    private struct Snapshot: Codable {
        let schemaVersion: Int
        var messages: [ChatMessage]
        var historyEntryID: UUID?
        var updatedAt: Date
    }

    private let directory: URL
    private nonisolated(unsafe) let fileManager: FileManager
    private let lock = NSLock()

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conversations", isDirectory: true)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func loadMessages(for mode: AppMode) -> [ChatMessage] {
        readSnapshot(for: mode)?.messages ?? []
    }

    func saveMessages(_ messages: [ChatMessage], for mode: AppMode) {
        updateSnapshot(for: mode) { snapshot in
            snapshot.messages = sanitize(messages)
        }
    }

    func clearMessages(for mode: AppMode) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL(for: mode))
    }

    func loadHistoryEntryID(for mode: AppMode) -> UUID? {
        readSnapshot(for: mode)?.historyEntryID
    }

    func saveHistoryEntryID(_ id: UUID, for mode: AppMode) {
        updateSnapshot(for: mode) { snapshot in
            snapshot.historyEntryID = id
        }
    }

    func clearHistoryEntryID(for mode: AppMode) {
        updateSnapshot(for: mode) { snapshot in
            snapshot.historyEntryID = nil
        }
    }

    private func readSnapshot(for mode: AppMode) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return readSnapshotUnlocked(for: mode)
    }

    private func updateSnapshot(for mode: AppMode, mutate: (inout Snapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = readSnapshotUnlocked(for: mode) ?? Snapshot(
            schemaVersion: 1,
            messages: [],
            historyEntryID: nil,
            updatedAt: Date()
        )
        mutate(&snapshot)
        snapshot.updatedAt = Date()
        writeSnapshotUnlocked(snapshot, for: mode)
    }

    private func readSnapshotUnlocked(for mode: AppMode) -> Snapshot? {
        let url = fileURL(for: mode)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }
        snapshot.messages = sanitize(snapshot.messages)
        return snapshot
    }

    private func writeSnapshotUnlocked(_ snapshot: Snapshot, for mode: AppMode) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL(for: mode), options: .atomic)
    }

    private func fileURL(for mode: AppMode) -> URL {
        directory.appendingPathComponent("\(mode.rawValue).json")
    }

    private func sanitize(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.compactMap { message in
            if message.isStreaming && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }

            guard message.isStreaming else { return message }
            return ChatMessage(
                id: message.id,
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                isStreaming: false,
                isStatusMessage: message.isStatusMessage,
                skillName: message.skillName,
                skillInstructions: message.skillInstructions,
                toolCallSkillName: message.toolCallSkillName,
                toolCallData: message.toolCallData,
                toolEvents: message.toolEvents
            )
        }
    }
}
