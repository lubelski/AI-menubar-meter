import Foundation

/// Resolves the credential a provider should use for one account.
enum Credentials {
    // MARK: Claude

    static func claudeAccessToken(
        _ account: Account, secrets: any SecretStore
    ) async throws(ProviderError) -> (token: String, plan: String?) {
        switch account.credential {
        case .pasted:
            guard let token = secrets.read(account.secretKey) else { throw .notSignedIn }
            return (token, nil)
        case .cli:
            let login = try await claudeCodeLogin()
            return (login.accessToken, login.planName)
        case .oauth:
            // Claude has no browser sign-in: Anthropic doesn't offer OAuth to other apps.
            throw .notSignedIn
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

    static func codexTokens(
        _ account: Account, secrets: any SecretStore, rejecting rejected: String? = nil
    ) async throws(ProviderError) -> (accessToken: String, accountID: String?) {
        switch account.credential {
        case .oauth:
            let login = try await OAuthSessions.shared.usableLogin(
                for: account, secrets: secrets, rejecting: rejected)
            return (login.accessToken, login.accountID)
        case .pasted:
            guard let token = secrets.read(account.secretKey) else { throw .notSignedIn }
            return (token, account.chatGPTAccountID)
        case .cli:
            let file = URL(fileURLWithPath: account.resolvedCodexHome).appending(path: "auth.json")
            guard let data = try? Data(contentsOf: file) else { throw .notSignedIn }
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
