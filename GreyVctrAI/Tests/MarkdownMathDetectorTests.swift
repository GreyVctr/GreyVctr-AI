import Testing
@testable import GreyVctrAI

@Suite("Markdown math detection")
struct MarkdownMathDetectorTests {
    @Test func detectsInlineMath() {
        #expect(MarkdownMathDetector.containsMathDelimiter(in: "The formula is $E = mc^2$."))
    }

    @Test func detectsBlockMath() {
        #expect(MarkdownMathDetector.containsMathDelimiter(in: "Result:\n\n$$x = 3$$"))
    }

    @Test func detectsParenthesisMath() {
        #expect(MarkdownMathDetector.containsMathDelimiter(in: "Use \\(a^2 + b^2 = c^2\\)."))
    }

    @Test func detectsBracketMath() {
        #expect(MarkdownMathDetector.containsMathDelimiter(in: "\\[x = 3\\]"))
    }

    @Test func detectsChemicalFormulaMath() {
        #expect(MarkdownMathDetector.containsMathDelimiter(in: "Carbon dioxide: $\\text{CO}_2$"))
        #expect(MarkdownMathDetector.containsMathDelimiter(in: "Water: \\(H_2O\\)"))
    }

    @Test func ignoresUnclosedBackslashMath() {
        #expect(!MarkdownMathDetector.containsMathDelimiter(in: "Literal \\( without a closing delimiter."))
    }

    @Test func ignoresCurrency() {
        #expect(!MarkdownMathDetector.containsMathDelimiter(in: "The total is $25 and shipping is $5."))
    }

    @Test func ignoresEscapedDollar() {
        #expect(!MarkdownMathDetector.containsMathDelimiter(in: "Use \\$HOME or pay \\$25."))
    }

    @Test func keepsPlainMarkdownAsSingleBlock() {
        let blocks = MarkdownMathDetector.renderBlocks(in: "# Header\n\n- Item 1\n- Item 2")

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .markdown)
    }

    @Test func splitsMixedMarkdownAndMathBlocks() {
        let blocks = MarkdownMathDetector.renderBlocks(in: "# Header\n\nFormula: $E = mc^2$")

        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .markdown)
        #expect(blocks[1].kind == .latex)
    }

    @Test func splitsBoldWrappedCaffeineFormulaForMarkdownRenderer() {
        let blocks = MarkdownMathDetector.renderBlocks(
            in: "The chemical formula for caffeine is **$\\text{C}_8\\text{H}_{10}\\text{N}_4\\text{O}_2$**."
        )

        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .markdown)
        #expect(blocks[0].content == "The chemical formula for caffeine is ")
        #expect(blocks[1].kind == .latex)
        #expect(blocks[1].content == "$\\text{C}_8\\text{H}_{10}\\text{N}_4\\text{O}_2$")
        #expect(blocks[2].kind == .markdown)
        #expect(blocks[2].content == ".")
    }

    @Test func stripsMarkdownWrappersAroundMath() {
        #expect(
            MarkdownMathDetector.stripMarkdownFromMath("**$H_2O$** and *$Fe$*") ==
                "$H_2O$ and $Fe$"
        )
    }

    @Test func splitsCaffeineFormulaForPlainRenderer() {
        let blocks = MarkdownMathDetector.renderInlineMathBlocks(
            in: "* **Caffeine:** $\\text{C}_8\\text{H}_{10}\\text{N}_4\\text{O}_2$"
        )

        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .markdown)
        #expect(blocks[0].content == "* **Caffeine:** ")
        #expect(blocks[1].kind == .latex)
        #expect(blocks[1].content == "$\\text{C}_8\\text{H}_{10}\\text{N}_4\\text{O}_2$")
    }

    @Test func splitsBackslashFormulaForPlainRenderer() {
        let blocks = MarkdownMathDetector.renderInlineMathBlocks(in: "Water is \\(H_2O\\).")

        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .markdown)
        #expect(blocks[0].content == "Water is ")
        #expect(blocks[1].kind == .latex)
        #expect(blocks[1].content == "\\(H_2O\\)")
        #expect(blocks[2].kind == .markdown)
        #expect(blocks[2].content == ".")
    }

    @Test func keepsCurrencyPlainForPlainRenderer() {
        let blocks = MarkdownMathDetector.renderInlineMathBlocks(
            in: "The total is $25 and shipping is $5."
        )

        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .markdown)
    }

}
