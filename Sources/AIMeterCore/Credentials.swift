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
            return try await claudeCodeLogin()
        }
    }

    /// Claude Code stores its login in the login Keychain. We read it through
    /// `/usr/bin/security` because that tool is already on the item's access list
    /// (Claude Code writes the item with it), which avoids a Keychain prompt on
    /// every rebuild of an ad-hoc-signed app.
    private static func claudeCodeLogin() async throws(ProviderError) -> (token: String, plan: String?) {
        let data: Data
        if let keychain = try? await run("/usr/bin/security",
                                         ["find-generic-password", "-s", "Claude Code-credentials", "-w"]) {
            data = keychain
        } else if let file = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json")) {
            data = file
        } else {
            throw .notSignedIn
        }

        struct Payload: Decodable {
            struct OAuth: Decodable {
                var accessToken: String
                var expiresAt: Double?
                var subscriptionType: String?
            }
            var claudeAiOauth: OAuth
        }
        guard let oauth = try? JSONDecoder().decode(Payload.self, from: data).claudeAiOauth else {
            throw .notSignedIn
        }
        if let expiresAt = oauth.expiresAt, Date(timeIntervalSince1970: expiresAt / 1000) < .now {
            throw .sessionExpired
        }
        return (oauth.accessToken, oauth.subscriptionType)
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

    // MARK: Helpers

    private struct ProcessFailure: Error {}

    private static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Drain before waiting so a large payload can't fill the pipe and deadlock.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ProcessFailure() }
            return data
        }.value
    }
}
