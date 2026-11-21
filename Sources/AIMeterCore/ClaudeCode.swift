import Foundation

/// Why AI Meter can't use the Claude Code login. Each case has a different fix.
public enum ClaudeCodeIssue: Error, Sendable, Equatable {
    /// No Claude Code login exists, or Claude Code reports that it is signed out.
    case signedOut
    /// The refresh token has expired, so only a new sign-in helps.
    case loginExpired
    /// Claude Code is signed in, but its access token is still expired or rejected
    /// after AI Meter asked the CLI to refresh it.
    case refreshFailed
    /// There is no usable login, and AI Meter can't find the `claude` command to refresh it.
    case cliNotFound
}

/// The OAuth login that Claude Code stores in the Keychain (older versions used a file).
struct ClaudeCodeLogin: Sendable, Equatable {
    var accessToken: String
    var expiresAt: Date?
    var refreshExpiresAt: Date?
    /// `subscriptionType`, such as `pro` or `max`.
    var plan: String?
    /// `rateLimitTier`, such as `default_claude_max_20x`.
    var rateLimitTier: String?

    /// The plan's name as Anthropic sells it now. Max 20x was renamed Ultra in late
    /// October 2026 and Max 5x became plain Max, but Claude Code still stores `max` for
    /// both. The rate-limit tier tells them apart.
    var planName: String? {
        if plan == "ultra" || rateLimitTier?.contains("max_20x") == true { return "Ultra" }
        return plan?.capitalized
    }

    /// A token that expires within a minute counts as expired, so a fetch can't race the expiry.
    func isUsable(at now: Date = .now) -> Bool {
        expiresAt.map { $0 > now.addingTimeInterval(60) } ?? true
    }

    /// True when the refresh token itself has expired.
    func needsNewSignIn(at now: Date = .now) -> Bool {
        refreshExpiresAt.map { $0 <= now } ?? false
    }

    static func decode(_ data: Data) -> ClaudeCodeLogin? {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                var accessToken: String
                var expiresAt: FlexibleNumber?
                var refreshTokenExpiresAt: FlexibleNumber?
                var subscriptionType: String?
                var rateLimitTier: String?
            }
            var claudeAiOauth: OAuth
        }
        guard let oauth = try? JSONDecoder().decode(Payload.self, from: data).claudeAiOauth,
              !oauth.accessToken.isEmpty else { return nil }
        return ClaudeCodeLogin(
            accessToken: oauth.accessToken,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0.value / 1000) },
            refreshExpiresAt: oauth.refreshTokenExpiresAt.map { Date(timeIntervalSince1970: $0.value / 1000) },
            plan: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )
    }

    /// The login with the latest expiry. An old `~/.claude/.credentials.json` can sit
    /// next to a current Keychain item, and the stale one must not win.
    static func newest(_ candidates: [ClaudeCodeLogin?]) -> ClaudeCodeLogin? {
        candidates.compactMap(\.self).max {
            ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast)
        }
    }

    /// Reads the Keychain item through `/usr/bin/security`, because that tool is already on
    /// the item's access list. This avoids a Keychain prompt on every rebuild of an ad-hoc-signed app.
    static func read() async -> ClaudeCodeLogin? {
        let keychain = (try? await Subprocess.run(
            "/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )).flatMap(decode)
        let file = (try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json"))).flatMap(decode)
        return newest([keychain, file])
    }

    /// Decides whether `login` can be used, given that the server rejected `rejected`.
    /// Returns nil when asking the CLI to refresh the login might help.
    static func resolve(_ login: ClaudeCodeLogin?, rejecting rejected: String?) -> Result<ClaudeCodeLogin, ClaudeCodeIssue>? {
        guard let login else { return nil }
        if login.isUsable(), login.accessToken != rejected { return .success(login) }
        if login.needsNewSignIn() { return .failure(.loginExpired) }
        return nil
    }

    /// Decides the outcome after AI Meter asked the CLI to refresh the login.
    static func resolve(
        _ login: ClaudeCodeLogin?, rejecting rejected: String?, after nudge: ClaudeCodeCLI.NudgeResult
    ) -> Result<ClaudeCodeLogin, ClaudeCodeIssue> {
        if let resolved = resolve(login, rejecting: rejected) { return resolved }
        switch nudge {
        case .noCLI: return .failure(.cliNotFound)
        case .ran(loggedIn: false): return .failure(.signedOut)
        case .ran, .throttled: return .failure(login == nil ? .signedOut : .refreshFailed)
        }
    }
}

/// Decodes a number that may arrive as a JSON number or a numeric string.
private struct FlexibleNumber: Decodable {
    var value: Double

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let number = Double(try container.decode(String.self)) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a number")
        }
    }
}

/// Runs the `claude` CLI so that Claude Code refreshes its own login. AI Meter never
/// uses the refresh token itself, because a refresh would rotate the token out from under Claude Code.
public actor ClaudeCodeCLI {
    public static let shared = ClaudeCodeCLI()

    enum NudgeResult: Equatable {
        /// A nudge ran recently, so this one was skipped.
        case throttled
        case noCLI
        /// `loggedIn` is nil when the CLI's output couldn't be read.
        case ran(loggedIn: Bool?)
    }

    /// Background refreshes ask the CLI at most this often while the login stays broken.
    static let nudgeInterval: TimeInterval = 10 * 60

    private var cachedURL: URL?
    private var lastNudge: Date?
    private var skipThrottleOnce = false

    /// Lets the next nudge run even if one ran recently. Used by the user's "Try Again" button.
    public func allowImmediateNudge() {
        skipThrottleOnce = true
    }

    /// Path of the `claude` executable, or nil when it isn't installed.
    public func path() async -> String? {
        if let cachedURL, FileManager.default.isExecutableFile(atPath: cachedURL.path) {
            return cachedURL.path
        }
        cachedURL = await Self.locate()
        return cachedURL?.path
    }

    /// Runs `claude auth status`, which loads the stored login and refreshes it if it has expired.
    /// AI Meter stops waiting after 30 seconds but never kills the CLI. A CLI that exits
    /// partway through a refresh can lose the rotated token and sign the user out.
    func nudge() async -> NudgeResult {
        if !skipThrottleOnce, let lastNudge, Date.now.timeIntervalSince(lastNudge) < Self.nudgeInterval {
            return .throttled
        }
        skipThrottleOnce = false
        guard let path = await path() else { return .noCLI }
        lastNudge = .now

        struct Status: Decodable { var loggedIn: Bool }
        let output = try? await Subprocess.run(path, ["auth", "status", "--json"],
                                               environment: Self.environment, timeout: 30, onTimeout: .detach)
        return .ran(loggedIn: output.flatMap { try? JSONDecoder().decode(Status.self, from: $0) }?.loggedIn)
    }

    /// The CLI finds its Keychain item by user name. Without `USER` it reports "signed out".
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        environment["HOME"] = home
        environment["USER"] = NSUserName()
        environment["LOGNAME"] = NSUserName()
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        return environment
    }

    /// Apps launched from Finder don't get the shell's `PATH`, so check the usual install
    /// locations first and fall back to asking a login shell.
    private static func locate() async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        guard let output = try? await Subprocess.run("/bin/zsh", ["-lc", "command -v claude"], timeout: 10) else {
            return nil
        }
        let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
            ? URL(fileURLWithPath: path) : nil
    }
}
