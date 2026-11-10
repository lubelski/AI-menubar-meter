import Foundation

/// Resolves the credential each provider should use, based on the user's account settings.
enum Credentials {
    // MARK: Claude

    static func claudeAccessToken(_ config: AuthConfig) async throws(ProviderError) -> (token: String, plan: String?) {
        switch config.claudeSource {
        case .token:
            guard let token = config.claudeToken else { throw .notSignedIn }
            return (token, nil)
        case .claudeCode:
            let login = try await claudeCodeLogin()
            return (login.accessToken, login.plan)
        }
    }

    /// Returns a usable Claude Code login. If the stored token has expired, or the server
    /// rejected `rejected`, asks the CLI to refresh it and reads the login again.
    static func claudeCodeLogin(rejecting rejected: String? = nil) async throws(ProviderError) -> ClaudeCodeLogin {
        let result: Result<ClaudeCodeLogin, ClaudeCodeIssue>
        if let early = ClaudeCodeLogin.resolve(await ClaudeCodeLogin.read(), rejecting: rejected) {
            result = early
        } else {
            let nudge = await ClaudeCodeCLI.shared.nudge()
            result = ClaudeCodeLogin.resolve(await ClaudeCodeLogin.read(), rejecting: rejected, after: nudge)
        }
        switch result {
        case .success(let login): return login
        case .failure(let issue): throw .claudeCode(issue)
        }
    }

    // MARK: OpenAI

    static func openAITokens(_ config: AuthConfig) throws(ProviderError) -> (accessToken: String, accountID: String?) {
        switch config.openAISource {
        case .token:
            guard let token = config.openAIToken else { throw .notSignedIn }
            return (token, config.openAIAccountID)
        case .codexCLI:
            guard let data = try? Data(contentsOf: config.codexHome.appending(path: "auth.json")) else {
                throw .notSignedIn
            }
            struct Payload: Decodable {
                struct Tokens: Decodable {
                    var access_token: String
                    var account_id: String?
                }
                var tokens: Tokens?
            }
            guard let tokens = try? JSONDecoder().decode(Payload.self, from: data).tokens else {
                throw .notSignedIn
            }
            return (tokens.access_token, tokens.account_id)
        }
    }
}
