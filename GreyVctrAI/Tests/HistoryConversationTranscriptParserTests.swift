import Testing
@testable import GreyVctrAI

@Suite("History conversation transcript parser")
struct HistoryConversationTranscriptParserTests {
    @Test func parsesAlternatingTurns() {
        let transcript = """
        **User**

        Hello

        ---

        **Assistant**

        Hi there

        ---

        **User**

        Continue please
        """

        let messages = HistoryConversationTranscriptParser.messages(from: transcript)

        #expect(messages.count == 3)
        #expect(messages[0].role == .user)
        #expect(messages[0].content == "Hello")
        #expect(messages[1].role == .model)
        #expect(messages[1].content == "Hi there")
        #expect(messages[2].role == .user)
        #expect(messages[2].content == "Continue please")
    }

    @Test func ignoresEmptySections() {
        let transcript = """
        **User**

        Hello

        ---

        **System**

        Stopped by user

        ---

        **Assistant**

        """

        let messages = HistoryConversationTranscriptParser.messages(from: transcript)

        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .system)
    }
}
