import LiteRTLM
import Foundation

/// Manages Ask Image mode state: image selection, prompt input, and inference output.
///
/// Uses the official LiteRT-LM SDK via `SessionCoordinator` for multimodal image analysis.
/// Each image analysis is single-turn — a fresh conversation is created for each request.
///
/// Uses `Data` for the selected image to remain platform-agnostic across iOS and macOS.
/// On iOS, callers convert `UIImage` to JPEG/PNG `Data` before setting `selectedImageData`.
@Observable
final class AskImageViewModel {

    // MARK: - Published State

    /// Raw image data (JPEG or PNG). Set by the view after the user picks or captures a photo.
    var selectedImageData: Data?

    /// Optional text prompt to accompany the image (e.g., "What is in this photo?").
    var textPrompt: String = ""

    /// Whether inference is currently in progress.
    var isGenerating: Bool = false

    /// Accumulated output from the model response.
    var streamedOutput: String = ""

    /// User-facing error message, or nil if no error.
    var error: String?

    // MARK: - Dependencies

    private let sessionCoordinator: SessionCoordinator
    private let configLoader: InferenceConfigLoaderProtocol
    private let userSettings: UserSettings

    // MARK: - Init

    /// Creates the view model with required dependencies.
    /// - Parameters:
    ///   - sessionCoordinator: Coordinates conversation lifecycle across app modes.
    ///   - configLoader: Loader for inference configuration (system prompt, temperature, etc.).
    init(
        sessionCoordinator: SessionCoordinator,
        configLoader: InferenceConfigLoaderProtocol,
        userSettings: UserSettings
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.configLoader = configLoader
        self.userSettings = userSettings
    }

    // MARK: - Actions

    /// Analyze the selected image with an optional text prompt.
    ///
    /// Creates a fresh conversation each time (single-turn vision analysis).
    /// Constructs a multimodal Message with image data and text prompt.
    @MainActor
    func analyzeImage() async {
        // Validate that an image is selected
        guard let imageData = selectedImageData else {
            error = "Please select an image before submitting."
            return
        }

        error = nil
        streamedOutput = ""
        isGenerating = true
        defer { isGenerating = false }

        do {
            // Load Ask Image config for parameters
            let config = effectiveConfig()

            // Compose the prompt — use the text prompt if provided, otherwise a default
            let trimmedPrompt = textPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = trimmedPrompt.isEmpty
                ? "Describe this image in detail."
                : trimmedPrompt

            // Build ConversationConfig with SamplerConfig from ask_image config values
            let samplerConfig = try SamplerConfig(
                topK: config.topK,
                topP: Float(config.topP),
                temperature: Float(config.temperature)
            )

            let conversationConfig = ConversationConfig(
                systemMessage: config.systemPrompt.isEmpty ? nil : Message(config.systemPrompt, role: .system),
                samplerConfig: samplerConfig
            )

            // Acquire a fresh conversation for vision (single-turn, new each time)
            await sessionCoordinator.releaseConversation(for: .askImage)
            let conversation: Conversation
            do {
                conversation = try await sessionCoordinator.acquireConversation(
                    for: .askImage,
                    config: conversationConfig
                )
            } catch {
                // If creation fails, the engine might be in a bad state from a previous cancel.
                // Try once more after a brief pause.
                try await Task.sleep(nanoseconds: 500_000_000)
                conversation = try await sessionCoordinator.acquireConversation(
                    for: .askImage,
                    config: conversationConfig
                )
            }

            // Construct multimodal message with image data and text prompt
            let message = Message(of: .imageData(imageData), .text(prompt))

            // Send message (non-streaming, single-turn for vision)
            await sessionCoordinator.beginInference()
            defer {
                Task { await sessionCoordinator.endInference() }
            }
            let response = try await conversation.sendMessage(message)

            // Extract text from the response
            streamedOutput = response.toString

        } catch let liteRTError as LiteRTLMError {
            switch liteRTError {
            case .conversation(.notAlive):
                error = "Vision session expired. Please try again."
            default:
                error = liteRTError.localizedDescription
            }
        } catch {
            let desc = error.localizedDescription
            if desc.localizedCaseInsensitiveContains("cancel") {
                self.error = "Inference was interrupted because the app went to background. Please try again."
            } else {
                self.error = "Image analysis failed: \(desc)"
            }
        }
    }

    private func effectiveConfig() -> InferenceConfig {
        let config = configLoader.load(for: .askImage)
        return InferenceConfig(
            temperature: userSettings.effectiveTemperature(configDefault: config.temperature),
            topK: userSettings.effectiveTopK(configDefault: config.topK),
            topP: userSettings.effectiveTopP(configDefault: config.topP),
            systemPrompt: userSettings.effectiveSystemPrompt(
                for: .askImage,
                configDefault: config.systemPrompt
            )
        )
    }
}
