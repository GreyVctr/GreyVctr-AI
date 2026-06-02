import LiteRTLM
import Foundation

/// LiteRT-LM Tool that the model calls to execute JavaScript for JS-backed skills.
/// This is the ONLY native tool registered — skill selection/loading is handled
/// at the app layer via system prompt + text parsing (matching the Google Gallery pattern).
struct RunJSTool: Tool {
    static let name = "run_js"
    static let description = "Execute a JavaScript skill computation. Pass the required data as a JSON string following the loaded skill's instructions."

    @ToolParam(description: "A JSON string containing the input data for the JavaScript skill function.")
    var data: String

    /// Injected at runtime. Maps skill names to their JS content.
    static var jsRuntime: JSRuntimeProtocol?
    static var jsSkillContent: [String: String] = [:]
    /// The most recently loaded skill name (set by the app when it detects skill selection).
    static var activeSkillName: String?

    func run() async throws -> Any {
        print("[RunJSTool] Called with data: \(data.prefix(200))...")

        guard let runtime = Self.jsRuntime else {
            print("[RunJSTool] ERROR: JavaScript runtime not available")
            return ["error": "JavaScript runtime not available"]
        }

        // Find the JS content for the active skill
        let skillName = Self.activeSkillName ?? ""
        guard let jsContent = Self.jsSkillContent[skillName] ??
              Self.jsSkillContent.values.first else {
            print("[RunJSTool] ERROR: No JavaScript content found for skill '\(skillName)'")
            return ["error": "No JavaScript content found for skill '\(skillName)'"]
        }

        do {
            let result = try await runtime.execute(script: jsContent, inputJSON: data)
            print("[RunJSTool] Success: \(result.prefix(200))...")
            // Parse the result JSON and return it as a dictionary
            if let resultData = result.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: resultData) {
                return parsed
            }
            return ["result": result]
        } catch {
            print("[RunJSTool] ERROR: \(error.localizedDescription)")
            return ["error": "JavaScript execution failed: \(error.localizedDescription)"]
        }
    }
}
