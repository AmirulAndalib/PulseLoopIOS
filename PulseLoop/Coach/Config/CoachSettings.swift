import Foundation

/// Where the coach's "brain" runs. v1 ships `offlineStub` + `userOpenAIKey`;
/// `backendProxy` is reserved for a future public build (iOS → server → OpenAI)
/// and is treated as disabled until implemented.
enum CoachProviderMode: String, Codable, CaseIterable, Identifiable {
    case offlineStub
    case userOpenAIKey
    case backendProxy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .offlineStub: return "Offline"
        case .userOpenAIKey: return "OpenAI (your key)"
        case .backendProxy: return "Backend proxy"
        }
    }
}

/// Preset OpenAI model choices. The stored `CoachSettings.model` is a free
/// string (so a new model can be typed/served without a code change); these are
/// just the curated picks surfaced in Settings.
enum CoachModel: String, CaseIterable, Identifiable {
    case gpt54mini = "gpt-5.4-mini"
    case gpt54 = "gpt-5.4"
    case gpt55 = "gpt-5.5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gpt54mini: return "gpt-5.4-mini"
        case .gpt54: return "gpt-5.4"
        case .gpt55: return "gpt-5.5"
        }
    }

    var blurb: String {
        switch self {
        case .gpt54mini: return "Lower cost & latency"
        case .gpt54: return "Balanced (default)"
        case .gpt55: return "Best reasoning"
        }
    }
}

/// User-tunable coach configuration, persisted as JSON in `UserDefaults`.
struct CoachSettings: Codable, Equatable {
    var providerMode: CoachProviderMode = .userOpenAIKey
    /// Default matches the web app; user-configurable (never hard-coded in the client).
    var model: String = CoachModel.gpt54.rawValue
    /// Optional reasoning effort hint ("low"/"medium"/"high") when the model supports it.
    var reasoningEffort: String? = nil
    var enableWebSearch: Bool = false
    /// Milestone A is read-only: write/action and live-measurement tools stay off
    /// until Milestone B wires confirmation gates.
    var enableWriteTools: Bool = false
    var enableLiveMeasurements: Bool = false
    var maxToolCalls: Int = 8
    var maxRounds: Int = 4

    static let `default` = CoachSettings()
}

/// Observable, UserDefaults-backed store for `CoachSettings`. Mutating `settings`
/// persists immediately. A shared instance keeps Settings and the coach in sync.
@MainActor
@Observable
final class CoachSettingsStore {
    static let shared = CoachSettingsStore()

    private static let storageKey = "pulseloop.coach.settings.v1"
    private let defaults: UserDefaults

    var settings: CoachSettings {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(CoachSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
