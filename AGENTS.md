# Agent guidance

Rules for coding agents working in this repository. `README.md` covers what the app does and how it's built.

## Screenshots in pull requests

A PR that changes anything a person sees must include screenshots of each changed state in its description. This covers the menu bar icon, the panel, Settings, and any text or layout in them.

- Show every state the change touches, not only the default one. Include error states, empty states, and states that are in progress.
- Use dark mode, unless the change is specific to light mode. In that case, show both.
- Look at each screenshot before posting it. A screenshot that shows a bug means the change isn't done.
- When stand-in data appears, say so in the PR, and use placeholder emails and names, never real ones.

### Making screenshots without taking focus

Will works on the same Mac. Before running anything that opens a real window or panel, ask him first and give a time estimate.

Prefer a windowless render:
1. Compile the app's SwiftUI sources (all but `AIMeterApp.swift`) with a small `main.swift`. Link it against `AIMeterCore` from `swift build`.
2. Call `NSApp.setActivationPolicy(.prohibited)`.
3. Put the view in an `NSHostingView` inside an `NSWindow` that is never ordered front. Draw it into a bitmap with `cacheDisplay(in:to:)`.

Build a `UsageStore` with an in-memory `SettingsStore` and `SecretStore` and a stub `fetch`, so no real accounts or Keychain items are read.

Two pitfalls:
- **Async state:** wait with `await Task.sleep`, not `RunLoop.run`. The top-level code runs on the main actor, so blocking the run loop stops async state changes from arriving before the render.
- **Background:** give the root view `.background(Color(nsColor: .windowBackgroundColor))`, or parts of the image render transparent.

### Where the images go

1. Commit the images to the `pr-assets` branch, in a folder named after the PR's branch.
2. Link each one as `https://github.com/lubelski/AI-menubar-meter/blob/<commit-sha>/<path>?raw=true`. The repo is private, so `raw.githubusercontent.com` links don't load.

## Building and running

Run only the app bundle that `scripts/bundle.sh` builds, never `swift run`. `swift build` stamps the binary with the wrong SDK version, and the panel then misbehaves. `docs/investigations/2026-11-09-panel-glass-bands.md` has the details.
