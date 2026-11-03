# AI Meter

A small macOS menu bar app that shows five thermometers for your AI usage:

| Group  | Gauges |
|--------|--------|
| Claude | 5-hour session · weekly |
| API credit | dollars used of the Claude plan's API credit |
| OpenAI (Codex) | 5-hour session · weekly |

Gauges are monochrome while everything's fine and turn orange at 75% and red at 90%.
Session bars are thinnest, weekly bars medium, and the API credit bar widest.
A small logo can lead each brand's meters: Claude's spark before Claude and API credit, OpenAI's knot before Codex.
Click the icon for detail: percent used, reset times, and a tick on each bar that marks
**even pace** (how much of the window has elapsed). Fill past the tick means you're burning faster than the window refills.
The arrow in each section header opens that service's own usage page: claude.ai, ChatGPT's Codex usage, or the Claude Platform cost page when API Credit uses an Admin API key.

## Settings

Open from the panel's ⋯ menu (⌘,):

- **Meters**: drain as you use them (the default), or fill up as you use them. Values always say "used" or "left".
- **Service logos**: show or hide the logos in the menu bar and panel.
- **Pace marker**: show or hide the even-pace tick.
- **Show**: hide Claude, API credit, or OpenAI from both the menu bar and the panel.
- **Refresh** interval (1–15 min) and **Launch at login**.

## Accounts

Settings → Accounts lists each service with its connection status. You can switch the sign-in source for each:

| Service | Default | Alternative |
|---|---|---|
| Claude | Claude Code's login (Keychain `Claude Code-credentials`, read via `/usr/bin/security` so there's no prompt) | Pasted OAuth access token |
| OpenAI | Codex CLI's `auth.json` (folder is configurable; defaults to `$CODEX_HOME` or `~/.codex`) | Pasted ChatGPT access token + optional account ID |
| API Credit | The credit included with your Claude plan, from the Claude response | Anthropic Admin API key: month-to-date spend from `/v1/organizations/cost_report` against a monthly budget you set |

Pasted secrets live in AI Meter's own Keychain items (service `dev.lubelski.AIMeter`), never in UserDefaults.

The Claude and OpenAI usage endpoints are the undocumented ones `claude /usage` and `codex /status` use, so they may change.
AI Meter never refreshes or writes CLI tokens. If one expires, run `claude` or `codex` once.

Polling runs every 5 minutes, again on wake, and when the panel opens if the data is more than a minute old.

## Build

Requires Xcode (for SwiftUI macros). `xcode-select` doesn't need to point at it; the script sets `DEVELOPER_DIR`.

```sh
./scripts/bundle.sh            # builds build/AI Meter.app
./scripts/bundle.sh --install  # also copies to ~/Applications and launches
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Layout

- `Sources/AIMeterCore`: models, credential loading, providers, `UsageStore` (testable, no UI)
- `Sources/AIMeter`: SwiftUI `MenuBarExtra`, the panel, and the drawn menu bar icon
- `Tests/AIMeterCoreTests`: parsing and formatting tests built from real response shapes
