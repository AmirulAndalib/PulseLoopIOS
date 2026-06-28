import Foundation

/// Single source of truth for "which `ResponsesClient` runs, given the user's
/// settings + stored keys." Shared by the chat view-model, the summary service,
/// and the notification service so provider logic (including the on-device
/// cloud-backup fallback) lives in exactly one place.
///
/// The returned `key` is a readiness sentinel: non-`nil` means the provider can
/// run (used to build `CoachFeatureFlags.hasAPIKey`). For cloud providers it's
/// the actual key; for on-device it's a `"on-device"` placeholder.
@MainActor
enum CoachClientResolver {
    static func resolve(
        settings: CoachSettings,
        openAIKeyStore: APIKeyStore,
        geminiKeyStore: APIKeyStore,
        openRouterKeyStore: APIKeyStore,
        openAIClientFactory: (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) }
    ) -> (key: String?, client: ResponsesClient) {
        switch settings.providerMode {
        case .appleOnDevice:
            let onDevice = AppleFoundationModelsClient()
            let available = AppleOnDeviceAvailability.current.isAvailable
            // A usable cloud backup is one whose key is actually present.
            let backup = settings.appleFallbackProvider.flatMap { mode in
                usableCloudClient(
                    mode, settings: settings,
                    openAIKeyStore: openAIKeyStore, geminiKeyStore: geminiKeyStore,
                    openRouterKeyStore: openRouterKeyStore, openAIClientFactory: openAIClientFactory
                )
            }
            if available {
                let client: ResponsesClient = backup.map { FallbackResponsesClient(primary: onDevice, secondary: $0) } ?? onDevice
                return ("on-device", client)
            } else if let backup {
                // On-device unusable on this device → run the cloud backup directly.
                return ("on-device", backup)
            } else {
                // Nothing usable: hand back the on-device client (it throws a clear
                // error) and signal "not ready" so generators degrade to scripted.
                return (nil, onDevice)
            }
        default:
            return directClient(
                settings.providerMode, settings: settings,
                openAIKeyStore: openAIKeyStore, geminiKeyStore: geminiKeyStore,
                openRouterKeyStore: openRouterKeyStore, openAIClientFactory: openAIClientFactory
            )
        }
    }

    /// Builds a client for a concrete (non-on-device) provider, mirroring the
    /// prior per-call-site logic. Returns a client even when the key is absent
    /// (`key == nil`); the feature-flags gate prevents an empty-key call.
    private static func directClient(
        _ mode: CoachProviderMode,
        settings: CoachSettings,
        openAIKeyStore: APIKeyStore,
        geminiKeyStore: APIKeyStore,
        openRouterKeyStore: APIKeyStore,
        openAIClientFactory: (String) -> ResponsesClient
    ) -> (key: String?, client: ResponsesClient) {
        switch mode {
        case .userGeminiKey:
            let key = (try? geminiKeyStore.readKey()) ?? nil
            return (key, GeminiClient(apiKey: key ?? ""))
        case .userOpenRouterKey:
            let key = (try? openRouterKeyStore.readKey()) ?? nil
            return (key, OpenRouterClient(
                apiKey: key ?? "",
                model: settings.openRouterModel,
                privacyRouting: settings.orEnablePrivacyRouting,
                providerSort: settings.orProviderSort))
        default:
            // userOpenAIKey / offlineStub / backendProxy (and appleOnDevice never
            // reaches here) all use the OpenAI key + factory.
            let key = (try? openAIKeyStore.readKey()) ?? nil
            return (key, openAIClientFactory(key ?? ""))
        }
    }

    /// A cloud client only when its key is present — used to decide whether the
    /// on-device backup is actually usable.
    private static func usableCloudClient(
        _ mode: CoachProviderMode,
        settings: CoachSettings,
        openAIKeyStore: APIKeyStore,
        geminiKeyStore: APIKeyStore,
        openRouterKeyStore: APIKeyStore,
        openAIClientFactory: (String) -> ResponsesClient
    ) -> ResponsesClient? {
        let (key, client) = directClient(
            mode, settings: settings,
            openAIKeyStore: openAIKeyStore, geminiKeyStore: geminiKeyStore,
            openRouterKeyStore: openRouterKeyStore, openAIClientFactory: openAIClientFactory
        )
        return key != nil ? client : nil
    }
}
