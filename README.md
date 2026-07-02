# Git Push Monitor

A small macOS desktop monitor and global Git `pre-push` guard for daily Git push upload traffic.

It is designed for one computer. It can track pushes made from this machine across repositories that use the global Git hooks path. It cannot see pushes made from other computers, GitHub web uploads, CI, or API uploads.

## Features

- Shows a small floating desktop window with today's Git push usage.
- Adds a settings button in the desktop window for changing the daily limit.
- Adds a details button in the desktop window for today's uploads by project.
- Enforces a daily upload limit before `git push`.
- Tracks all repositories on this computer that use the global Git hooks path.
- Lets the user change the daily limit without editing code.
- Defaults to `0.99 MB` per day.

## Install

```sh
./scripts/install.sh
```

The installer writes:

- Config: `~/.config/git-push-monitor/config`
- Hook: `~/.config/git/hooks/pre-push`
- Desktop monitor: `~/.local/bin/GitPushTrafficMonitor.swift`
- LaunchAgent: `~/Library/LaunchAgents/com.emoow.git-push-monitor.plist`
- Usage history: `~/.local/state/git-push-monitor/YYYY-MM-DD.bytes`
- Project usage history: `~/.local/state/git-push-monitor/YYYY-MM-DD.projects.tsv`

It also sets:

```sh
git config --global core.hooksPath ~/.config/git/hooks
```

## Change The Daily Limit

Use the settings button in the desktop monitor window to update:

- Daily limit MB
- Warn ratio

The new values are saved to:

```sh
~/.config/git-push-monitor/config
```

You can also edit that file directly:

```sh
~/.config/git-push-monitor/config
```

Example:

```sh
DAILY_LIMIT_MB=0.99
WARN_RATIO=0.80
```

Change `DAILY_LIMIT_MB` to any positive number:

```sh
DAILY_LIMIT_MB=5
```

The hook and desktop monitor both read this file.

## View Project Uploads

Click the details button in the desktop monitor window to open a small dropdown of today's uploads by project.

The project list is recorded by the `pre-push` hook. Pushes made before installing this version may only have a total counter, not per-project detail.

## Uninstall

```sh
./scripts/uninstall.sh
```

The uninstall script removes the hook, monitor, and LaunchAgent. It keeps the config and usage history.

## Notes

- The hook estimates upload size by generating a Git pack for the refs being pushed.
- The usage counter increments before the network push finishes. If the network fails, the estimate can still be counted.
- A repository with its own local `core.hooksPath` can override the global hook.
- You can intentionally bypass the guard with `git push --no-verify`.
