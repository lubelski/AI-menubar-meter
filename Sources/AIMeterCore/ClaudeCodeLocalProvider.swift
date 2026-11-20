import Foundation

/// Spend estimated on this Mac from Claude Code's own logs, with no key and no network.
///
/// Claude Code writes one JSON line per API response under `~/.claude/projects`, with the
/// model and the token counts but no dollar amount. This prices each response at
/// Anthropic's list prices. It covers Claude Code on this Mac only, and it counts every
/// response the same way: the logs don't say whether a subscription or an API key paid.
public struct ClaudeCodeLocalProvider: Sendable {
    public init() {}

    /// The folder Claude Code keeps its session logs in.
    public static var defaultLogFolder: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        return config.appending(path: "projects")
    }

    public func fetch(
        _ account: Account, folder: URL = Self.defaultLogFolder, now: Date = .now, calendar: Calendar = .current
    ) async throws(ProviderError) -> Reading {
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { throw .noLogs }
        let month = calendar.dateInterval(of: .month, for: now)!
        let responses = await ClaudeCodeLog.shared.responses(in: folder, since: month.start)
        return Reading(spend: Self.spend(from: responses, now: now, calendar: calendar))
    }

    /// Today and this month are the Mac's own calendar day and month.
    static func spend(from responses: [ClaudeCodeLog.Response], now: Date, calendar: Calendar) -> Spend {
        let day = calendar.dateInterval(of: .day, for: now)!
        let month = calendar.dateInterval(of: .month, for: now)!
        var today = 0.0, monthToDate = 0.0
        var unpriced: Set<String> = []
        // A resumed session and a subagent's file can repeat a response that another file has.
        var seen: Set<String> = []
        for response in responses where response.time >= month.start && response.time <= now {
            guard seen.insert(response.id).inserted else { continue }
            guard let dollars = response.dollars else {
                unpriced.insert(response.model)
                continue
            }
            monthToDate += dollars
            if response.time >= day.start { today += dollars }
        }
        return Spend(today: today, monthToDate: monthToDate, resetsAt: day.end,
                     isUTCDay: false, unpricedModels: unpriced.sorted())
    }
}

/// Reads Claude Code's session logs and remembers what each file held, so a refresh
/// only reads the files that changed since the last one.
actor ClaudeCodeLog {
    static let shared = ClaudeCodeLog()

    /// One API response that used tokens.
    struct Response: Equatable, Sendable {
        /// The message id and request id together. Claude Code writes one line per content
        /// block, so a response with three blocks appears three times with the same usage.
        var id: String
        var time: Date
        var model: String
        /// `nil` when `ModelPrices` has no entry for the model.
        var dollars: Double?
    }

    private struct CachedFile {
        var size: Int
        var modified: Date
        var responses: [Response]
    }

    private var files: [URL: CachedFile] = [:]

    /// Every response in the files under `folder` that changed on or after `since`.
    func responses(in folder: URL, since: Date) -> [Response] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        var current: [URL: CachedFile] = [:]
        while let url = found?.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize, let modified = values.contentModificationDate,
                  modified >= since else { continue }
            if let cached = files[url], cached.size == size, cached.modified == modified {
                current[url] = cached
            } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                current[url] = CachedFile(size: size, modified: modified, responses: Self.parse(data))
            }
        }
        // Files that are gone or too old drop out of the cache here.
        files = current
        return current.values.flatMap(\.responses)
    }

    private struct Line: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct CacheCreation: Decodable {
                    var ephemeral_5m_input_tokens: Int?
                    var ephemeral_1h_input_tokens: Int?
                }
                var input_tokens: Int?
                var output_tokens: Int?
                var cache_read_input_tokens: Int?
                var cache_creation_input_tokens: Int?
                var cache_creation: CacheCreation?
                var speed: String?
            }
            var id: String?
            var model: String?
            var usage: Usage?
        }
        var timestamp: String?
        var requestId: String?
        var message: Message?
    }

    private static let usageMarker = Data(#""usage""#.utf8)

    /// The responses in one log file, each counted once.
    static func parse(_ data: Data) -> [Response] {
        var responses: [Response] = []
        var seen: Set<String> = []
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Most lines are prompts and tool results. Skip them without decoding.
            guard line.range(of: usageMarker) != nil,
                  let entry = try? decoder.decode(Line.self, from: line),
                  let message = entry.message, let model = message.model, let logged = message.usage,
                  let time = entry.timestamp.flatMap(Timestamp.parse) else { continue }

            var usage = TokenUsage(
                input: logged.input_tokens ?? 0, output: logged.output_tokens ?? 0,
                cacheRead: logged.cache_read_input_tokens ?? 0, isFast: logged.speed == "fast")
            if let split = logged.cache_creation {
                usage.cacheWrite5m = split.ephemeral_5m_input_tokens ?? 0
                usage.cacheWrite1h = split.ephemeral_1h_input_tokens ?? 0
            } else {
                usage.cacheWrite5m = logged.cache_creation_input_tokens ?? 0
            }
            // Claude Code logs its own error messages as responses from a model that used nothing.
            guard !usage.isEmpty else { continue }

            // A line with neither id can't be matched to its repeats, so it counts by itself.
            let id = message.id == nil && entry.requestId == nil
                ? "\(entry.timestamp ?? "")|\(responses.count)"
                : "\(message.id ?? "")|\(entry.requestId ?? "")"
            guard seen.insert(id).inserted else { continue }
            responses.append(Response(id: id, time: time, model: model,
                                      dollars: ModelPrices.dollars(for: usage, model: model)))
        }
        return responses
    }
}
