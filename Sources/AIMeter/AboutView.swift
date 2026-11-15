import SwiftUI

/// The About tab: what the app is, which build is running, and where it comes from.
struct AboutView: View {
    private static let repository = URL(string: "https://github.com/lubelski/AI-menubar-meter")!

    /// The version and the commit it was built from, such as "Version 1.0 (767c825)".
    /// `scripts/bundle.sh` writes the commit into `AIMeterGitCommit`.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let commit = info?["AIMeterGitCommit"] as? String
        return switch (short, commit) {
        case let (short?, commit?): "Version \(short) (\(commit))"
        case let (short?, nil): "Version \(short)"
        case let (nil, commit?): "Dev build \(commit)"
        default: "Dev build"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            HStack(alignment: .bottom, spacing: 6) {
                TankView(fill: .live(remaining: 0.75, level: .normal), kind: .session, height: 56)
                TankView(fill: .live(remaining: 0.45, level: .normal), kind: .weekly, height: 56)
                TankView(fill: .live(remaining: 0.2, level: .warning), kind: .pool, height: 56)
            }

            VStack(spacing: 4) {
                Text("AI Meter")
                    .font(.title.bold())
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Link("Source code on GitHub", destination: Self.repository)

            Spacer()

            Text("© 2026 William Lubelski. Released under the MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
