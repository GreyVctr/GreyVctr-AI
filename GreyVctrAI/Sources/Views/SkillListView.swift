import SwiftUI
import UniformTypeIdentifiers

/// Displays a list of available Guard skills with local file import capability.
struct SkillListView: View {
    @Environment(AppState.self) private var appState
    @State private var skills: [SkillDefinition] = []
    @State private var loadError: String?
    @State private var showFileImporter = false
    @State private var importError: String?

    var body: some View {
        Group {
            if let errorMessage = loadError {
                ContentUnavailableView {
                    Label("No Skills", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else if skills.isEmpty {
                ContentUnavailableView {
                    Label("Loading…", systemImage: "arrow.clockwise")
                } description: {
                    Text("Loading skill definitions…")
                }
            } else {
                skillList
            }
        }
        .navigationTitle("Skills")
        .onAppear { loadSkills() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import from Files", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus.circle")
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

    // MARK: - Skill List

    private var skillList: some View {
        List {
            let bundled = skills.filter { !$0.id.hasPrefix("user-") }
            let imported = skills.filter { $0.id.hasPrefix("user-") }

            if !bundled.isEmpty {
                Section("Bundled Skills (\(bundled.count))") {
                    ForEach(bundled) { skill in
                        NavigationLink(destination: SkillDetailView(skill: skill)) {
                            SkillRow(skill: skill)
                        }
                    }
                }
            }

            if !imported.isEmpty {
                Section("Imported Skills (\(imported.count))") {
                    ForEach(imported) { skill in
                        NavigationLink(destination: SkillDetailView(skill: skill)) {
                            SkillRow(skill: skill)
                        }
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
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - Actions

    private func loadSkills() {
        let parser = appState.dependencies?.skillParser ?? SkillParser()
        let loaded = parser.loadAllSkills()
        if loaded.isEmpty {
            loadError = "No skills found."
        } else {
            loadError = nil
        }
        skills = loaded
    }

    private func deleteImportedSkill(_ skill: SkillDefinition) {
        let parser = appState.dependencies?.skillParser ?? SkillParser()
        do {
            try parser.deleteImportedSkill(id: skill.id)
            loadSkills()
        } catch {
            importError = "Failed to delete skill: \(error.localizedDescription)"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Permission denied to access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let parser = appState.dependencies?.skillParser ?? SkillParser()
            let fileManager = FileManager.default

            // Check if it's a directory containing SKILL.md or a SKILL.md file itself
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)

            let sourceDir: URL
            if isDir.boolValue {
                // It's a skill directory — check for SKILL.md inside
                let skillMD = url.appendingPathComponent("SKILL.md")
                guard fileManager.fileExists(atPath: skillMD.path) else {
                    importError = "Selected folder doesn't contain a SKILL.md file."
                    return
                }
                sourceDir = url
            } else if url.lastPathComponent == "SKILL.md" {
                // It's a SKILL.md file — use its parent directory
                sourceDir = url.deletingLastPathComponent()
            } else {
                importError = "Please select a folder containing SKILL.md or a SKILL.md file."
                return
            }

            // Copy the skill directory to the user skills directory
            let skillName = sourceDir.lastPathComponent
            let destDir = parser.userSkillsDirectory.appendingPathComponent(skillName)

            do {
                if fileManager.fileExists(atPath: destDir.path) {
                    try fileManager.removeItem(at: destDir)
                }
                try fileManager.copyItem(at: sourceDir, to: destDir)

                // Reload skills
                loadSkills()
            } catch {
                importError = "Failed to import skill: \(error.localizedDescription)"
            }

        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

// MARK: - Skill Row

struct SkillRow: View {
    let skill: SkillDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(skill.name)
                    .font(.headline)

                if skill.skillType == .jsBacked {
                    Image(systemName: "gearshape.2")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Text(skill.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SkillListView()
    }
    .environment(AppState())
}
#endif
