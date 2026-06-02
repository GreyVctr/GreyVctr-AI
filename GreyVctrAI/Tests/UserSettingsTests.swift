import Testing
@testable import GreyVctrAI

@Suite("User settings")
struct UserSettingsTests {
    @Test func effectiveSystemPromptKeepsDefaultAndAppendsPerModePrompt() {
        let settings = UserSettings()
        defer { resetSettings(settings) }

        settings.globalSystemPrompt = "Global instructions"
        settings.aiChatSystemPrompt = "Per-mode instructions"

        let result = settings.effectiveSystemPrompt(
            for: .aiChat,
            configDefault: "Bundled default"
        )

        #expect(result == """
        Global instructions

        Bundled default

        Per-mode instructions
        """)
    }

    @Test func effectiveSystemPromptSkipsEmptySections() {
        let settings = UserSettings()
        defer { resetSettings(settings) }

        settings.globalSystemPrompt = "Global instructions"
        settings.skillsSystemPrompt = "Per-mode instructions"

        let result = settings.effectiveSystemPrompt(
            for: .chatWithSkills,
            configDefault: ""
        )

        #expect(result == """
        Global instructions

        Per-mode instructions
        """)
    }

    private func resetSettings(_ settings: UserSettings) {
        settings.globalSystemPrompt = ""
        settings.askImageSystemPrompt = ""
        settings.aiChatSystemPrompt = ""
        settings.skillsSystemPrompt = ""
    }
}
