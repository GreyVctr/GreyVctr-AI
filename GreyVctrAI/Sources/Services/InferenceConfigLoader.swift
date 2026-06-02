import Foundation
import os

/// Protocol for loading inference configuration from a bundled JSON file.
protocol InferenceConfigLoaderProtocol {
    /// Load the default configuration from the app bundle.
    /// Falls back to `InferenceConfig.defaults` if the file is missing or invalid.
    func load() -> InferenceConfig

    /// Load the configuration resolved for a specific app mode.
    /// Per-mode overrides are applied on top of defaults.
    /// Falls back to `InferenceConfig.defaults` if the file is missing or invalid.
    func load(for mode: AppMode) -> InferenceConfig

    /// Legacy developer flag for remote model metadata checks.
    /// Required target model update prompts do not depend on this flag.
    var checkForModelUpdates: Bool { get }
}

/// Loads inference parameters from the bundled `inference_config.json` file.
final class InferenceConfigLoader: InferenceConfigLoaderProtocol {

    private let bundle: Bundle
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GreyVctr AI",
                                category: "InferenceConfig")
    private let cachedConfigFile: InferenceConfigFile?

    var checkForModelUpdates: Bool {
        cachedConfigFile?.checkForModelUpdates ?? false
    }

    /// Creates a loader that reads from the given bundle.
    /// - Parameter bundle: The bundle containing `inference_config.json`. Defaults to `.main`.
    init(bundle: Bundle = .main) {
        self.bundle = bundle
        self.cachedConfigFile = Self.loadConfigFile(from: bundle, logger: Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "GreyVctr AI",
            category: "InferenceConfig"
        ))
    }

    // MARK: - InferenceConfigLoaderProtocol

    func load() -> InferenceConfig {
        guard let configFile = cachedConfigFile else {
            return InferenceConfig.defaults
        }
        return configFile.defaults
    }

    func load(for mode: AppMode) -> InferenceConfig {
        guard let configFile = cachedConfigFile else {
            return InferenceConfig.defaults
        }
        return configFile.resolved(for: mode)
    }

    // MARK: - Private

    /// Locate and parse the `inference_config.json` file from the bundle.
    /// Returns `nil` (with a logged warning) if the file is missing or contains invalid JSON.
    private static func loadConfigFile(from bundle: Bundle, logger: Logger) -> InferenceConfigFile? {
        guard let url = bundle.url(forResource: "inference_config", withExtension: "json") else {
            logger.warning("inference_config.json not found in bundle — using defaults")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(InferenceConfigFile.self, from: data)
        } catch {
            logger.warning("Failed to parse inference_config.json: \(error.localizedDescription) — using defaults")
            return nil
        }
    }
}
