# ClaudeBar

[![CI](https://github.com/ThomasHaas15/ClaudeBar/actions/workflows/ci.yml/badge.svg)](https://github.com/ThomasHaas15/ClaudeBar/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2015-blue.svg)](https://developer.apple.com)

A macOS menu bar app that surfaces **Claude Code** usage at a glance — session and weekly rate limits, daily and lifetime token stats, per-model breakdown, and active sessions. Posts a system notification when any limit crosses 80% or 100%. Local data only, no credentials — its one network call is an hourly check for its own updates, which you can turn off.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/usage.png" alt="Usage tab" width="380"/><br/><em>Usage</em></td>
    <td align="center"><img src="docs/screenshots/stats.png" alt="Stats tab" width="380"/><br/><em>Stats</em></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/models.png" alt="Models tab" width="380"/><br/><em>Models</em></td>
    <td align="center"><img src="docs/screenshots/status.png" alt="Status tab" width="380"/><br/><em>Status</em></td>
  </tr>
</table>

## Features

- **Live rate limits** — Session (5-hour) and Week (all models) percentages with reset times, refreshed on every Claude Code prompt
- **Header at a glance** — today's tokens, weekly-limit delta since midnight, current streak
- **Stats** — tokens this week and this month with a green/red arrow against the same days of the period before, current and longest streak, longest session duration, lifetime totals, full-width activity heatmap (about twenty weeks — as many as the popover fits) — hover a day for its tokens and messages
- **Models** — per-model token share with input/output/cache breakdown and a favorite-model summary. Model names are derived from the id's shape, so a model released after this build still reads as "Opus 6" rather than as a raw id
- **Status** — Claude Code version, session activity ("2 working, 1 waiting, 1 idle"), running session count, launch-at-login toggle, statusline installer
- **Threshold notifications** — fires at 80% and 100% of session and weekly limits, once per reset window
- **Visual indicator in the menu bar** — sparkle glyph picks up a colored dot when any limit goes warning (yellow ≥ 80%) or critical (red = 100%)
- **No credentials** — reads only local files under `~/.claude/`, and writes only its own day-by-day record
- **Updates itself** — checks this repo's releases hourly, installs a newer one and restarts, all without interrupting you
- **Live file watching** — `DispatchSource` vnode events push updates the moment Claude Code writes data

## Quota Status Thresholds

ClaudeBar uses two thresholds for both visual cues and notifications:

| Used | Status   | Bar / dot color | Notification |
|------|----------|------------------|--------------|
| < 80%  | Healthy  | Blue / none      | —            |
| ≥ 80%  | Warning  | Yellow           | "Session limit at 80%" |
| = 100% | Critical | Red              | "Session limit reached" |

Each threshold fires **once per reset window** per limit (Session and Week). When the window resets, the notifications re-arm automatically. State is persisted in `UserDefaults` keyed by `(limit, resets_at)` so an app restart doesn't re-fire alerts you've already seen.

## Requirements

- macOS 15 (Sonoma) or later
- Xcode 16+ (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the project (`brew install xcodegen`)
- [Claude Code](https://claude.ai/code) installed locally — ClaudeBar reads `~/.claude/`

## Install

```sh
make install
```

Builds a Release copy, quits any running instance, copies the app to `/Applications/ClaudeBar.app`, and launches it. Run `make help` for other targets (`generate`, `build`, `package`, `clean`, ...).

## Updates

ClaudeBar keeps itself current. Half a minute after launch and hourly after that, it asks GitHub for this repo's latest release; if the tag is newer than the running build it downloads the `.zip`, replaces the installed bundle, and restarts itself. Nothing to click, and no window appears.

The check parks itself until the Mac has a network rather than failing on a closed lid, so a laptop that spent the hour asleep still gets its update on the next wake.

Before anything is deleted, the downloaded bundle has to be ClaudeBar, carry the version its tag promised, and pass `codesign --verify`. The swap then copies the new app into `/Applications` alongside the old one and exchanges them with two renames, so the moment where `ClaudeBar.app` doesn't exist is microseconds long rather than the length of a copy, and the old copy is kept aside until the new one is in place. Whenever the swap gives up it puts the old app back and starts it — the one outcome worth ruling out is a Mac left with no ClaudeBar at all. Because the app fetches the archive itself it never picks up a quarantine flag, so Gatekeeper has nothing to object to.

The **Status** tab carries the switch, the installed version, and a **Check now** button. With automatic updates off, a manual check reports what's available and waits for you to press **Install and restart**.

Debug builds never update themselves — replacing the bundle under someone mid-edit would be a strange thing to do.

## Releasing

Merging to `main` publishes a release. [`release.yml`](.github/workflows/release.yml) reads the newest tag, adds one to its minor, runs the tests, builds and ad-hoc signs a Release copy, and publishes `v1.x.0` with `ClaudeBar-1.x.0.zip` attached. Installed copies pick it up within the hour. Nothing to tag by hand, and no version is committed to the tree — the tags are the record of what shipped.

Merges that change nothing the app ships — Markdown, `docs/`, tests, CI config — don't release, and neither does a commit whose message contains `[skip release]`. A major bump is a deliberate act: run the Release workflow from the Actions tab with a version such as `2.0.0`, and the minor carries on from there.

Local builds stamp themselves one minor above the newest release, through the same [`scripts/next-version.sh`](scripts/next-version.sh) the workflow uses. That is what stops `make install` from handing your own unmerged work to the updater to overwrite.

## First-run setup

After launching, click the menu bar icon, switch to the **Status** tab, and click **Install statusline**. ClaudeBar will:

1. Write `~/.claude/claudebar-statusline.sh`
2. Patch `~/.claude/settings.json` to set `statusLine.command` to that script
3. Detect any pre-existing custom statusline and offer to replace it (showing the old command first, so you can restore later)

Open Claude Code and run any prompt — the **Usage** tab will populate within a second.

## How the statusline relay works

Claude Code receives rate-limit utilization in the response headers of every API call but **does not persist it to disk on its own**. The only documented "free" path that exposes the numbers is its [statusline contract](https://docs.claude.com/en/docs/claude-code/statusline): on every prompt, Claude Code pipes a JSON payload to the configured statusline command, runs the command, and renders whatever it prints back as the in-terminal status string.

That payload includes a `rate_limits` field:

```json
{
  "rate_limits": {
    "five_hour": { "used_percentage": 76, "resets_at": 1777250400 },
    "seven_day": { "used_percentage": 42, "resets_at": 1777730400 }
  }
}
```

ClaudeBar's relay is a small `sh` + `python3` script that:

1. Reads the JSON from stdin
2. Atomically writes the `rate_limits` object to `~/.claude/rate-limits.json`
3. Echoes a short status line (`5h:76% 7d:42%`) back to Claude Code so you also see the percentages in your terminal prompt

ClaudeBar watches `rate-limits.json` with a `DispatchSource` vnode source and refreshes the popover within milliseconds. No keys, no API calls, no recurring cost.

> **Note:** The statusline payload carries `five_hour`, `seven_day`, and — only for sessions behind a Claude apps gateway with a spend cap — `spend_limit`. Per-model weekly windows (`seven_day_sonnet`, `seven_day_opus`) are tracked internally by Claude Code but not exposed through the statusline contract, so ClaudeBar deliberately does not show them — better to omit a number than to show a stale or guessed one. A row appears only for a window that actually arrives.

The relay is versioned. Claude Code has changed the payload before — it used to send `utilization` as a fraction where it now sends `used_percentage` — so ClaudeBar rewrites a relay left behind by an older version of itself the next time you open the popover. Nothing to reinstall.

## Data sources

ClaudeBar reads `~/.claude` — or `$CLAUDE_CONFIG_DIR`, if you point Claude Code somewhere else.

| File | Tab | Notes |
|---|---|---|
| `~/.claude/stats-cache.json` | Stats, Models | Lifetime totals, daily activity, per-model usage — up to the day it was last computed. |
| `~/.claude/projects/**/*.jsonl` | Header, Stats, Models | Live scan of the session logs, covering every day the cache does not. This is what makes the numbers move. |
| `~/.claude/rate-limits.json` | Usage | Written by the statusline relay (see above). |
| `~/.claude/sessions/*.json` | Status | Running sessions: pid, version, and what each one is doing. |

One file is ClaudeBar's own: `~/Library/Application Support/ClaudeBar/daily-activity.json`, a day-by-day record of what the scan has seen. See below for why it has to exist.

### Why the live scan carries the weight

`stats-cache.json` is the cache behind Claude Code's own `/usage` screen, and it is **only recomputed when you open that screen** — and even then it stops at yesterday, because the dialog recomputes today from the transcripts. A machine whose owner never runs `/usage` has a stats cache frozen on the day they last did.

So ClaudeBar treats it as history, not as a feed: the cache covers everything up to its `lastComputedDate`, and the scanner counts everything after it, straight from the session logs. Days, sessions, messages, tool calls and per-model tokens are all counted the way Claude Code counts them, so the two halves add up. The scan is incremental — an append-only log is resumed from the byte offset the last scan stopped at — and costs milliseconds once warm.

Two consequences worth knowing:

- **Tokens mean input + output.** Cache reads and writes are two orders of magnitude larger and would turn every figure into a measure of context size, so they are counted separately and shown per model in the Models tab.
- **Claude Code prunes old transcripts** (`cleanupPeriodDays`, 30 days by default). Whatever the stats cache absorbed survives as lifetime totals; per-day figures survive only in ClaudeBar's own record (below).

### Why ClaudeBar keeps a day-by-day record of its own

The stats cache has a per-day token figure, `dailyModelTokens`, and ClaudeBar deliberately ignores it. It counts cache reads and writes alongside input and output:

| Day | `dailyModelTokens` | input + output |
|---|---|---|
| 2026-09-02 | 33,320,754 | 326,341 |
| 2026-09-13 | 4,704,474 | 120,810 |

Roughly a hundred times the number shown everywhere else in the app, so a day taken from the cache set beside a day taken from the live scan is not a comparison — it is a fake crash every time the week straddles the cache's last computed day.

So per-day tokens come only from the transcripts. Which leaves the other problem: Claude Code throws those away after thirty days, while the heatmap reaches back some twenty weeks and a month-on-month comparison further still. ClaudeBar therefore writes down what it sees, in `daily-activity.json`, and a day stays readable long after its transcripts are gone.

The three sources — the live scan, ClaudeBar's record, and the cache — are partial views of the same days rather than slices of different ones, so they are merged by taking the largest figure for each field rather than by adding them up. A day's numbers only grow as more of it is recorded, so a day half pruned scans low and cannot overwrite what was seen while it was whole.

Until two periods have both been recorded, the card says so rather than guessing: a span containing a day that did work but has no figure left shows no arrow at all.

## Development

```sh
xcodegen generate
open ClaudeBar.xcodeproj
```

Build, run, and test from Xcode (`Cmd+R`, `Cmd+U`), or from the CLI:

```sh
xcodebuild -project ClaudeBar.xcodeproj -scheme ClaudeBar -configuration Debug test
```

### Layout

- `ClaudeBar/ClaudeBarApp.swift` — app entry, `MenuBarExtra` wiring
- `ClaudeBar/Views/` — popover, header, tab bar, four tab views, reusable components
- `ClaudeBar/Services/` — file readers (`StatsCache`, `RateLimits`, `Sessions`), `ClaudeFileWatcher`, `StatuslineInstaller`, `LoginItem`, `ThresholdTracker`, `NotificationCoordinator`, `LiveStats`, `ModelNames`, `Updater`
- `ClaudeBar/DesignSystem/` — `Theme`, `ViewModifiers`

## License

MIT — see [LICENSE](LICENSE) if present, otherwise the repo defaults apply.
