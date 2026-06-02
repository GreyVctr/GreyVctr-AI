import Foundation
import os

/// Manages which skills are enabled for the multi-skill chat interface.
///
/// Loads all skills (bundled + imported) via `SkillParser`, tracks enabled/disabled
/// state per skill, and persists that state to `UserDefaults`.
@Observable
final class SkillsManager {

    // MARK: - State

    /// All available skills (bundled + user-imported).
    var allSkills: [SkillDefinition] = []

    /// IDs of currently enabled skills.
    var enabledSkillIDs: Set<String> = []

    // MARK: - Computed

    /// Skills that are currently enabled, in their original order.
    var enabledSkills: [SkillDefinition] {
        allSkills.filter { enabledSkillIDs.contains($0.id) }
    }

    /// Bundled skills (IDs that don't start with "user-").
    var bundledSkills: [SkillDefinition] {
        allSkills.filter { !$0.id.hasPrefix("user-") }
    }

    /// User-imported skills (IDs that start with "user-").
    var importedSkills: [SkillDefinition] {
        allSkills.filter { $0.id.hasPrefix("user-") }
    }

    /// Number of enabled skills.
    var enabledCount: Int { enabledSkillIDs.count }

    /// Total number of available skills.
    var totalCount: Int { allSkills.count }

    /// Whether the user has exceeded the recommended max of 9 enabled skills.
    var isOverRecommendedLimit: Bool { enabledCount > 9 }

    // MARK: - Private

    private static let userDefaultsKey = "enabledSkillIDs"
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GreyVctr AI",
        category: "SkillsManager"
    )

    // MARK: - Actions

    /// Load all skills from the parser and restore persisted enabled state.
    func loadSkills(parser: SkillParserProtocol) {
        allSkills = parser.loadAllSkills()
        loadState()

        // If no persisted state exists, enable all bundled skills by default
        if enabledSkillIDs.isEmpty && !allSkills.isEmpty {
            enabledSkillIDs = Set(bundledSkills.map(\.id))
            saveState()
        }

        // Remove stale IDs that no longer match any loaded skill
        let validIDs = Set(allSkills.map(\.id))
        let staleIDs = enabledSkillIDs.subtracting(validIDs)
        if !staleIDs.isEmpty {
            enabledSkillIDs.subtract(staleIDs)
            saveState()
        }

        logger.info("Loaded \(self.allSkills.count) skills, \(self.enabledSkillIDs.count) enabled")
    }

    /// Toggle a skill's enabled state.
    func toggleSkill(_ skill: SkillDefinition) {
        if enabledSkillIDs.contains(skill.id) {
            enabledSkillIDs.remove(skill.id)
        } else {
            enabledSkillIDs.insert(skill.id)
        }
        saveState()
    }

    /// Check if a specific skill is enabled.
    func isEnabled(_ skill: SkillDefinition) -> Bool {
        enabledSkillIDs.contains(skill.id)
    }

    /// Remove a skill from the list (used after deleting an imported skill).
    func removeSkill(_ skill: SkillDefinition) {
        allSkills.removeAll { $0.id == skill.id }
        enabledSkillIDs.remove(skill.id)
        saveState()
    }

    /// Add a newly imported skill and enable it by default.
    func addSkill(_ skill: SkillDefinition) {
        allSkills.append(skill)
        enabledSkillIDs.insert(skill.id)
        saveState()
    }

    // MARK: - Persistence

    /// Save enabled skill IDs to UserDefaults.
    func saveState() {
        let array = Array(enabledSkillIDs)
        UserDefaults.standard.set(array, forKey: Self.userDefaultsKey)
    }

    /// Load enabled skill IDs from UserDefaults.
    func loadState() {
        if let array = UserDefaults.standard.stringArray(forKey: Self.userDefaultsKey) {
            enabledSkillIDs = Set(array)
        }
    }
}
