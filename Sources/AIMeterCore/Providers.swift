import Foundation

/// Reads one account with the provider for its kind.
public enum Providers {
    public static func fetch(_ account: Account, secrets: any SecretStore) async -> Result<Reading, ProviderError> {
        await capture { () async throws(ProviderError) in
            switch account.kind {
            case .claude: try await ClaudeProvider().fetch(account, secrets: secrets)
            case .codex: try await CodexProvider().fetch(account, secrets: secrets)
            case .anthropicAPI: try await AnthropicCostProvider().fetch(account, secrets: secrets)
            case .claudeCodeLocal: try await ClaudeCodeLocalProvider().fetch(account)
            }
        }
    }
}

private func capture<Value>(
    _ body: () async throws(ProviderError) -> Value
) async -> Result<Value, ProviderError> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
