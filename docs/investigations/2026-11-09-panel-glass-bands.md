# Empty glass above and below the panel

First seen 2026-11-09. Cause confirmed 2026-11-10. macOS 27.2 (26B123), Xcode with the macOS 27.2 SDK.

## Symptom

The panel showed a band of empty glass above its content and an equal band below it.
The content sat in a dark rectangle with square corners, centered inside a taller rounded panel.

The fault appeared when the content of the panel got shorter while the panel was open.
The reported case: the panel showed the Claude Code sign-in problem, the user clicked "Try Again", the retry succeeded, and the sign-in text went away.

## Cause

The binary of the app said that it was built with the macOS 15.0 SDK. It was built with the macOS 27.2 SDK.

Every Mach-O binary records two versions in its `LC_BUILD_VERSION` load command: the oldest macOS it runs on (`minos`) and the SDK it was linked against (`sdk`).
AppKit and SwiftUI read the `sdk` value when the app starts.
An app linked against an SDK older than macOS 26 runs in a compatibility mode that keeps the behavior and the appearance from before Liquid Glass.

`swift build` wrote `sdk 15.0` into the binary.
15.0 is the deployment target from `Package.swift`, not the SDK.
The object files of the same build carry `sdk 27.2`, so the link step sets the wrong value.
SwiftPM has two build engines, and only the default one does this:

| Build | `minos` | `sdk` |
|---|---|---|
| `swift build` (default engine, `swiftbuild`) | 15.0 | 15.0 |
| `swift build --build-system native` (deprecated) | 15.0 | 27.2 |
| `swiftc` called directly with `-target arm64-apple-macos15.0` | 15.0 | 27.2 |

Which input to the link step causes the wrong value is not known. The link command contains no explicit version flag.

In the compatibility mode on macOS 27.2, the window of a `MenuBarExtra` with the `.window` style does not shrink when its content shrinks while the panel is open.
The window keeps its height, and SwiftUI centers the shorter content inside it.

## Evidence

A test harness runs the real `MenuBarExtra` and `UsagePanel` with stub data (see "How to script the panel").
The harness was built once with `swiftc`, which stamps `sdk 27.2`. A second copy of the same binary was restamped:

```sh
vtool -set-build-version macos 15.0 15.0 -replace -output harness-sdk15 harness
codesign --force --sign - harness-sdk15
```

Both copies ran the same sequence: show the sign-in problem, open the panel, let a successful refresh land 0.5 seconds later.

| Stamp | Window before | Window after | Content after |
|---|---|---|---|
| `sdk 27.2` | 427 | 309 | 309 |
| `sdk 15.0` | 423 | 423 | 309, centered, 57 points from the top and the bottom |

The `sdk 15.0` copy showed the fault in 3 of 3 runs, and its screenshot matches the reported one.
The `sdk 27.2` copy resized correctly in every run, here and in about 20 other sequences on 2026-11-09.

The first sighting, on 2026-11-09, showed 375 points of glass around 309 points of content.
A panel in which the OpenAI account has no reading is 376 points tall.
The belief is that the panel was opened while that account was still loading, and that the content shrank when the reading arrived. That case was not rerun.

## Fix

`scripts/bundle.sh` writes the real SDK version into the binary after the build, with `vtool -set-build-version`, and then signs the bundle.
It reads the version from `xcrun --sdk macosx --show-sdk-version`.
The script fails if the binary does not carry that version afterwards.

The app now runs on the current code path of macOS 26 and later:

- The panel window follows its content.
- The panel is drawn as a rounded Liquid Glass panel instead of a flat dark rectangle with a hairline border.
- Settings uses the current control styles. All three tabs still fit in the 660 by 520 point window without scrolling. On the Accounts tab this was checked for a Claude Code login, a Codex login, and an Anthropic API key. The forms for a pasted token were not checked.

## What is not fixed or not verified

- A binary from `swift build` or `swift run` alone still carries `sdk 15.0` and still shows the fault. Only the bundle from `scripts/bundle.sh` is stamped.
- macOS 15 was not tested. There the old code path is the only one. Whether a panel shrinks correctly on a real macOS 15 system is unknown.
- `.fixedSize(horizontal: false, vertical: true)` on the panel came from commit `a7a9eb4`, an earlier attempt at this symptom. It keeps the content at its ideal height. It never prevented the fault. Whether the panel needs it on macOS 15 was not tested, so it stays.

## What the first investigation got wrong

The write-up of 2026-11-09 blamed the install script, which started the new app a fraction of a second after it killed the old one.
That explanation was a belief, and it is wrong.
The harness could not reproduce the fault because `swiftc` gave it the correct SDK stamp, so it never ran in the compatibility mode.
The changes to the install script from that day (wait for the old process to exit, keep one bundle, register it) are still reasonable. They did not fix this fault.

Findings from that investigation that still hold on the current code path:

- SwiftUI owns the frame of the panel window. The window class is `SwiftUI.MenuBarExtraWindow`, and it overrides `setFrame(_:display:)`. When other code changes the frame, SwiftUI resets it within about 20 ms, and the panel then closes. Do not fix a size problem by setting the frame of this window.
- The glass is not a separate window. The window list of the window server shows no window from any process behind the panel.
- Neither the app's preferences nor its saved application state holds a panel size.

## How to check a build

```sh
xcrun vtool -show-build "$HOME/Applications/AI Meter.app/Contents/MacOS/AIMeter"
```

`sdk` must be the version of the installed macOS SDK (`xcrun --sdk macosx --show-sdk-version`), and never the same as `minos`.
A flat dark panel with a hairline border and square inner corners is the visible sign of the compatibility mode.

## How to script the panel

Build the app's sources, minus `AIMeterApp.swift`, with a small `@main` that injects a `UsageStore` with a stub `fetch`.
Compile `Sources/AIMeterCore` as a static library first, then the app sources with `swiftc`.
Check the SDK stamp of the result, and restamp a copy when the compatibility mode is the subject of the test.

On this macOS version the menu bar item is an `NSSceneStatusItem`, and the system opens the panel through a private session.
`performClick`, synthetic mouse events on the status item, and an accessibility press do nothing.
The harness opens the panel with a private call instead. It is for a throwaway harness only and must not ship.

```swift
// The status item behind the MenuBarExtra. `button` is the NSStatusBarButton
// found in the app's NSStatusBarWindow.
let item = button.value(forKey: "statusItem") as? NSStatusItem
_ = item?.perform(NSSelectorFromString("_requestExpandedInterfaceSession"))

// The panel is then the visible window whose class name contains "MenuBarExtraWindow".
// To close it:
(item?.value(forKey: "expandedInterfaceSession") as AnyObject?)?.perform(NSSelectorFromString("cancel"))
```

Three more notes for the harness:

- A synthetic mouse event does work inside the open panel. Send it with `window.sendEvent(_:)` on the panel window.
- To measure what the content needs, ask a separate offscreen host: `NSHostingView(rootView: UsagePanel(store: store)).fittingSize.height`. The panel's own hosting view reports no fitting size.
- Each run opens a real panel and takes keyboard focus. In the compatibility mode the panel also closes when the app stops being the active app, so activity in other apps changes the result.

## Reference heights

Two accounts, Claude with one model-scoped row, 290 points wide, measured with the `sdk 27.2` harness.

| State | Height |
|---|---|
| Both accounts loading | 184 |
| Both accounts current | 309 |
| Both readings out of date | 356 |
| A third account that cannot sign in | 377 |
| Claude with a plan API credit tank | 385 |
| Claude with the Claude Code sign-in fix showing | 427 |
