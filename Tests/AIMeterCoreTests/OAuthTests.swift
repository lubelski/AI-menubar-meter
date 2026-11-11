import Foundation
import Testing
@testable import AIMeterCore

private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "e30.\(PKCE.base64URL(payload)).sig"
}

@Suite("OAuth")
struct OAuthTests {
    @Test func codexAuthorizationURLMatchesTheCLI() throws {
        let url = OAuthClient.codex.authorizationURL(port: 1455, challenge: "abc", state: "xyz")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        #expect(url.host() == "auth.openai.com")
        #expect(query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(query["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(query["scope"] == "openid profile email offline_access")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "xyz")
        #expect(query["codex_cli_simplified_flow"] == "true")
    }

    @Test func claudeAsksOnlyForProfile() throws {
        let url = OAuthClient.claude.authorizationURL(port: 5123, challenge: "abc", state: "xyz")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        #expect(query["redirect_uri"] == "http://localhost:5123/callback")
        #expect(query["scope"] == "user:profile")
        #expect(OAuthClient.for(.anthropicAPI) == nil)
    }

    @Test func pkceChallengeIsTheSHA256OfTheVerifier() {
        // RFC 7636, appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func readsAClaudeTokenResponse() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let data = Data("""
            {"access_token":"sk-ant-oat01-a","refresh_token":"sk-ant-ort01-b","expires_in":28800,
             "token_type":"Bearer","account":{"uuid":"u","email_address":"me@example.com"}}
            """.utf8)
        let login = try #require(OAuthLogin.from(data, now: now))
        #expect(login.accessToken == "sk-ant-oat01-a")
        #expect(login.refreshToken == "sk-ant-ort01-b")
        #expect(login.expiresAt == now.addingTimeInterval(28800))
        #expect(login.email == "me@example.com")
    }

    @Test func readsAnOpenAITokenResponse() throws {
        let idToken = jwt([
            "email": "me@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"],
        ])
        let access = jwt(["exp": 2_000_000])
        let data = Data("""
            {"access_token":"\(access)","refresh_token":"rt","id_token":"\(idToken)"}
            """.utf8)
        let login = try #require(OAuthLogin.from(data))
        #expect(login.accountID == "acct-1")
        #expect(login.email == "me@example.com")
        #expect(login.expiresAt == Date(timeIntervalSince1970: 2_000_000))
    }

    @Test func aRefreshKeepsWhatTheResponseLeavesOut() throws {
        let previous = OAuthLogin(accessToken: "old", refreshToken: "rt", expiresAt: nil,
                                  accountID: "acct-1", email: "me@example.com")
        let login = try #require(OAuthLogin.from(Data(#"{"access_token":"new"}"#.utf8), previous: previous))
        #expect(login.accessToken == "new")
        #expect(login.refreshToken == "rt")
        #expect(login.accountID == "acct-1")
        #expect(login.email == "me@example.com")
    }

    @Test func freshnessLeavesAMargin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func login(expiringIn seconds: TimeInterval?) -> OAuthLogin {
            OAuthLogin(accessToken: "a", expiresAt: seconds.map { now.addingTimeInterval($0) })
        }
        #expect(login(expiringIn: nil).isFresh(at: now))
        #expect(login(expiringIn: 3600).isFresh(at: now))
        #expect(!login(expiringIn: 60).isFresh(at: now))
    }

    @Test func storedLoginRoundTrips() throws {
        let secrets = MemorySecrets()
        let repository = AccountRepository(defaults: MemorySettings(), secrets: secrets)
        let account = Account(kind: .codex, credential: .oauth)
        let login = OAuthLogin(accessToken: "a", refreshToken: "r",
                               expiresAt: Date(timeIntervalSince1970: 1_000_000), accountID: "x", email: "e")
        repository.setOAuthLogin(login, for: account)
        #expect(repository.oauthLogin(for: account) == login)
        // Kept apart from a pasted token, so switching sources loses neither.
        #expect(repository.secret(for: account) == nil)
        repository.setOAuthLogin(nil, for: account)
        #expect(repository.oauthLogin(for: account) == nil)
    }

    @Test func callbackServerReturnsTheRedirectQuery() async throws {
        let server = try await CallbackServer.start(port: nil, path: "/callback")
        defer { server.stop() }
        #expect(server.port != 0)

        async let query = server.callback()
        let (_, notFound) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/favicon.ico")!)
        #expect((notFound as? HTTPURLResponse)?.statusCode == 404)
        let (body, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/callback?code=c1&state=s1")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("signed in"))
        #expect(try await query == ["code": "c1", "state": "s1"])
    }

    @Test func aBusyPortIsReported() async throws {
        let first = try await CallbackServer.start(port: nil, path: "/callback")
        defer { first.stop() }
        await #expect(throws: OAuthError.portInUse(first.port)) {
            _ = try await CallbackServer.start(port: first.port, path: "/callback")
        }
    }
}
