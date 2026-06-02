import Foundation

/// Errors that can occur during SKILL.md parsing.
enum SkillParseError: Error, Equatable {
    /// The SKILL.md file was not found at the expected path.
    case fileNotFound(path: String)
    /// The YAML front matter is malformed or unparseable.
    case invalidYAMLFrontMatter(reason: String)
    /// A required field (e.g., name, description) is missing from the front matter.
    case missingRequiredField(field: String)
    /// The file contents could not be decoded as UTF-8.
    case invalidUTF8Encoding
}
