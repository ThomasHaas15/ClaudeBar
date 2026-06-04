# ClaudeBar

[![CI](https://github.com/ThomasHaas15/ClaudeBar/actions/workflows/ci.yml/badge.svg)](https://github.com/ThomasHaas15/ClaudeBar/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2015-blue.svg)](https://developer.apple.com)

A macOS menu bar app that surfaces **Claude Code** usage at a glance — session and weekly rate limits, daily and lifetime token stats, per-model breakdown, and active sessions. Posts a system notification when any limit crosses 80% or 100%. Local data only; no network calls, no credentials.

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
- **Stats** — total sessions, total tokens, current and longest streak, longest session duration, 30-day activity heatmap
- **Models** — per-model token share with input/output breakdown and a favorite-model summary
- **Status** — Claude Code version, session activity ("2 working, 2 idle"), active session count, launch-at-login toggle, statusline installer
- **Threshold notifications** — fires at 80% and 100% of session and weekly limits, once per reset window
- **Visual indicator in the menu bar** — sparkle glyph picks up a colored dot when any limit goes warning (yellow ≥ 80%) or critical (red = 100%)
- **No credentials, no network** — reads only local files under `~/.claude/`
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

> **Note:** The statusline payload only contains `five_hour` and `seven_day`. Per-model breakdowns (`seven_day_sonnet`, `seven_day_opus`) are tracked internally by Claude Code but not exposed through the statusline contract, so ClaudeBar deliberately does not show them — better to omit a number than to show a stale or guessed one.

## Data sources

| File | Tab | Notes |
|---|---|---|
| `~/.claude/stats-cache.json` | Stats, Models | Totals, daily activity, per-model usage. Recomputed by Claude Code in the background. |
| `~/.claude/projects/*/*.jsonl` | Stats header | Live overlay scan of session logs newer than the cache, so today's tokens appear before Claude Code re-aggregates. |
| `~/.claude/rate-limits.json` | Usage | Written by the statusline relay (see above). |
| `~/.claude/sessions/*.json` | Status | Active sessions: pid, version, busy/idle. |

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
- `ClaudeBar/Services/` — file readers (`StatsCache`, `RateLimits`, `Sessions`), `ClaudeFileWatcher`, `StatuslineInstaller`, `LoginItem`, `ThresholdTracker`, `NotificationCoordinator`, `LiveStats`
- `ClaudeBar/DesignSystem/` — `Theme`, `ViewModifiers`

## License

MIT — see [LICENSE](LICENSE) if present, otherwise the repo defaults apply.
