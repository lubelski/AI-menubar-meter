# AI Meter

A small macOS menu bar app that shows how much of each AI allowance you have left, as a row of tanks that drain.

| Account kind | Tanks |
|--------|--------|
| Claude | 5-hour session · weekly · API credit, when the plan includes one |
| OpenAI (Codex) | 5-hour session · weekly |
| Anthropic API | month-to-date spend against a budget you set |

You can add any number of accounts of each kind, for example three OpenAI accounts and no Claude account.

Session tanks are thinnest, weekly tanks medium, and dollar tanks widest.
The panel draws the same tanks at twice the size, with the percent left and the reset time beside each one.
In the panel, a tick on each tank marks **even pace**: where the level would be if usage were spread evenly across the window.
A level below the tick means you're burning faster than the window refills.

## Reading a tank

| Drawing | Meaning |
|---|---|
| Solid level, monochrome | A current reading |
| Solid level, orange | Under 25% left |
| Red outline and red level | Under 10% left. An empty tank is a red outline with nothing in it. |
| Striped level, never colored | The last reading, which is out of date |
| Dashed outline | AI Meter can't read the account and has no earlier reading |
| Faint outline | The first reading hasn't arrived yet |

A reading is out of date when it has missed two refreshes, or when the account needs you to sign in again.
The panel says how old the reading is and why.

## Settings

Open from the panel's ⋯ menu (⌘,). Each tab fits the window without scrolling.

- **General**: the refresh interval (1–15 min) and launch at login.
- **Appearance**: show or hide the service logos and the pace marker. A legend shows each way a tank can be drawn.
- **Accounts**: the list of accounts.
- **About**: the version, a link to this repository, and the license.

## Accounts

Settings → Accounts lists your accounts with their connection status. Click + to add one and − to remove the selected one.
Drag a row to change the order in the menu bar. Accounts of the same brand that sit next to each other share one logo.
Each account has a name, a switch that hides it from the menu bar and the panel, and a sign-in source:

| Kind | Default | Alternative |
|---|---|---|
| Claude | Claude Code's login (Keychain `Claude Code-credentials`, read via `/usr/bin/security` so there's no prompt) | Pasted OAuth access token |
| OpenAI | Codex CLI's `auth.json` (the folder is set per account and defaults to `$CODEX_HOME` or `~/.codex`) | Pasted ChatGPT access token + optional account ID |
| Anthropic API | Anthropic Admin API key: month-to-date spend from `/v1/organizations/cost_report` against a monthly budget you set | |

Claude Code keeps one login per Mac, so a second Claude account needs a pasted token.
For a second OpenAI account, run `codex login` with `CODEX_HOME` set to another folder, then choose that folder in the account's settings.

AI Meter also has its own browser sign-in (OAuth with PKCE, a one-shot redirect server on `127.0.0.1`, and logins kept in the Keychain item `account.<id>.oauth` and refreshed by AI Meter). It is not offered yet: it needs an OAuth client that a service issues to AI Meter, and AI Meter never borrows another program's client. Anthropic offers none. OpenAI's "Sign in with ChatGPT" may.

On first launch AI Meter adds an account for each command-line login it finds. An upgrade from 1.0 keeps the accounts that were set up there.

The list of accounts lives in UserDefaults. Pasted secrets live in AI Meter's own Keychain items (service `dev.lubelski.AIMeter`, one item per account), never in UserDefaults.

The Claude and OpenAI usage endpoints are the undocumented ones `claude /usage` and `codex /status` use, so they may change.
AI Meter never refreshes or writes CLI tokens itself, because a refresh rotates the token and would sign the CLI out.
When the Claude Code token expires or the server rejects it, AI Meter runs `claude auth status`, which refreshes the login, and tries again.
It runs that command at most every 10 minutes and never kills it, because a refresh that stops partway can sign you out.
If the refresh doesn't help, the panel and Settings → Accounts explain the problem and offer a button that opens `claude` (or `claude auth login`) in Terminal.
AI Meter watches for the new login and reconnects on its own.
If a Codex token expires, run `codex` once.

Polling runs every 5 minutes, again on wake, and when the panel opens if the data is more than a minute old.

## Build

Requires Xcode (for SwiftUI macros). `xcode-select` doesn't need to point at it; the script sets `DEVELOPER_DIR`.

```sh
./scripts/bundle.sh            # builds build/AI Meter.app
./scripts/bundle.sh --install  # moves it to ~/Applications, replacing the running copy, and launches
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Run the app from the bundle that the script builds, not from `swift run`. `swift build` records the wrong SDK version in the binary, and macOS then runs the app in a compatibility mode in which the panel does not resize correctly. The script corrects the version. The comments in `scripts/bundle.sh` have the details.

## Releases and updates

A release build updates itself with [Sparkle](https://sparkle-project.org). It checks the feed about once a day, downloads a newer build, verifies its signature, and relaunches into it. The panel's ⋯ menu and the About tab have **Check for Updates…**, and the About tab has a checkbox that turns automatic updates off.

```sh
./scripts/release.sh 1.2.0            # build, sign, notarize, and publish v1.2.0 from main
./scripts/release.sh 1.2.0 --dry-run  # build the files into build/release and publish nothing
```

The script publishes a GitHub Release with two files: the zipped app and `appcast.xml`, the feed. Installed copies read the feed from the latest release, so publishing the release ships the update. The one-time setup (a Developer ID certificate, a notarization login, and a Sparkle signing key) is described at the top of the script.

- The version is the release tag. The build number is the commit count, and Sparkle compares build numbers, so releases are built from `main`.
- A build from `bundle.sh` alone has no feed and never updates itself, so a development copy is not replaced by a release.
- The repository that hosts releases must be public. Installed copies download the feed and the app without a login.

## Layout

- `Sources/AIMeterCore`: accounts, readings, credential loading, providers, and `UsageStore` (testable, no UI)
  - `Account.swift`: the kinds of account and what the user stores for each one
  - `Providers.swift`: picks the provider for an account's kind. A new kind needs a case in `AccountKind`, a provider here, and a form in the Accounts settings.
  - `AccountState.swift`: an account with its latest reading, and the rule for when that reading is out of date
- `Sources/AIMeter`: SwiftUI `MenuBarExtra`, the panel, Settings, and `AppUpdater` (Sparkle)
  - `TankDrawing.swift`: the one Core Graphics routine that draws a tank for the menu bar icon, the panel, and the app icon
- `Resources/AppIcon.icon`: the app icon, an Icon Composer file that `bundle.sh` compiles. `scripts/render-icon.sh` redraws its artwork from `TankDrawing.swift`.
- `Tests/AIMeterCoreTests`: parsing tests built from real response shapes, plus tests for the account list, migration, and the store

## License

MIT. See `LICENSE`.
