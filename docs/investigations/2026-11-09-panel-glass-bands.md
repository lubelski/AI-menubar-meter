# Empty glass above and below the panel

Date: 2026-11-09. macOS 27.2 (26B123). Status: cause not confirmed, not reproduced, not present at the end of the investigation.

## Symptom

The panel opened with a band of empty glass above its content and an equal band below it.
One screenshot recorded it. In that screenshot the glass was 375 points tall and the content was 309 points tall.
The glass started at the normal distance below the menu bar, and the content sat centered inside it.

The same symptom led to an earlier change, commit `a7a9eb4`, which added `.fixedSize(horizontal: false, vertical: true)` to the panel.
That change pins the height of the content. It does not explain or prevent a window that is taller than the content.

## What the measurements show

All of these were measured with a test harness that runs the real `MenuBarExtra` and `UsagePanel` with stub data.

- The panel window always matched its content. This held when the content grew or shrank while the panel was open, and while it was closed. It held when a refresh landed 0 to 700 ms after the panel started to open. It held when an account was added or removed, and when the first reading arrived while the panel was open.
- A relaunch did not carry a panel size over. A run with a 453 point panel, followed by a relaunch with a 309 point panel, opened at 309 points. This held for a relaunch after one second and for an immediate one.
- The glass is not a separate window. The window list of the window server shows no window from any process behind the panel, and the panel window has no glass view in its view hierarchy.
- SwiftUI owns the frame of the panel window. The window class is `SwiftUI.MenuBarExtraWindow`. It overrides `setFrame(_:display:)` and `makeKeyAndOrderFront(_:)`. When other code changes the frame, SwiftUI resets it within about 20 ms, and the panel then closes.
- No state of the current build with two accounts is 375 points tall. A scan of 690 combinations of account states found 376 points only when the OpenAI account has no reading at all.
- The panel of the build before the account rework was 376 points tall. That build showed three sections: Claude, API Credit, and OpenAI.

After the investigation, two real openings from the menu bar were recorded from outside the app. In both, the window was 290 by 309 points and the glass matched it.

## What this rules out

- A fix that sets the frame of the panel window. The first attempt did this from an `NSViewRepresentable` in the panel's background. SwiftUI resets such a change, and the panel closes. Do not retry this approach.
- A stale window size after the content shrinks. SwiftUI resizes the window on every content change, and again each time the panel opens.
- A second surface behind the panel that keeps its own size.
- A panel size kept in the app's preferences or in saved application state. Neither holds one.

## Best remaining explanation

This is a belief. No test confirmed it.

The glass had the height of the old build's panel, two launches after that build was replaced.
The install script killed the running app and started the new one a fraction of a second later, from a bundle that it had just overwritten.
It also left a second bundle with the same bundle identifier in `build/`.
The belief is that this handover left the system's side of the menu bar item with the previous size, and that a real click reached that state where the test harness could not.

Two limits of the investigation matter here:

- The harness cannot make a real click. On this macOS version the menu bar item is an `NSSceneStatusItem`, and the system opens the panel through a private session. `performClick`, synthetic mouse events, and an accessibility press do nothing. The harness opens the panel with a private call instead (see below).
- Bartender 7 and Stage Manager were running. Neither was tested as a factor.

## What changed because of it

- `scripts/bundle.sh --install` now waits until the old process has exited before it starts the new one.
- It moves the built bundle to `~/Applications` instead of copying it, so that only one bundle with the app's identifier exists, and it registers that bundle with LaunchServices.

These changes remove the two irregular parts of the install. They are not a verified fix.

## How to investigate if it comes back

1. Record the real panel from outside the app. `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` lists the panel as a window owned by "AI Meter" at layer 101. Compare its height with the content. A height other than the content's means SwiftUI sized the window wrong. An equal height with visible bands means something else draws the glass.
2. Note what happened just before: an install, a wake from sleep, a change in Settings.
3. To script the panel, build the app's sources with a small `@main` that injects a `UsageStore` with a stub `fetch`. Open the panel in that process with the private call below. It is for a throwaway harness only and must not ship.

```swift
// The status item behind the MenuBarExtra. `button` is the NSStatusBarButton
// found in the app's NSStatusBarWindow.
let item = button.value(forKey: "statusItem") as? NSStatusItem
_ = item?.perform(NSSelectorFromString("_requestExpandedInterfaceSession"))

// The panel is then the visible window whose class name contains "MenuBarExtraWindow".
// To close it:
(item?.value(forKey: "expandedInterfaceSession") as AnyObject?)?.perform(NSSelectorFromString("cancel"))
```

To measure what the content needs, ask a separate offscreen host: `NSHostingView(rootView: UsagePanel(store: store)).fittingSize.height`. The panel's own hosting view reports no fitting size.

## Reference heights

Two accounts, Claude with one model-scoped row, 290 points wide.

| State | Height |
|---|---|
| Both accounts loading | 184 |
| Both accounts current | 309 |
| Both readings out of date | 356 |
| A third account that cannot sign in | 377 |
| Claude with a plan API credit tank | 385 |
| Claude with the Claude Code sign-in fix showing | 426 |
