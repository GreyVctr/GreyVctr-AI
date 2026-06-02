import Foundation

/// Inference parameters loaded from inference_config.json.
struct InferenceConfig: Codable, Equatable {
    var temperature: Double
    var topK: Int
    var topP: Double
    var systemPrompt: String

    enum CodingKeys: String, CodingKey {
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case systemPrompt = "system_prompt"
    }

    /// Hardcoded fallback values used when config file is missing or invalid.
    static let defaults = InferenceConfig(
        temperature: 0.7,
        topK: 40,
        topP: 0.95,
        systemPrompt: "You are a helpful assistant."
    )
}

/// Partial inference config used for per-mode overrides.
/// Only fields present in the JSON override the defaults.
struct PartialInferenceConfig: Codable {
    var temperature: Double?
    var topK: Int?
    var topP: Double?
    var systemPrompt: String?

    enum CodingKeys: String, CodingKey {
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case systemPrompt = "system_prompt"
    }
}

/// Top-level structure of inference_config.json with per-mode overrides.
struct InferenceConfigFile: Codable {
    let defaults: InferenceConfig
    let modes: ModeOverrides?
    /// Legacy developer flag for remote model metadata checks.
    /// Settings update prompts compare installed metadata against `ModelDownloader.currentModel`.
    let checkForModelUpdates: Bool?

    enum CodingKeys: String, CodingKey {
        case defaults
        case modes
        case checkForModelUpdates = "check_for_model_updates"
    }

    struct ModeOverrides: Codable {
        let askImage: PartialInferenceConfig?
        let aiChat: PartialInferenceConfig?
        let chatWithSkills: PartialInferenceConfig?

        enum CodingKeys: String, CodingKey {
            case askImage = "ask_image"
            case aiChat = "ai_chat"
            case chatWithSkills = "chat_with_skills"
        }
    }

    /// Resolve the configuration for a specific mode.
    /// Mode-specific values override defaults; missing fields inherit from defaults.
    func resolved(for mode: AppMode) -> InferenceConfig {
        let modeConfig: PartialInferenceConfig?
        switch mode {
        case .askImage:
            modeConfig = modes?.askImage
        case .aiChat:
            modeConfig = modes?.aiChat
        case .chatWithSkills:
            modeConfig = modes?.chatWithSkills
        }

        guard let override = modeConfig else {
            return defaults
        }

        return InferenceConfig(
            temperature: override.temperature ?? defaults.temperature,
            topK: override.topK ?? defaults.topK,
            topP: override.topP ?? defaults.topP,
            systemPrompt: override.systemPrompt ?? defaults.systemPrompt
        )
    }
}
