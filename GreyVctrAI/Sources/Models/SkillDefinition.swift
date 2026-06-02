import Foundation

/// A parsed skill definition from a SKILL.md file.
struct SkillDefinition: Identifiable, Codable, Equatable {
    /// Directory name (e.g., "risk-matrix-helper").
    let id: String
    /// From YAML front matter "name" field.
    let name: String
    /// From YAML front matter "description" field.
    let description: String
    /// Full markdown body (instructions, examples, output formats, guardrails).
    let instructions: String
    /// Whether this skill is text-only or JavaScript-backed.
    let skillType: SkillType
    /// Contents of scripts/index.html (nil for text-only skills).
    let jsContent: String?
    /// Relative asset paths bundled with the skill.
    let assetPaths: [String]
    /// Contents of assets/webview.html or assets/ui.html, if present.
    let webViewContent: String?

    init(
        id: String,
        name: String,
        description: String,
        instructions: String,
        skillType: SkillType,
        jsContent: String?,
        assetPaths: [String] = [],
        webViewContent: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.skillType = skillType
        self.jsContent = jsContent
        self.assetPaths = assetPaths
        self.webViewContent = webViewContent
    }
}

/// Classification of a skill's execution type.
enum SkillType: String, Codable, Equatable {
    /// Pure LLM prompt — no companion script.
    case textOnly = "text_only"
    /// Includes a companion JavaScript file for computation.
    case jsBacked = "js_backed"
}
