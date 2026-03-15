<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Claude Island — Extended Fork</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
    <br />
    This is an extended fork of <a href="https://github.com/farouqaldori/claude-island">farouqaldori/claude-island</a> with notch wings, token stats, and fullscreen detection.
  </p>
</div>

## What this fork adds

### Notch Wings

Persistent info panels on each side of the notch, showing live data at a glance:

- **Rate Limits** — Current API rate limit status
- **Tokens Today / All Time** — Token consumption from Claude Code JSONL logs, including Desktop agent sessions and subagents
- **Last Day** — Previous day's usage summary

Wings are fully customizable:
- Drag-and-drop to reorder or move elements between left and right sides
- Per-element toggle to show/hide individual wings
- Clickable — expand into detail panels with hover tooltips

### Token Usage Heatmap

Click a wing to reveal a detail panel with:
- 7-day history table with per-day token counts
- Heatmap visualization with a heated-metal color scale (black → red → orange → yellow → white)
- Hover tooltips with record highlights

### Fullscreen Detection

Wings automatically hide when a terminal is in fullscreen:
- Native macOS fullscreen (Space type detection via private CGS API)
- **Non-native fullscreen** (e.g. Ghostty `Cmd+Enter`) — detected via `CGWindowListCopyWindowInfo` screen coverage analysis
- Works correctly on the built-in display even when a secondary monitor is active

### Other Additions

- **Global shortcut** (`Cmd+Shift+H`) — Toggle notch visibility from anywhere
- **Notification volume slider** — Adjust notification sounds relative to system volume
- **Session counters** — Active session count in the notch header
- **Settings tabs** — Reorganized settings with scrollable appearance tab
- **App Nap prevention** — Ensures the fullscreen detection timer is never delayed by macOS power management
- **Removed Mixpanel analytics** — No telemetry in this fork
- **Local deploy script** (`scripts/deploy-local.sh`) — Build, sign, and install in one command with proper entitlement preservation

## Features (from upstream)

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Hooks install automatically on first launch

## Requirements

- macOS 15.6+
- MacBook with a notch (built-in display)
- Claude Code CLI

## Install

Build from source:

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

Or use the local deploy script to build and install to `/Applications`:

```bash
./scripts/deploy-local.sh
```

## How It Works

Claude Island installs hooks into `~/.claude/hooks/` that communicate session state via a Unix socket. The app listens for events and displays them in the notch overlay.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons — no need to switch to the terminal.

### Screen Recording Permission

The non-native fullscreen detection requires **Screen Recording** permission (System Settings > Privacy & Security > Screen Recording). The app uses `CGWindowListCopyWindowInfo` to detect terminal windows covering the screen — this API needs Screen Recording access to read other applications' window names and bounds.

If you re-deploy the app via `deploy-local.sh`, macOS may invalidate the previous authorization. Toggle the permission off and on again in System Settings, then relaunch the app.

## License

Apache 2.0
