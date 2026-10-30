import LiteRTLM
import Testing
@testable import GreyVctrAI

@Suite("AI chat stream")
struct AIChatStreamTests {
    @Test func collectsEveryTextItemInOrder() {
        let chunk = Message(contents: [
            .text("The planets are: "),
            .imageFile("/unused/image.png"),
            .text("Mercury, Venus, Earth")
        ], role: .model)

        #expect(AIChatViewModel.streamedText(in: chunk) == "The planets are: Mercury, Venus, Earth")
    }
}
