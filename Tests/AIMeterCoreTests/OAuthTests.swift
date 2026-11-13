import Foundation
import Testing
@testable import AIMeterCore

private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "e30.\(PKCE.base64URL(payload)).sig"
}

@Suite("OAuth")
struct OAuthTests {
    private let client = OAuthClient(
        clientID: "client-1",
        authorizeURL: URL(string: "https://auth.example.com/oauth/authorize")!,
        tokenURL: URL(string: "https://auth.example.com/oauth/token")!,
        scopes: ["openid", "email", "offline_access"],
        fixedPort: nil,
        callbackPath: "/callback",
        extraParameters: [("prompt", "login")]
    )

    @Test func authorizationURLCarriesThePKCERequest() throws {
        let url = client.authorizationURL(port: 5123, challenge: "a+b", state: "xyz")
        #expect(url.host() == "auth.example.com")
        // "+" must survive form decoding on the server.
        #expect(url.absoluteString.contains("code_challenge=a%2Bb"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "client-1")
        #expect(query["redirect_uri"] == "http://localhost:5123/callback")
        #expect(query["scope"] == "openid email offline_access")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "xyz")
        #expect(query["prompt"] == "login")
    }

    /// No service has issued AI Meter a client yet, so Settings doesn't offer browser sign-in.
    @Test func noKindOffersBrowserSignInWithoutAClient() {
        for kind in AccountKind.allCases {
            #expect(OAuthClient.for(kind) == nil)
            #expect(!kind.credentialSources.contains(.oauth))
        }
    }

    @Test func pkceChallengeIsTheSHA256OfTheVerifier() {
        // RFC 7636, appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func readsATokenResponseWithAnAccountEmail() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let data = Data("""
            {"access_token":"at-1","refresh_token":"rt-1","expires_in":28800,
             "token_type":"Bearer","account":{"uuid":"u","email_address":"me@example.com"}}
            """.utf8)
        let login = try #require(OAuthLogin.from(data, now: now))
        #expect(login.accessToken == "at-1")
        #expect(login.refreshToken == "rt-1")
        #expect(login.expiresAt == now.addingTimeInterval(28800))
        #expect(login.email == "me@example.com")
    }

    @Test func readsAnIDTokenResponse() throws {
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

import Darwin

@Suite("Callback server port")
struct CallbackPortTests {
    /// Another program may hold a fixed redirect port with an ordinary socket. The sign-in must
    /// not share the port, or the browser's redirect could reach either program.
    @Test func aPortHeldByAnotherProgramIsReported() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        #expect(bound)
        #expect(listen(fd, 1) == 0)
        let port = UInt16(bigEndian: addr.sin_port)
        await #expect(throws: OAuthError.portInUse(port)) {
            let server = try await CallbackServer.start(port: port, path: "/callback")
            server.stop()
        }
    }
}
