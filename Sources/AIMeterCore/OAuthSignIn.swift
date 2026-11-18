import Foundation
import Network

/// Runs one browser sign-in: starts a server on this Mac's loopback address, opens the
/// service's sign-in page, waits for the redirect back, and trades its code for tokens.
public enum OAuthSignIn {
    /// - Parameter open: Opens the sign-in page in the user's browser.
    public static func run(
        _ kind: AccountKind,
        timeout: Duration = .seconds(300),
        open: @Sendable (URL) -> Void
    ) async throws(OAuthError) -> OAuthLogin {
        guard let client = OAuthClient.for(kind) else { throw .exchangeFailed("this kind of account has no sign-in") }
        let pkce = PKCE()
        let state = PKCE.randomString()

        let server = try await CallbackServer.start(port: client.fixedPort, path: client.callbackPath)
        defer { server.stop() }

        open(client.authorizationURL(port: server.port, challenge: pkce.challenge, state: state))

        let query: [String: String]
        do {
            query = try await withThrowingTaskGroup(of: [String: String].self) { group in
                group.addTask { try await server.callback() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw OAuthError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let error as OAuthError {
            throw error
        } catch {
            throw .cancelled
        }

        if let denial = query["error"] {
            throw .denied(query["error_description"] ?? denial)
        }
        guard query["state"] == state else { throw .stateMismatch }
        guard let code = query["code"] else { throw .exchangeFailed("no code in the reply") }
        return try await OAuthTokens.exchange(
            code: code, client: client, port: server.port, verifier: pkce.verifier, state: state)
    }
}

/// A one-shot HTTP server on 127.0.0.1 that waits for the redirect to `path`, answers the
/// browser with a short page, and returns the redirect's query parameters.
final class CallbackServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let path: String
    private let queue = DispatchQueue(label: "dev.lubelski.AIMeter.oauth")
    // Guarded by `queue`.
    private var result: Result<[String: String], OAuthError>?
    private var waiter: CheckedContinuation<[String: String], any Error>?

    private init(listener: NWListener, port: UInt16, path: String) {
        self.listener = listener
        self.port = port
        self.path = path
    }

    static func start(port: UInt16?, path: String) async throws(OAuthError) -> CallbackServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port ?? 0)!)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .portInUse(port ?? 0)
        }

        let ready: Result<UInt16, OAuthError> = await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: .success(listener.port?.rawValue ?? 0)) }
                case .failed, .waiting:
                    once.run { continuation.resume(returning: .failure(.portInUse(port ?? 0))) }
                case .cancelled:
                    once.run { continuation.resume(returning: .failure(.cancelled)) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: DispatchQueue(label: "dev.lubelski.AIMeter.oauth.listener"))
        }
        switch ready {
        case .success(let boundPort):
            let server = CallbackServer(listener: listener, port: boundPort, path: path)
            listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
            return server
        case .failure(let error):
            listener.cancel()
            throw error
        }
    }

    func stop() {
        listener.cancel()
        queue.async {
            self.waiter?.resume(throwing: OAuthError.cancelled)
            self.waiter = nil
        }
    }

    /// Waits for the redirect and returns its query parameters.
    func callback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result.mapError { $0 as any Error })
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Runs on `queue`.
    private func handle(_ head: String, on connection: NWConnection) {
        // "GET /callback?code=…&state=… HTTP/1.1"
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == path else {
            respond(connection, status: "404 Not Found", body: "Not found.")
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }

        let succeeded = query["code"] != nil && query["error"] == nil
        respond(connection, status: "200 OK", body: succeeded
            ? "You're signed in. You can close this tab and go back to AI Meter."
            : "Sign-in didn't finish. Go back to AI Meter to try again.")

        guard result == nil else { return }
        result = .success(query)
        waiter?.resume(returning: query)
        waiter = nil
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
            <!doctype html><meta charset="utf-8"><title>AI Meter</title>
            <body style="font: 15px -apple-system, sans-serif; margin: 4em auto; max-width: 30em; \
            color-scheme: light dark">\(body)</body>
            """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
