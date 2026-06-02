import Foundation
import SwiftData

/// A persisted output history entry. Supports all three app modes.
@Model
final class HistoryEntry {
    /// Unique identifier for this history entry.
    @Attribute(.unique) var id: UUID
    /// The app mode used: "ask_image", "ai_chat", or "chat_with_skills".
    var mode: String
    /// Name of the skill used (nil for non-skill modes).
    var skillName: String?
    /// ID of the skill used (nil for non-skill modes).
    var skillId: String?
    /// Original user input text.
    var userInput: String
    /// Full LLM-generated output.
    var generatedOutput: String
    /// When the output was generated.
    var timestamp: Date
    /// True when this entry represents a full chat conversation instead of one generated response.
    var isConversation: Bool = false
    /// Number of user turns represented by this entry.
    var turnCount: Int = 1

    /// Create a new history entry.
    /// - Parameters:
    ///   - mode: The app mode that produced this output.
    ///   - skillName: Name of the skill (nil for Ask Image / AI Chat).
    ///   - skillId: ID of the skill (nil for Ask Image / AI Chat).
    ///   - userInput: The original user input text.
    ///   - generatedOutput: The full LLM-generated output.
    init(
        id: UUID = UUID(),
        mode: AppMode,
        skillName: String? = nil,
        skillId: String? = nil,
        userInput: String,
        generatedOutput: String,
        isConversation: Bool = false,
        turnCount: Int = 1
    ) {
        self.id = id
        self.mode = mode.rawValue
        self.skillName = skillName
        self.skillId = skillId
        self.userInput = userInput
        self.generatedOutput = generatedOutput
        self.timestamp = Date()
        self.isConversation = isConversation
        self.turnCount = turnCount
    }
}
