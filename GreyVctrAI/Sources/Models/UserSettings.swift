import Foundation

/// User-configurable settings that override inference_config.json defaults.
/// Persisted to UserDefaults.
@Observable
final class UserSettings {

    // MARK: - Global

    /// Temperature override (nil = use config default)
    var temperatureOverride: Double? {
        didSet { save() }
    }

    /// Top K override (nil = use config default)
    var topKOverride: Int? {
        didSet { save() }
    }

    /// Top P override (nil = use config default)
    var topPOverride: Double? {
        didSet { save() }
    }

    /// Global system prompt prepended to all modes
    var globalSystemPrompt: String {
        didSet { save() }
    }

    /// KV cache size used when the LiteRT-LM engine starts.
    /// Larger values allow longer conversations but use more memory.
    var kvCacheSize: Int {
        didSet { save() }
    }

    /// Preferred LiteRT-LM backend. Automatic chooses GPU on capable devices and
    /// falls back to CPU when GPU is unavailable.
    var engineBackendPreference: EngineBackendPreference {
        didSet { save() }
    }

    static let supportedKVCacheSizes = [512, 1024, 2048, 4096, 8192]
    static let defaultKVCacheSize = 4096
    static let defaultEngineBackendPreference: EngineBackendPreference = .automatic

    // MARK: - Per-Mode System Prompts

    var askImageSystemPrompt: String {
        didSet { save() }
    }

    var aiChatSystemPrompt: String {
        didSet { save() }
    }

    var skillsSystemPrompt: String {
        didSet { save() }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        self.temperatureOverride = defaults.object(forKey: "userSettings.temperature") as? Double
        self.topKOverride = defaults.object(forKey: "userSettings.topK") as? Int
        self.topPOverride = defaults.object(forKey: "userSettings.topP") as? Double
        self.globalSystemPrompt = defaults.string(forKey: "userSettings.globalSystemPrompt") ?? ""
        self.askImageSystemPrompt = defaults.string(forKey: "userSettings.askImageSystemPrompt") ?? ""
        self.aiChatSystemPrompt = defaults.string(forKey: "userSettings.aiChatSystemPrompt") ?? ""
        self.skillsSystemPrompt = defaults.string(forKey: "userSettings.skillsSystemPrompt") ?? ""
        let savedBackendPreference = defaults.string(forKey: "userSettings.engineBackendPreference")
            .flatMap(EngineBackendPreference.init(rawValue:))
        self.engineBackendPreference = savedBackendPreference ?? Self.defaultEngineBackendPreference
        let savedKVCacheSize = defaults.integer(forKey: "userSettings.kvCacheSize")
        let hasSavedKVCacheSize = defaults.object(forKey: "userSettings.kvCacheSize") != nil
        let candidateKVCacheSize = Self.supportedKVCacheSizes.contains(savedKVCacheSize)
            ? savedKVCacheSize
            : Self.defaultKVCacheSize
        self.kvCacheSize = KVCacheMemoryPolicy.isAvailable(candidateKVCacheSize)
            ? candidateKVCacheSize
            : Self.defaultKVCacheSize

        if hasSavedKVCacheSize, savedKVCacheSize != self.kvCacheSize {
            defaults.set(self.kvCacheSize, forKey: "userSettings.kvCacheSize")
        }
    }

    // MARK: - Resolve

    /// Returns the effective system prompt for a mode, combining global, bundled mode defaults,
    /// and any per-mode additions.
    func effectiveSystemPrompt(for mode: AppMode, configDefault: String) -> String {
        let perMode: String
        switch mode {
        case .askImage: perMode = askImageSystemPrompt
        case .aiChat: perMode = aiChatSystemPrompt
        case .chatWithSkills: perMode = skillsSystemPrompt
        }

        var parts: [String] = []

        if !globalSystemPrompt.isEmpty {
            parts.append(globalSystemPrompt)
        }

        if !configDefault.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(configDefault)
        }

        if !perMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(perMode)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Returns the effective temperature, using user override or config default.
    func effectiveTemperature(configDefault: Double) -> Double {
        temperatureOverride ?? configDefault
    }

    /// Returns the effective Top K, using user override or config default.
    func effectiveTopK(configDefault: Int) -> Int {
        topKOverride ?? configDefault
    }

    /// Returns the effective Top P, using user override or config default.
    func effectiveTopP(configDefault: Double) -> Double {
        topPOverride ?? configDefault
    }

    /// Reset all overrides to defaults.
    func resetAll() {
        temperatureOverride = nil
        topKOverride = nil
        topPOverride = nil
        globalSystemPrompt = ""
        askImageSystemPrompt = ""
        aiChatSystemPrompt = ""
        skillsSystemPrompt = ""
        kvCacheSize = Self.defaultKVCacheSize
        engineBackendPreference = Self.defaultEngineBackendPreference
    }

    // MARK: - Persistence

    private func save() {
        let defaults = UserDefaults.standard
        if let temp = temperatureOverride {
            defaults.set(temp, forKey: "userSettings.temperature")
        } else {
            defaults.removeObject(forKey: "userSettings.temperature")
        }
        if let topK = topKOverride {
            defaults.set(topK, forKey: "userSettings.topK")
        } else {
            defaults.removeObject(forKey: "userSettings.topK")
        }
        if let topP = topPOverride {
            defaults.set(topP, forKey: "userSettings.topP")
        } else {
            defaults.removeObject(forKey: "userSettings.topP")
        }
        defaults.set(globalSystemPrompt, forKey: "userSettings.globalSystemPrompt")
        defaults.set(askImageSystemPrompt, forKey: "userSettings.askImageSystemPrompt")
        defaults.set(aiChatSystemPrompt, forKey: "userSettings.aiChatSystemPrompt")
        defaults.set(skillsSystemPrompt, forKey: "userSettings.skillsSystemPrompt")
        defaults.set(kvCacheSize, forKey: "userSettings.kvCacheSize")
        defaults.set(engineBackendPreference.rawValue, forKey: "userSettings.engineBackendPreference")
    }
}

enum EngineBackendPreference: String, CaseIterable, Identifiable {
    case automatic
    case gpu
    case cpu

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .gpu:
            return "GPU (Metal)"
        case .cpu:
            return "CPU"
        }
    }

    var detailText: String {
        switch self {
        case .automatic:
            return "Use GPU on supported hardware, fall back to CPU"
        case .gpu:
            return "Prefer Metal GPU; unavailable in Simulator"
        case .cpu:
            return "Use CPU for compatibility and Simulator testing"
        }
    }
}

struct KVCacheSizeOption: Identifiable {
    let value: Int
    let label: String
    let detail: String
    let isAvailable: Bool
    let unavailableReason: String?

    var id: Int { value }
}

enum KVCacheMemoryPolicy {
    private static let decimalGigabyte = 1_000_000_000.0

    static var physicalMemoryDecimalGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / decimalGigabyte
    }

    static var physicalMemoryLabel: String {
        let memory = physicalMemoryDecimalGB
        if memory >= 10 {
            return "\(Int(memory.rounded())) GB"
        }
        return String(format: "%.1f GB", memory)
    }

    static var options: [KVCacheSizeOption] {
        UserSettings.supportedKVCacheSizes.map { size in
            KVCacheSizeOption(
                value: size,
                label: label(for: size),
                detail: detail(for: size),
                isAvailable: isAvailable(size),
                unavailableReason: unavailableReason(for: size)
            )
        }
    }

    static var availableOptions: [KVCacheSizeOption] {
        options.filter(\.isAvailable)
    }

    static func isAvailable(_ size: Int) -> Bool {
        switch size {
        case ...8192:
            return true
        case 16384:
            return physicalMemoryDecimalGB >= 6
        case 32768:
            return physicalMemoryDecimalGB >= 8
        default:
            return false
        }
    }

    static func label(for size: Int) -> String {
        switch size {
        case 512: return "512 tokens"
        case 1024: return "1024 tokens"
        case 2048: return "2048 tokens"
        case 4096: return "4096 tokens"
        case 8192: return "8192 tokens"
        case 16384: return "16K tokens"
        case 32768: return "32K tokens"
        default: return "\(size) tokens"
        }
    }

    private static func detail(for size: Int) -> String {
        switch size {
        case 512: return "Shortest context"
        case 1024: return "Short context"
        case 2048: return "Moderate context"
        case 4096: return "Recommended"
        case 8192: return "More context"
        case 16384: return "High memory"
        case 32768: return "Very high memory"
        default: return "Custom"
        }
    }

    private static func unavailableReason(for size: Int) -> String? {
        switch size {
        case 16384:
            return physicalMemoryDecimalGB >= 6 ? nil : "Requires a device with at least 6 GB memory."
        case 32768:
            return physicalMemoryDecimalGB >= 8 ? nil : "Requires a device with at least 8 GB memory."
        default:
            return nil
        }
    }
}
