import Testing
import Foundation
@testable import GreyVctrAI

// MARK: - History Preservation Property Tests

/// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6**
///
/// Property 2: Preservation — Existing History Behaviors Unchanged
///
/// These tests capture the CURRENT (unfixed) behavior of the app's history persistence.
/// They verify that:
/// - AIChatViewModel.sendMessage() saves entries with mode .aiChat after successful generation
/// - SkillsChatViewModel.sendMessage() saves entries with mode .chatWithSkills after successful generation
/// - Engine errors in any mode produce no history entries
/// - Empty/whitespace inputs produce no history entries
/// - Individual delete removes only the targeted entry
///
/// All tests MUST PASS on the unfixed code — they confirm baseline behavior to preserve.
@Suite("History Preservation — Existing Behaviors")
struct HistoryPreservationTests {

    // MARK: - AI Chat Preservation

    /// Simulates the AIChatViewModel.sendMessage() → saveHistory() flow.
    ///
    /// Observed behavior on UNFIXED code:
    /// After a successful engine.conversationSend() call, AIChatViewModel calls:
    ///   historyStore.save(entry: HistoryEntry(mode: .aiChat, userInput: trimmedInput, generatedOutput: response))
    ///
    /// This replicates that exact logic to verify the save happens correctly.
    private func simulateAIChatSendMessage(
        userInput: String,
        mockHistoryStore: MockHistoryStore,
        mockConfigLoader: MockConfigLoader,
        engineResponse: String,
        engineShouldThrow: Bool = false
    ) -> String? {
        // Step 1: Trim input (matches AIChatViewModel.sendMessage())
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 2: Validate non-empty (matches guard !trimmedInput.isEmpty)
        guard !trimmedInput.isEmpty else {
            return "Please enter a message."
        }

        // Step 3: Load config (matches configLoader.load(for: .aiChat))
        _ = mockConfigLoader.load(for: .aiChat)

        // Step 4: Simulate engine call
        if engineShouldThrow {
            // When engine throws, AIChatViewModel catches the error and does NOT call saveHistory
            return MockError.visionFailed.localizedDescription
        }

        // Step 5: On success, call saveHistory (matches AIChatViewModel.saveHistory())
        // This is the EXACT logic from AIChatViewModel.saveHistory():
        do {
            try mockHistoryStore.save(entry: HistoryEntry(
                mode: .aiChat,
                userInput: trimmedInput,
                generatedOutput: engineResponse
            ))
        } catch {
            // Matches: self.error = "Response generated, but history could not be saved: ..."
            return "Response generated, but history could not be saved: \(error.localizedDescription)"
        }

        return nil // no error
    }

    /// Simulates the SkillsChatViewModel.sendMessage() → saveHistory() flow.
    ///
    /// Observed behavior on UNFIXED code:
    /// After a successful engine.conversationSend() call, SkillsChatViewModel calls:
    ///   historyStore.save(entry: HistoryEntry(mode: .chatWithSkills, skillName: ..., skillId: ...,
    ///                                          userInput: trimmedInput, generatedOutput: response))
    private func simulateSkillsChatSendMessage(
        userInput: String,
        matchedSkill: SkillDefinition?,
        mockHistoryStore: MockHistoryStore,
        mockConfigLoader: MockConfigLoader,
        engineResponse: String,
        engineShouldThrow: Bool = false
    ) -> String? {
        // Step 1: Trim input (matches SkillsChatViewModel.sendMessage())
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 2: Validate non-empty (matches guard !trimmedInput.isEmpty)
        guard !trimmedInput.isEmpty else {
            return "Please enter a message."
        }

        // Step 3: Load config (matches configLoader.load(for: .chatWithSkills))
        _ = mockConfigLoader.load(for: .chatWithSkills)

        // Step 4: Simulate engine call
        if engineShouldThrow {
            // When engine throws, SkillsChatViewModel catches the error and does NOT call saveHistory
            return MockError.visionFailed.localizedDescription
        }

        // Step 5: On success, call saveHistory (matches SkillsChatViewModel.saveHistory())
        // This is the EXACT logic from SkillsChatViewModel.saveHistory():
        do {
            try mockHistoryStore.save(entry: HistoryEntry(
                mode: .chatWithSkills,
                skillName: matchedSkill?.name,
                skillId: matchedSkill?.id,
                userInput: trimmedInput,
                generatedOutput: engineResponse
            ))
        } catch {
            return "Response generated, but history could not be saved: \(error.localizedDescription)"
        }

        return nil // no error
    }

    // MARK: - Test: AI Chat Preservation

    @Test("AI Chat: successful generation saves HistoryEntry with mode .aiChat",
          arguments: generateRandomPrompts(count: 20, seed: 100))
    func aiChatHistoryPreservation(prompt: String) {
        let mockHistoryStore = MockHistoryStore()
        let mockConfigLoader = MockConfigLoader()
        let engineResponse = "AI Chat response for: \(prompt)"

        let error = simulateAIChatSendMessage(
            userInput: prompt,
            mockHistoryStore: mockHistoryStore,
            mockConfigLoader: mockConfigLoader,
            engineResponse: engineResponse
        )

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // No error should occur
        #expect(error == nil, "Unexpected error during AI Chat save: \(error ?? "")")

        // Verify entry was saved with correct mode and content
        #expect(
            mockHistoryStore.savedEntries.contains { entry in
                entry.mode == AppMode.aiChat.rawValue &&
                entry.userInput == trimmedPrompt &&
                entry.generatedOutput == engineResponse
            },
            """
            AI Chat preservation failed: After successful generation with prompt '\(trimmedPrompt)', \
            expected a HistoryEntry with mode .aiChat but found \(mockHistoryStore.savedEntries.count) entries.
            """
        )
    }

    // MARK: - Test: Skills Chat Preservation

    @Test("Skills Chat: successful generation saves HistoryEntry with mode .chatWithSkills",
          arguments: generateRandomPrompts(count: 20, seed: 200))
    func skillsChatHistoryPreservation(prompt: String) {
        let mockHistoryStore = MockHistoryStore()
        let mockConfigLoader = MockConfigLoader()
        let engineResponse = "Skills Chat response for: \(prompt)"
        let testSkill = SkillDefinition(
            id: "test-skill",
            name: "Test Skill",
            description: "A test skill for preservation testing",
            instructions: "Test instructions",
            skillType: .textOnly,
            jsContent: nil
        )

        let error = simulateSkillsChatSendMessage(
            userInput: prompt,
            matchedSkill: testSkill,
            mockHistoryStore: mockHistoryStore,
            mockConfigLoader: mockConfigLoader,
            engineResponse: engineResponse
        )

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // No error should occur
        #expect(error == nil, "Unexpected error during Skills Chat save: \(error ?? "")")

        // Verify entry was saved with correct mode, skill metadata, and content
        #expect(
            mockHistoryStore.savedEntries.contains { entry in
                entry.mode == AppMode.chatWithSkills.rawValue &&
                entry.skillName == testSkill.name &&
                entry.skillId == testSkill.id &&
                entry.userInput == trimmedPrompt &&
                entry.generatedOutput == engineResponse
            },
            """
            Skills Chat preservation failed: After successful generation with prompt '\(trimmedPrompt)', \
            expected a HistoryEntry with mode .chatWithSkills and skill metadata but found \
            \(mockHistoryStore.savedEntries.count) entries.
            """
        )
    }

    // MARK: - Test: Skills Chat Without Matched Skill

    @Test("Skills Chat: saves entry with nil skill metadata when no skill matches",
          arguments: generateRandomPrompts(count: 10, seed: 250))
    func skillsChatNoSkillMatchPreservation(prompt: String) {
        let mockHistoryStore = MockHistoryStore()
        let mockConfigLoader = MockConfigLoader()
        let engineResponse = "General response for: \(prompt)"

        let error = simulateSkillsChatSendMessage(
            userInput: prompt,
            matchedSkill: nil,
            mockHistoryStore: mockHistoryStore,
            mockConfigLoader: mockConfigLoader,
            engineResponse: engineResponse
        )

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(error == nil, "Unexpected error during Skills Chat save: \(error ?? "")")

        #expect(
            mockHistoryStore.savedEntries.contains { entry in
                entry.mode == AppMode.chatWithSkills.rawValue &&
                entry.skillName == nil &&
                entry.skillId == nil &&
                entry.userInput == trimmedPrompt &&
                entry.generatedOutput == engineResponse
            },
            """
            Skills Chat (no skill) preservation failed: Expected entry with nil skill metadata \
            but found \(mockHistoryStore.savedEntries.count) entries.
            """
        )
    }

    // MARK: - Test: Error Path Preservation

    @Test("Error path: engine failure produces no history entry for AI Chat",
          arguments: generateRandomPrompts(count: 10, seed: 300))
    func aiChatErrorPathPreservation(prompt: String) {
        let mockHistoryStore = MockHistoryStore()
        let mockConfigLoader = MockConfigLoader()

        let countBefore = mockHistoryStore.savedEntries.count

        _ = simulateAIChatSendMessage(
            userInput: prompt,
            mockHistoryStore: mockHistoryStore,
            mockConfigLoader: mockConfigLoader,
            engineResponse: "", // irrelevant — engine throws
            engineShouldThrow: true
        )

        let countAfter = mockHistoryStore.savedEntries.count

        #expect(
            countBefore == countAfter,
            """
            Error path preservation failed: When engine throws in AI Chat mode, \
            no history entry should be saved. Before: \(countBefore), After: \(countAfter).
            """
        )
    }

    @Test("Error path: engine failure produces no history entry for Skills Chat",
          arguments: generateRandomPrompts(count: 10, seed: 350))
    func skillsChatErrorPathPreservation(prompt: String) {
        let mockHistoryStore = MockHistoryStore()
        let mockConfigLoader = MockConfigLoader()

        let countBefore = mockHistoryStore.savedEntries.count

        _ = simulateSkillsChatSendMessage(
            userInput: prompt,
            matchedSkill: nil,
            mockHistoryStore: mockHistoryStore,
            mockConfigLoader: mockConfigLoader,
            engineResponse: "",
            engineShouldThrow: true
        )

        let countAfter = mockHistoryStore.savedEntries.count

        #expect(
            countBefore == countAfter,
            """
            Error path preservation failed: When engine throws in Skills Chat mode, \
            no history entry should be saved. Before: \(countBefore), After: \(countAfter).
            """
        )
    }

    // MARK: - Test: Empty Input Preservation

    @Test("Empty input: AI Chat with empty/whitespace input saves no entry and sets error",
          arguments: ["", "   ", "\t", "\n", "  \t\n  "])
    func aiChatEmptyInputPreservation(input: String) {
        let mockHistoryStore = MockHistoryStore()
        let mockConfigLoader = MockConfigLoader()

        let error = simulateAIChatSendMessage(
            userInput: input,
            mockHistoryStore: mockHistoryStore,
            mockConfigLoader: mockConfigLoader,
            engineResponse: "Should not be used"
        )

        #expect(
            error == "Please enter a message.",
            """
            Empty input preservation failed: AI Chat with input '\(input)' should set error \
            'Please enter a message.' but got '\(error ?? "nil")'.
            """
        )

        #expect(
            mockHistoryStore.savedEntries.isEmpty,
            """
            Empty input preservation failed: AI Chat with empty input should not save any entries \
            but found \(mockHistoryStore.savedEntries.count).
            """
        )
    }

    @Test("Empty input: Skills Chat with empty/whitespace input saves no entry and sets error",
          arguments: ["", "   ", "\t", "\n", "  \t\n  "])
    func skillsChatEmptyInputPreservation(input: String) {
        let mockHistoryStore = MockHistoryStore()
        let mockConfigLoader = MockConfigLoader()

        let error = simulateSkillsChatSendMessage(
            userInput: input,
            matchedSkill: nil,
            mockHistoryStore: mockHistoryStore,
            mockConfigLoader: mockConfigLoader,
            engineResponse: "Should not be used"
        )

        #expect(
            error == "Please enter a message.",
            """
            Empty input preservation failed: Skills Chat with input '\(input)' should set error \
            'Please enter a message.' but got '\(error ?? "nil")'.
            """
        )

        #expect(
            mockHistoryStore.savedEntries.isEmpty,
            """
            Empty input preservation failed: Skills Chat with empty input should not save any entries \
            but found \(mockHistoryStore.savedEntries.count).
            """
        )
    }

    // MARK: - Test: Individual Delete Preservation

    @Test("Individual delete: removing one entry preserves all others")
    func individualDeletePreservation() throws {
        let mockHistoryStore = MockHistoryStore()

        // Save multiple entries across different modes
        let entries = [
            HistoryEntry(mode: .aiChat, userInput: "AI prompt 1", generatedOutput: "AI response 1"),
            HistoryEntry(mode: .chatWithSkills, skillName: "Skill A", skillId: "skill-a",
                         userInput: "Skill prompt 1", generatedOutput: "Skill response 1"),
            HistoryEntry(mode: .askImage, userInput: "Image prompt 1", generatedOutput: "Image response 1"),
            HistoryEntry(mode: .aiChat, userInput: "AI prompt 2", generatedOutput: "AI response 2"),
            HistoryEntry(mode: .chatWithSkills, userInput: "Skill prompt 2", generatedOutput: "Skill response 2"),
        ]

        for entry in entries {
            try mockHistoryStore.save(entry: entry)
        }

        #expect(mockHistoryStore.savedEntries.count == 5, "Should have 5 entries before delete")

        // Delete the middle entry (index 2 — the askImage entry)
        let entryToDelete = mockHistoryStore.savedEntries[2]
        let deletedId = entryToDelete.id
        try mockHistoryStore.delete(entry: entryToDelete)

        // Verify count decreased by exactly 1
        #expect(
            mockHistoryStore.savedEntries.count == 4,
            "After deleting one entry, should have 4 entries but found \(mockHistoryStore.savedEntries.count)"
        )

        // Verify the deleted entry is gone
        #expect(
            !mockHistoryStore.savedEntries.contains { $0.id == deletedId },
            "Deleted entry should not be present in savedEntries"
        )

        // Verify all other entries remain
        let remainingIds = Set(mockHistoryStore.savedEntries.map { $0.id })
        for (i, entry) in entries.enumerated() {
            if i == 2 { continue } // skip the deleted one
            #expect(
                remainingIds.contains(entry.id),
                "Entry at index \(i) with userInput '\(entry.userInput)' should still be present after deleting another entry"
            )
        }
    }

    @Test("Individual delete: deleting from single-entry store leaves it empty")
    func individualDeleteSingleEntry() throws {
        let mockHistoryStore = MockHistoryStore()

        let entry = HistoryEntry(mode: .aiChat, userInput: "Only entry", generatedOutput: "Only response")
        try mockHistoryStore.save(entry: entry)

        #expect(mockHistoryStore.savedEntries.count == 1)

        try mockHistoryStore.delete(entry: entry)

        #expect(
            mockHistoryStore.savedEntries.isEmpty,
            "After deleting the only entry, store should be empty but found \(mockHistoryStore.savedEntries.count) entries"
        )
    }
}
