#!/bin/sh

set -eu

hooks_dir="$HOME/.config/git/hooks"
launch_agent_file="$HOME/Library/LaunchAgents/com.emoow.git-push-monitor.plist"
uid="$(id -u)"

launchctl bootout "gui/$uid" "$launch_agent_file" >/dev/null 2>&1 || true

rm -f "$launch_agent_file"
rm -f "$HOME/.local/bin/GitPushTrafficMonitor.swift"
rm -f "$hooks_dir/pre-push"

if [ "$(git config --global --get core.hooksPath || true)" = "$hooks_dir" ]; then
  git config --global --unset core.hooksPath || true
fi

cat <<EOF
Git Push Monitor uninstalled.

Config and usage history were kept:
  $HOME/.config/git-push-monitor/config
  ${XDG_STATE_HOME:-$HOME/.local/state}/git-push-monitor
EOF
