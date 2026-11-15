import SwiftUI

/// The About tab: what the app is, which build is running, and where it comes from.
struct AboutView: View {
    private static let repository = URL(string: "https://github.com/lubelski/AI-menubar-meter")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        return switch (short, build) {
        case let (short?, build?): "Version \(short) (\(build))"
        case let (short?, nil): "Version \(short)"
        default: "Development build"
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

            Text("How much of each AI allowance you have left, in the menu bar.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

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
