import Foundation

/// A single message in an AI Chat conversation.
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    let isStreaming: Bool
    let isStatusMessage: Bool
    let skillName: String?
    let skillInstructions: String?
    let toolCallSkillName: String?
    let toolCallData: String?
    let toolEvents: [SkillToolEvent]

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isStatusMessage: Bool = false,
        skillName: String? = nil,
        skillInstructions: String? = nil,
        toolCallSkillName: String? = nil,
        toolCallData: String? = nil,
        toolEvents: [SkillToolEvent] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isStatusMessage = isStatusMessage
        self.skillName = skillName
        self.skillInstructions = skillInstructions
        self.toolCallSkillName = toolCallSkillName
        self.toolCallData = toolCallData
        self.toolEvents = toolEvents
    }
}

struct SkillToolEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let detail: String?
    let data: String?

    init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        data: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.data = data
    }
}

/// The role of a message sender in a conversation.
enum MessageRole: String, Codable {
    case user
    case model
    case system
}
