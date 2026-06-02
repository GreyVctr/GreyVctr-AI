import Foundation

/// Manages the skill library list state.
///
/// Loads all available skill definitions from the app bundle via `SkillParser`
/// and exposes them for display in the skill list view.
@Observable
final class SkillLibraryViewModel {

    // MARK: - Published State

    /// All successfully loaded skill definitions.
    var skills: [SkillDefinition] = []

    /// User-facing error message if skill loading fails, or nil if no error.
    var loadError: String?

    // MARK: - Dependencies

    private let skillParser: SkillParserProtocol

    // MARK: - Init

    /// Creates the view model with a skill parser dependency.
    /// - Parameter skillParser: The parser used to load skill definitions from the bundle.
    init(skillParser: SkillParserProtocol) {
        self.skillParser = skillParser
    }

    // MARK: - Actions

    /// Load all skill definitions from the app bundle.
    ///
    /// Populates `skills` with valid definitions. If no skills are found,
    /// sets `loadError` with a descriptive message.
    func loadSkills() {
        loadError = nil
        let loadedSkills = skillParser.loadAllSkills()

        if loadedSkills.isEmpty {
            loadError = "No skills found in the app bundle."
        }

        skills = loadedSkills
    }
}
