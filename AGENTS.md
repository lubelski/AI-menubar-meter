# Agent guidance

Rules for coding agents working in this repository. `README.md` covers what the app does and how it's built.

## How to work

By default, work in your own git worktree under `./.wt/`, named like `./.wt/wt-01/`, on a branch for the task. Commit and push as you go, and open a PR when the work is ready for review.

The worktree keeps your changes apart from the main checkout and from other agents. Pushing as you go means the work survives if the session ends early. `/.wt/` is already in `.gitignore`.

## Screenshots in pull requests

A PR that changes anything a person sees must include screenshots of each changed state in its description. This covers the menu bar icon, the panel, Settings, and any text or layout in them.

- Show every state the change touches, not only the default one. Include error states, empty states, and states that are in progress.
- Capture the entire window (the whole panel or the whole Settings window), even when the change is in one part of it. The rest of the window gives the reader context.
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

### Attaching the images

Upload screenshots with `gh`'s `--attach` flag. It works on `gh pr create`, `gh pr edit` and `gh pr comment`, and takes up to 50 files per command.

- Reference each image in the body by its local path, as in `![Panel, error state](./shots/panel-error.png)`, and pass the same file with `--attach`. `gh` uploads it and rewrites the reference to the uploaded asset.
- An attached file the body doesn't reference is appended to the end. Give it alt text after `#`: `--attach './panel-error.png#Panel, error state'`.

Don't commit screenshots to the repo or to a side branch.

## Building and running

Run only the app bundle that `scripts/bundle.sh` builds, never `swift run`. `swift build` stamps the binary with the wrong SDK version, and the panel then misbehaves. `docs/investigations/2026-11-09-panel-glass-bands.md` has the details.
