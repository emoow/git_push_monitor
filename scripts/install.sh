#!/bin/sh

set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
config_dir="$HOME/.config/git-push-monitor"
config_file="$config_dir/config"
hooks_dir="$HOME/.config/git/hooks"
bin_dir="$HOME/.local/bin"
launch_agent_dir="$HOME/Library/LaunchAgents"
launch_agent_file="$launch_agent_dir/com.emoow.git-push-monitor.plist"

mkdir -p "$config_dir" "$hooks_dir" "$bin_dir" "$launch_agent_dir"

if [ ! -f "$config_file" ]; then
  cp "$repo_dir/config/config.example" "$config_file"
fi

cp "$repo_dir/hooks/pre-push" "$hooks_dir/pre-push"
chmod +x "$hooks_dir/pre-push"
git config --global core.hooksPath "$hooks_dir"

cp "$repo_dir/app/GitPushTrafficMonitor.swift" "$bin_dir/GitPushTrafficMonitor.swift"
chmod +x "$bin_dir/GitPushTrafficMonitor.swift"

cat > "$launch_agent_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.emoow.git-push-monitor</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>swift</string>
        <string>$bin_dir/GitPushTrafficMonitor.swift</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$bin_dir</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <false/>

    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
    </array>

    <key>StandardOutPath</key>
    <string>/tmp/git-push-monitor.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/git-push-monitor.log</string>
</dict>
</plist>
EOF

uid="$(id -u)"
launchctl bootout "gui/$uid" "$launch_agent_file" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$launch_agent_file"
launchctl kickstart -k "gui/$uid/com.emoow.git-push-monitor"

cat <<EOF
Git Push Monitor installed.

Config:
  $config_file

Change DAILY_LIMIT_MB in that file to adjust the daily limit.
EOF
