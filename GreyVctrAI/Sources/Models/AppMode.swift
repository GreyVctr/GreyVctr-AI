import Foundation

/// The three top-level interaction modes in the app.
enum AppMode: String, CaseIterable, Codable {
    case askImage = "ask_image"
    case aiChat = "ai_chat"
    case chatWithSkills = "chat_with_skills"
}
