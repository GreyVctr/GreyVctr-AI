import Foundation
import os

/// Parses SKILL.md files from the app bundle into SkillDefinition objects.
protocol SkillParserProtocol {
    /// Load all valid skill definitions from the app bundle and user-imported skills.
    func loadAllSkills() -> [SkillDefinition]

    /// Parse a single skill directory at the given URL.
    func parseSkill(at url: URL) -> Result<SkillDefinition, SkillParseError>

    /// Import a skill from a URL (GitHub raw URL or local file).
    func importSkill(from url: URL) async throws -> SkillDefinition

    /// Delete a user-imported skill by its ID.
    func deleteImportedSkill(id: String) throws

    /// The directory where user-imported skills are stored.
    var userSkillsDirectory: URL { get }
}

/// Scans the bundle's Skills/ directory for subdirectories containing SKILL.md,
/// parses YAML front matter and markdown body, and classifies skill types.
final class SkillParser: SkillParserProtocol {

    private let bundle: Bundle
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GreyVctr AI",
        category: "SkillParser"
    )

    /// Creates a parser that reads from the given bundle.
    /// - Parameter bundle: The bundle containing the Skills/ resource directory. Defaults to `.main`.
    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// The directory where user-imported skills are stored.
    var userSkillsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let skillsDir = docs.appendingPathComponent("Skills")
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        return skillsDir
    }

    // MARK: - SkillParserProtocol

    func loadAllSkills() -> [SkillDefinition] {
        var skills: [SkillDefinition] = []

        // 1. Load bundled skills
        skills.append(contentsOf: loadBundledSkills())

        // 2. Load user-imported skills from Documents/Skills/
        skills.append(contentsOf: loadUserSkills())

        return skills
    }

    /// Import a skill from a URL. Supports:
    /// - Direct URL to a SKILL.md file
    /// - GitHub repo URL pointing to a skill directory
    func importSkill(from url: URL) async throws -> SkillDefinition {
        let fileManager = FileManager.default

        // Download the SKILL.md content
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw SkillParseError.invalidUTF8Encoding
        }

        // Parse to get the skill name for the directory
        let (yamlString, _) = splitFrontMatter(content)
        guard let yamlString else {
            throw SkillParseError.invalidYAMLFrontMatter(reason: "Missing YAML front matter")
        }
        let fields = parseYAML(yamlString)
        guard let name = fields["name"], !name.isEmpty else {
            throw SkillParseError.missingRequiredField(field: "name")
        }

        // Create a directory for this skill
        let skillDir = userSkillsDirectory.appendingPathComponent(name)
        try fileManager.createDirectory(at: skillDir, withIntermediateDirectories: true)

        // Save the SKILL.md file
        let skillMDPath = skillDir.appendingPathComponent("SKILL.md")
        try data.write(to: skillMDPath)

        logger.info("Imported skill '\(name)' to \(skillDir.path)")

        // Parse and return the skill
        switch parseSkill(at: skillDir) {
        case .success(let skill):
            return skill
        case .failure(let error):
            throw error
        }
    }

    /// Delete a user-imported skill by removing its directory.
    func deleteImportedSkill(id: String) throws {
        // Strip the "user-" prefix to get the actual directory name
        let dirName = id.hasPrefix("user-") ? String(id.dropFirst(5)) : id
        let skillDir = userSkillsDirectory.appendingPathComponent(dirName)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: skillDir.path) {
            try fileManager.removeItem(at: skillDir)
            logger.info("Deleted imported skill: \(dirName)")
        }
    }

    // MARK: - Private Loading

    private func loadBundledSkills() -> [SkillDefinition] {
        let fileManager = FileManager.default

        // The skill directories are copied individually into the bundle root.
        // Look for known skill directory names, or scan for any directory containing SKILL.md.
        let knownSkillDirs = [
            "aar-hotwash-assistant",
            "crew-chief-shift-turnover",
            "dsca-shift-change-assistant",
            "grid-converter",
            "readiness-packet-builder",
            "risk-matrix-helper",
        ]

        var skills: [SkillDefinition] = []

        // First try known skill names in the bundle
        for skillName in knownSkillDirs {
            if let skillURL = bundle.url(forResource: skillName, withExtension: nil) {
                let skillMDURL = skillURL.appendingPathComponent("SKILL.md")
                if fileManager.fileExists(atPath: skillMDURL.path) {
                    switch parseSkill(at: skillURL) {
                    case .success(let skill):
                        skills.append(skill)
                        logger.info("Loaded bundled skill: \(skill.name)")
                    case .failure(let error):
                        logger.error("Failed to parse bundled skill \(skillName): \(error)")
                    }
                }
            }
        }

        // Also try the Skills/ directory approach as fallback
        if skills.isEmpty {
            let possibleURLs: [URL?] = [
                bundle.url(forResource: "Skills", withExtension: nil),
                bundle.resourceURL?.appendingPathComponent("Skills"),
            ]

            for candidate in possibleURLs.compactMap({ $0 }) {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    if let subdirs = try? fileManager.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) {
                        for dirURL in subdirs {
                            var subIsDir: ObjCBool = false
                            guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &subIsDir),
                                  subIsDir.boolValue else { continue }
                            let skillMD = dirURL.appendingPathComponent("SKILL.md")
                            guard fileManager.fileExists(atPath: skillMD.path) else { continue }
                            switch parseSkill(at: dirURL) {
                            case .success(let skill):
                                skills.append(skill)
                            case .failure(let error):
                                logger.error("Skipping skill: \(error)")
                            }
                        }
                    }
                    if !skills.isEmpty { break }
                }
            }
        }

        if skills.isEmpty {
            logger.warning("No bundled skills found")
        } else {
            logger.info("Loaded \(skills.count) bundled skills")
        }

        return skills
    }

    private func loadUserSkills() -> [SkillDefinition] {
        let fileManager = FileManager.default
        let userDir = userSkillsDirectory

        guard let subdirectories = try? fileManager.contentsOfDirectory(
            at: userDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var skills: [SkillDefinition] = []
        for directoryURL in subdirectories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let skillMDURL = directoryURL.appendingPathComponent("SKILL.md")
            guard fileManager.fileExists(atPath: skillMDURL.path) else {
                continue
            }

            switch parseSkill(at: directoryURL) {
            case .success(var skill):
                // Mark user-imported skills with a prefix to distinguish them
                    skill = SkillDefinition(
                        id: "user-\(skill.id)",
                        name: skill.name,
                        description: skill.description,
                        instructions: skill.instructions,
                        skillType: skill.skillType,
                        jsContent: skill.jsContent,
                        assetPaths: skill.assetPaths,
                        webViewContent: skill.webViewContent
                    )
                skills.append(skill)
            case .failure(let error):
                logger.error("Skipping user skill at \(directoryURL.lastPathComponent): \(error)")
            }
        }

        return skills
    }

    func parseSkill(at url: URL) -> Result<SkillDefinition, SkillParseError> {
        let skillID = url.lastPathComponent
        let skillMDURL = url.appendingPathComponent("SKILL.md")

        // 1. Read file contents as UTF-8 string
        let contents: String
        do {
            let data = try Data(contentsOf: skillMDURL)
            guard let string = String(data: data, encoding: .utf8) else {
                return .failure(.invalidUTF8Encoding)
            }
            contents = string
        } catch {
            return .failure(.fileNotFound(path: skillMDURL.path))
        }

        // 2. Split on `---` delimiters to separate YAML front matter from markdown body
        let (yamlString, markdownBody) = splitFrontMatter(contents)

        guard let yamlString else {
            return .failure(.invalidYAMLFrontMatter(reason: "Missing YAML front matter delimiters"))
        }

        // 3. Parse YAML front matter for `name` and `description`
        let yamlFields = parseYAML(yamlString)

        guard let name = yamlFields["name"], !name.isEmpty else {
            return .failure(.missingRequiredField(field: "name"))
        }
        guard let description = yamlFields["description"], !description.isEmpty else {
            return .failure(.missingRequiredField(field: "description"))
        }

        // 4. The remaining markdown body is the skill's instructions
        let instructions = markdownBody.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Check for scripts/index.html companion file
        let scriptsURL = url.appendingPathComponent("scripts").appendingPathComponent("index.html")
        let fileManager = FileManager.default
        let skillType: SkillType
        let jsContent: String?
        let assetPaths = loadAssetPaths(from: url)
        let webViewContent = loadWebViewContent(from: url)

        if fileManager.fileExists(atPath: scriptsURL.path) {
            skillType = .jsBacked
            jsContent = try? String(contentsOf: scriptsURL, encoding: .utf8)
        } else {
            skillType = .textOnly
            jsContent = nil
        }

        // 6. Return a SkillDefinition with all extracted fields
        let skill = SkillDefinition(
            id: skillID,
            name: name,
            description: description,
            instructions: instructions,
            skillType: skillType,
            jsContent: jsContent,
            assetPaths: assetPaths,
            webViewContent: webViewContent
        )

        return .success(skill)
    }

    // MARK: - Private Parsing Helpers

    /// Splits a SKILL.md file's contents into YAML front matter and markdown body.
    ///
    /// The expected format is:
    /// ```
    /// ---
    /// name: value
    /// description: value
    /// ---
    /// markdown body...
    /// ```
    ///
    /// - Returns: A tuple of (yamlString, markdownBody). `yamlString` is nil if delimiters are missing.
    func splitFrontMatter(_ contents: String) -> (String?, String) {
        let delimiter = "---"
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix(delimiter) else {
            return (nil, contents)
        }

        // Remove the leading "---" and find the closing "---"
        let afterFirstDelimiter = String(trimmed.dropFirst(delimiter.count))
        guard let closingRange = afterFirstDelimiter.range(of: "\n\(delimiter)") ??
              afterFirstDelimiter.range(of: "\r\n\(delimiter)") else {
            return (nil, contents)
        }

        let yamlString = String(afterFirstDelimiter[afterFirstDelimiter.startIndex..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdownBody = String(afterFirstDelimiter[closingRange.upperBound...])

        return (yamlString, markdownBody)
    }

    /// Parses simple YAML key-value pairs from a string.
    ///
    /// Handles multi-line values where continuation lines don't start with a new key.
    /// For example:
    /// ```
    /// name: my-skill
    /// description: A long description that
    /// wraps to the next line.
    /// ```
    func parseYAML(_ yaml: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?
        var currentValue: String = ""

        for line in yaml.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }

            // Check if this line starts a new key: value pair
            if let colonIndex = trimmedLine.firstIndex(of: ":") {
                let potentialKey = String(trimmedLine[trimmedLine.startIndex..<colonIndex])
                    .trimmingCharacters(in: .whitespaces)

                // Only treat as a new key if the key part has no spaces (simple YAML keys)
                if !potentialKey.isEmpty && !potentialKey.contains(" ") {
                    // Save previous key-value pair
                    if let key = currentKey {
                        result[key] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    currentKey = potentialKey
                    let valueStart = trimmedLine.index(after: colonIndex)
                    currentValue = String(trimmedLine[valueStart...])
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
            }

            // Continuation line for the current key's value
            if currentKey != nil {
                currentValue += " " + trimmedLine
            }
        }

        // Save the last key-value pair
        if let key = currentKey {
            result[key] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    private func loadAssetPaths(from skillURL: URL) -> [String] {
        let assetsURL = skillURL.appendingPathComponent("assets")
        guard let enumerator = FileManager.default.enumerator(
            at: assetsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(of: skillURL.path + "/", with: "")
            paths.append(relativePath)
        }
        return paths.sorted()
    }

    private func loadWebViewContent(from skillURL: URL) -> String? {
        let candidates = [
            skillURL.appendingPathComponent("assets").appendingPathComponent("webview.html"),
            skillURL.appendingPathComponent("assets").appendingPathComponent("ui.html")
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try? String(contentsOf: candidate, encoding: .utf8)
        }

        return nil
    }
}
