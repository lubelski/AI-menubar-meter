import CryptoKit
import Foundation

/// An OAuth client that AI Meter signs in with: an authorization-code flow with PKCE that
/// returns to a one-shot server on this Mac.
///
/// No kind of account has a client yet. A client must be one the service issued to
/// AI Meter. Never borrow another program's client, such as a CLI's: that presents AI Meter
/// as that program, which the services' terms forbid.
public struct OAuthClient: Sendable {
    public enum Body: Sendable { case json, form }

    public var clientID: String
    public var authorizeURL: URL
    public var tokenURL: URL
    public var scopes: [String]
    /// A fixed port, when the service only accepts one redirect address. `nil` takes any free port.
    public var fixedPort: UInt16?
    public var callbackPath: String
    /// Extra parameters the service asks for in the authorization request.
    public var extraParameters: [(String, String)] = []
    /// The scope sent with a refresh. `nil` sends none.
    public var refreshScope: String?
    public var exchangeBody: Body = .form
    /// The token exchange repeats `state`, which some services require.
    public var exchangeIncludesState = false

    /// The client for this kind of account, or `nil` when it has no browser sign-in.
    /// Settings offers browser sign-in only for kinds that have one.
    public static func `for`(_ kind: AccountKind) -> OAuthClient? {
        switch kind {
        // Anthropic offers no OAuth to other apps, and its terms keep Claude subscription
        // logins to its own products. OpenAI's own "Sign in with ChatGPT" may fit; it needs
        // a client registered for AI Meter.
        case .claude, .codex, .anthropicAPI: nil
        }
    }

    func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)\(callbackPath)"
    }

    func authorizationURL(port: UInt16, challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        let items: [(String, String)] = extraParameters + [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI(port: port)),
            ("scope", scopes.joined(separator: " ")),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" alone, and form decoders read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

/// A login that AI Meter obtained itself. Stored as JSON in the account's Keychain item for
/// its own sign-in, apart from any pasted token. No other program uses these tokens, so AI Meter
/// may refresh them: the refresh rotates the token, and nothing else holds the old one.
public struct OAuthLogin: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    /// OpenAI only: the ChatGPT workspace the login belongs to.
    public var accountID: String?
    /// The address the user signed in with, shown in Settings.
    public var email: String?

    public init(
        accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
        accountID: String? = nil, email: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
    }

    /// True when the access token has at least `margin` left, or when its expiry is unknown.
    public func isFresh(at now: Date = .now, margin: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > margin
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }

    static func decode(_ string: String) -> OAuthLogin? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(OAuthLogin.self, from: Data(string.utf8))
    }

    /// Builds a login from a token response. `previous` supplies what a refresh response leaves out.
    static func from(_ data: Data, previous: OAuthLogin? = nil, now: Date = .now) -> OAuthLogin? {
        struct Response: Decodable {
            struct Account: Decodable { var email_address: String? }
            var access_token: String
            var refresh_token: String?
            var expires_in: Double?
            var id_token: String?
            var account: Account?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let idClaims = response.id_token.flatMap(JWT.claims)
        let openAIAuth = idClaims?["https://api.openai.com/auth"] as? [String: Any]
        let expiresAt = response.expires_in.map { now.addingTimeInterval($0) }
            ?? (JWT.claims(response.access_token)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
        return OAuthLogin(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? previous?.refreshToken,
            expiresAt: expiresAt,
            accountID: openAIAuth?["chatgpt_account_id"] as? String ?? previous?.accountID,
            email: response.account?.email_address ?? idClaims?["email"] as? String ?? previous?.email
        )
    }
}

/// Reads the claims of a JSON Web Token without checking its signature. The values only
/// label the login in Settings and pick its workspace; the server still checks the token.
enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// The PKCE secret for one sign-in and the challenge derived from it.
struct PKCE {
    var verifier: String
    var challenge: String

    init(verifier: String = randomString()) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomString(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthError: Error, Sendable, Equatable {
    /// Another program holds the port the service redirects to.
    case portInUse(UInt16)
    case cancelled
    case denied(String)
    case stateMismatch
    case exchangeFailed(String)
    case timedOut

    public var message: String {
        switch self {
        case .portInUse(let port):
            "Port \(port) is in use by another program. Close it or finish its sign-in, then try again."
        case .cancelled: "Sign-in was cancelled."
        case .denied(let reason): "The service declined the sign-in: \(reason)."
        case .stateMismatch: "The sign-in reply didn't match this request. Try again."
        case .exchangeFailed(let detail): "Couldn't finish signing in: \(detail)."
        case .timedOut: "Sign-in timed out. Try again."
        }
    }
}

/// Token requests against a service's OAuth server.
enum OAuthTokens {
    static func exchange(
        code: String, client: OAuthClient, port: UInt16, verifier: String, state: String
    ) async throws(OAuthError) -> OAuthLogin {
        var fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", client.redirectURI(port: port)),
            ("client_id", client.clientID),
            ("code_verifier", verifier),
        ]
        if client.exchangeIncludesState { fields.append(("state", state)) }
        let data: Data
        do {
            data = try await post(client.tokenURL, fields: fields, as: client.exchangeBody)
        } catch {
            throw .exchangeFailed(error.message)
        }
        guard let login = OAuthLogin.from(data) else { throw .exchangeFailed("unexpected reply") }
        return login
    }

    /// Exchanges the refresh token for a new login, with the same body format as the code exchange.
    static func refresh(_ login: OAuthLogin, client: OAuthClient) async throws(ProviderError) -> OAuthLogin {
        guard let refreshToken = login.refreshToken else { throw .sessionExpired }
        var fields = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", client.clientID),
        ]
        if let scope = client.refreshScope { fields.append(("scope", scope)) }
        let data: Data
        do {
            data = try await post(client.tokenURL, fields: fields, as: client.exchangeBody)
        } catch .badRequest {
            // invalid_grant: the refresh token was revoked or already used.
            throw .sessionExpired
        } catch {
            throw error.providerError
        }
        guard let refreshed = OAuthLogin.from(data, previous: login) else { throw .unexpectedResponse }
        return refreshed
    }

    enum PostError: Error {
        case badRequest
        case other(ProviderError)

        var providerError: ProviderError {
            switch self {
            case .badRequest: .sessionExpired
            case .other(let error): error
            }
        }

        var message: String {
            switch self {
            case .badRequest: "the server rejected the code"
            case .other(let error): error.message
            }
        }
    }

    private static func post(
        _ url: URL, fields: [(String, String)], as body: OAuthClient.Body
    ) async throws(PostError) -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch body {
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: Dictionary(fields, uniquingKeysWith: { $1 }))
        case .form:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            request.httpBody = Data(fields.map { name, value in
                "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }.joined(separator: "&").utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw .other(.network("Couldn't connect"))
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 400, 401: throw .badRequest
        case 429: throw .other(.rateLimited)
        case let code: throw .other(.network("Server error \(code)"))
        }
    }
}

/// Hands out a usable access token for each account that signed in through AI Meter, and
/// refreshes it when it's close to expiring or the server rejects it. One actor for the whole
/// app, so two fetches never spend the same refresh token: each refresh rotates it.
public actor OAuthSessions {
    public static let shared = OAuthSessions()

    private var refreshing: [String: Task<OAuthLogin, any Error>] = [:]

    public init() {}

    public static func key(for account: Account) -> String { "\(account.secretKey).oauth" }

    public func login(for account: Account, secrets: any SecretStore) -> OAuthLogin? {
        secrets.read(Self.key(for: account)).flatMap(OAuthLogin.decode)
    }

    public func save(_ login: OAuthLogin?, for account: Account, secrets: any SecretStore) {
        secrets.write(login?.encoded() ?? "", for: Self.key(for: account))
    }

    /// A login whose access token is fresh. Refreshes first when the stored one is about to
    /// expire, or when the server rejected `rejected`.
    func usableLogin(
        for account: Account, secrets: any SecretStore, rejecting rejected: String? = nil
    ) async throws(ProviderError) -> OAuthLogin {
        guard let client = OAuthClient.for(account.kind),
              let stored = login(for: account, secrets: secrets) else { throw .notSignedIn }
        if stored.isFresh(), stored.accessToken != rejected { return stored }

        let key = Self.key(for: account)
        let task: Task<OAuthLogin, any Error>
        if let running = refreshing[key] {
            task = running
        } else {
            task = Task { try await OAuthTokens.refresh(stored, client: client) }
            refreshing[key] = task
        }
        do {
            let refreshed = try await task.value
            if refreshing[key] == task {
                refreshing[key] = nil
                save(refreshed, for: account, secrets: secrets)
            }
            return refreshed
        } catch {
            if refreshing[key] == task { refreshing[key] = nil }
            throw (error as? ProviderError) ?? .unexpectedResponse
        }
    }
}
