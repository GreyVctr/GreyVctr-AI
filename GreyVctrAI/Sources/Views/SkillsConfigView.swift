import SwiftUI
import UniformTypeIdentifiers

/// Configuration screen for enabling/disabling skills and importing new ones.
///
/// Presented as a sheet from SkillsChatView. Shows all bundled and imported skills
/// with toggle switches, supports importing from local files, and warns when
/// more than 9 skills are enabled.
struct SkillsConfigView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Status Header
                statusSection

                // MARK: - Warning Banner
                if appState.skillsManager.isOverRecommendedLimit {
                    warningBanner
                }

                // MARK: - Bundled Skills
                if !appState.skillsManager.bundledSkills.isEmpty {
                    bundledSection
                }

                // MARK: - Imported Skills
                if !appState.skillsManager.importedSkills.isEmpty {
                    importedSection
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Skills Config")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import skill")
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.folder, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Import Error", isPresented: .init(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("\(appState.skillsManager.enabledCount) of \(appState.skillsManager.totalCount) skills enabled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var warningBanner: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Too many skills enabled")
                        .font(.subheadline.weight(.semibold))
                    Text("Google recommends a maximum of 9 skills at a time for best results. You have \(appState.skillsManager.enabledCount) enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var bundledSection: some View {
        Section("Bundled Skills (\(appState.skillsManager.bundledSkills.count))") {
            ForEach(appState.skillsManager.bundledSkills) { skill in
                skillToggleRow(skill: skill)
            }
        }
    }

    private var importedSection: some View {
        Section("Imported Skills (\(appState.skillsManager.importedSkills.count))") {
            ForEach(appState.skillsManager.importedSkills) { skill in
                skillToggleRow(skill: skill)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteImportedSkill(skill)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    // MARK: - Row

    private func skillToggleRow(skill: SkillDefinition) -> some View {
        Toggle(isOn: Binding(
            get: { appState.skillsManager.isEnabled(skill) },
            set: { _ in appState.skillsManager.toggleSkill(skill) }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(skill.name)
                            .font(.body)

                        if skill.skillType == .jsBacked {
                            Image(systemName: "gearshape.2")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)

                Spacer()

                NavigationLink(destination: SkillDetailView(skill: skill, readOnly: true)) {
                    Text("View")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("View skill details for \(skill.name)")
            }
        }
    }

    // MARK: - Actions

    private func deleteImportedSkill(_ skill: SkillDefinition) {
        let parser = appState.dependencies?.skillParser ?? SkillParser()
        do {
            try parser.deleteImportedSkill(id: skill.id)
            appState.skillsManager.removeSkill(skill)
        } catch {
            importError = "Failed to delete skill: \(error.localizedDescription)"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                importError = "Permission denied to access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let parser = appState.dependencies?.skillParser ?? SkillParser()
            let fileManager = FileManager.default

            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)

            let sourceDir: URL
            if isDir.boolValue {
                let skillMD = url.appendingPathComponent("SKILL.md")
                guard fileManager.fileExists(atPath: skillMD.path) else {
                    importError = "Selected folder doesn't contain a SKILL.md file."
                    return
                }
                sourceDir = url
            } else if url.lastPathComponent == "SKILL.md" {
                sourceDir = url.deletingLastPathComponent()
            } else {
                importError = "Please select a folder containing SKILL.md or a SKILL.md file."
                return
            }

            let skillName = sourceDir.lastPathComponent
            let destDir = parser.userSkillsDirectory.appendingPathComponent(skillName)

            do {
                if fileManager.fileExists(atPath: destDir.path) {
                    try fileManager.removeItem(at: destDir)
                }
                try fileManager.copyItem(at: sourceDir, to: destDir)

                // Parse the newly imported skill and add it to the manager
                let result = parser.parseSkill(at: destDir)
                switch result {
                case .success(let parsedSkill):
                    let importedSkill = SkillDefinition(
                        id: "user-\(parsedSkill.id)",
                        name: parsedSkill.name,
                        description: parsedSkill.description,
                        instructions: parsedSkill.instructions,
                        skillType: parsedSkill.skillType,
                        jsContent: parsedSkill.jsContent,
                        assetPaths: parsedSkill.assetPaths,
                        webViewContent: parsedSkill.webViewContent
                    )
                    appState.skillsManager.addSkill(importedSkill)
                case .failure(let parseError):
                    importError = "Failed to parse imported skill: \(parseError)"
                }
            } catch {
                importError = "Failed to import skill: \(error.localizedDescription)"
            }

        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview {
    SkillsConfigView()
        .environment(AppState())
}
#endif
