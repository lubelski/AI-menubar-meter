import Foundation

enum HTTP {
    static func get(_ url: URL, headers: [String: String]) async throws(ProviderError) -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIMeter/1.0", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw .network("Offline")
        } catch {
            throw .network("Couldn't connect")
        }

        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 401, 403: throw .sessionExpired
        case 429: throw .rateLimited
        case let code: throw .network("Server error \(code)")
        }
    }
}
