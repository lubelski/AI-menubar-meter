# Retrospective: the account rework and the glass fault

Written 2026-11-10. Covers the work of 2026-11-09 and 2026-11-10: PRs #2 to #5.
It does not cover the sessions before 2026-11-09. Those transcripts were not reviewed.

Claude wrote this entry at Will's request. The recommendations are proposals. None is adopted until the file it names contains it.

## What shipped

| PR | Change |
|---|---|
| #2 | Accounts as a list of any number per kind, tanks that drain, a visible state for a reading that is out of date |
| #3 | Install script waits for the old process and keeps one bundle. Tests stopped writing to `~/Library/Preferences` |
| #4 | `scripts/bundle.sh` stamps the binary with the real SDK version. This fixed the empty glass above and below the panel |
| #5 | The footer shows "Updating…" during every refresh. The refresh icon turns only for the refresh button |

## What went wrong

### The test harness was not the shipped app

On 2026-11-09 the harness ran about 20 scripted sequences and never showed the glass fault.
The conclusion was "cannot reproduce", with a belief that the install process caused it.
A sweep of the Mac for old copies of the app, and the install changes in PR #3, followed from that belief.
The belief was wrong.

The harness was built with `swiftc`, which stamped it `sdk 27.2`. The app was built with `swift build`, which stamped it `sdk 15.0`.
macOS ran the two on different code paths, and only the app's path has the fault.
The evidence was available on the first day: the reported screenshot showed a flat dark panel, and the harness screenshots showed Liquid Glass.
Claude did not compare them.

The fault was found on 2026-11-10 after Will reported the exact action that triggered it.
`docs/investigations/2026-11-09-panel-glass-bands.md` has the full account.

Cost: one wrong explanation in a merged write-up, one cleanup pass on a wrong theory, and a day with the fault still present.

### Trials took keyboard focus

Each harness run opens a real menu bar panel. The Settings runs activate the harness app.
About 15 runs happened on 2026-11-10 with no warning, while Will worked on the same Mac.
Will stopped them: "you keep stealing focus".
He then said: "no worries if you need to run some more real trials, just ping me first and we'll estimate and schedule how long that part will take."

A windowless render replaced most of these trials for PR #5.
A process that sets `NSApp.setActivationPolicy(.prohibited)` and draws an `NSHostingView` into a bitmap opens nothing and takes no focus.

### The ship sequence was restated for every PR

Will gave the same instruction in his own words four times: merge, pull `main`, install from `main`.
No file in the repo records that sequence.

### Merged branches stayed on the remote

Claude's request to delete a remote branch was denied by a permission check, which is reasonable for a destructive git command.
Four merged branches now sit on the remote: `accounts-and-tanks`, `panel-height`, `sdk-stamp`, `updating-text`.

### The first design pass added too much

The first proposal for the rework added calculations ("can I start a big task now").
Will's correction: "first things first is a reliable gas meter in a slick looking dash. we can build trip planning software later."
The Linear project description now states that scope.

## What worked

- The first write-up labeled the install explanation as a belief. That made the correction on 2026-11-10 a short edit and not a dispute.
- The investigation note in the repo. The second day started from its recorded measurements and from the private call that opens the panel, not from memory.
- The task worktree flow (`wt switch --create`, PR, merge, `wt remove`) gave four clean merges with no work on `main`.
- A build check that fails loudly. `scripts/bundle.sh` stops if the binary does not carry the expected SDK version.

## Proposed guidance

Each row is a proposal. Where the rule came from Will, the row quotes him, and the guidance must keep his strength.

| Proposal | Where | Source and strength |
|---|---|---|
| Before a "cannot reproduce" conclusion is accepted, list how the test build differs from the shipped build, and compare the two. For a Mac app: `vtool -show-build` on both, and the two screenshots side by side | User `CLAUDE.md` | Claude's recommendation |
| Ask, with a time estimate, before a trial that opens a real window or panel on Will's Mac. Prefer a windowless render when it answers the question | User `CLAUDE.md` | Will: "just ping me first and we'll estimate and schedule how long that part will take". The preference for a windowless render is Claude's addition |
| Remove a task worktree once its branch is merged | `~/dev/AGENTS.md` | Will: "once a wt is fully merged it should be culled (or returned to the pool if pooled)" |
| The ship sequence: merge the PR, pull `main`, run `./scripts/bundle.sh --install` from `main`, remove the worktree | New `AGENTS.md` in this repo | Will's repeated instruction. He has not said that it applies without being asked each time |
| Build and run only the bundle from `scripts/bundle.sh` | New `AGENTS.md` in this repo | Follows from PR #4. Already in `README.md` |
| Images for a PR go on the `pr-assets` branch and are linked as `github.com/<owner>/<repo>/blob/<sha>/<path>?raw=true`, because `raw.githubusercontent.com` fails for a private repo | New `AGENTS.md` in this repo | Claude's recommendation, from a failed first attempt in PR #2 |

The second and third rows exist today as memory notes for this project only. Other projects do not see them.

## Proposed actions

- Check the SDK stamp of Will's other Mac apps that are built with SwiftPM. An app stamped with its deployment target runs in the same compatibility mode. The check is read-only: `xcrun vtool -show-build <binary>`.
- Move the test harness and the windowless renderer into this repo. Both live in a temporary directory of one session and will be deleted with it.
- Turn on "Automatically delete head branches" for the repo on GitHub, and delete the four merged branches.

## Open questions

- Does the panel shrink correctly on a real macOS 15 system? Not tested. Tracked in ENG-249.
- Which input to SwiftPM's link step writes the deployment target into the SDK field? Not known. The stamp in `scripts/bundle.sh` makes the answer optional.
