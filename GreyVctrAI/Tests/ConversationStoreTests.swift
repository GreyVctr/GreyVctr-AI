import Foundation
import Testing
@testable import GreyVctrAI

@Suite("Conversation store")
struct ConversationStoreTests {
    @Test func restoresMessagesAndHistoryIDFromDisk() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationStore(directory: directory)
        let historyID = UUID()
        let messages = [
            ChatMessage(role: .user, content: "Status?"),
            ChatMessage(role: .model, content: "All systems nominal.")
        ]

        store.saveMessages(messages, for: .aiChat)
        store.saveHistoryEntryID(historyID, for: .aiChat)

        let restoredStore = ConversationStore(directory: directory)
        #expect(restoredStore.loadMessages(for: .aiChat) == messages)
        #expect(restoredStore.loadHistoryEntryID(for: .aiChat) == historyID)
    }

    @Test func storesModesIndependently() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationStore(directory: directory)
        let chatMessages = [ChatMessage(role: .user, content: "Chat")]
        let skillMessages = [ChatMessage(role: .user, content: "Skill")]

        store.saveMessages(chatMessages, for: .aiChat)
        store.saveMessages(skillMessages, for: .chatWithSkills)

        #expect(store.loadMessages(for: .aiChat) == chatMessages)
        #expect(store.loadMessages(for: .chatWithSkills) == skillMessages)
    }

    @Test func clearsSnapshotForMode() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationStore(directory: directory)
        store.saveMessages([ChatMessage(role: .user, content: "Clear me")], for: .aiChat)
        store.saveHistoryEntryID(UUID(), for: .aiChat)

        store.clearMessages(for: .aiChat)

        #expect(store.loadMessages(for: .aiChat).isEmpty)
        #expect(store.loadHistoryEntryID(for: .aiChat) == nil)
    }

    @Test func dropsEmptyStreamingPlaceholders() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationStore(directory: directory)
        let messages = [
            ChatMessage(role: .user, content: "Generate"),
            ChatMessage(role: .model, content: "", isStreaming: true),
            ChatMessage(role: .model, content: "partial", isStreaming: true)
        ]

        store.saveMessages(messages, for: .aiChat)
        let restored = store.loadMessages(for: .aiChat)

        #expect(restored.count == 2)
        #expect(restored[0].content == "Generate")
        #expect(restored[1].content == "partial")
        #expect(restored[1].isStreaming == false)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}
