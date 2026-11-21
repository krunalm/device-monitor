#!/usr/bin/env bash
if [ "$(uname -s)" = "Darwin" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.devicemonitor.agent.plist"
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null
  rm -f "$PLIST"; rm -rf "$HOME/Library/Application Support/DeviceMonitorAgent"
  echo "Device Monitor agent removed."; exit 0
fi
DIR="$HOME/.local/share/device-monitor"
if [ -n "$TERMUX_VERSION" ] || [ "$(uname -o 2>/dev/null)" = "Android" ]; then
  OLD="$(cat "$DIR/agent.pid" 2>/dev/null)"
  case "$OLD" in ''|*[!0-9]*) ;; *) grep -q agent-android.sh "/proc/$OLD/cmdline" 2>/dev/null && kill "$OLD" 2>/dev/null ;; esac
  grep -q '^KEEP_AWAKE=1' "$DIR/settings" 2>/dev/null && termux-wake-unlock 2>/dev/null
  rm -f "$HOME/.termux/boot/device-monitor"; rm -rf "$DIR"
  echo "Device Monitor agent removed."; exit 0
fi
systemctl --user disable --now device-monitor.service 2>/dev/null
rm -f "$HOME/.config/systemd/user/device-monitor.service"
(crontab -l 2>/dev/null | grep -v device-monitor) | crontab - 2>/dev/null
pkill -f "$DIR/agent.sh" 2>/dev/null
rm -rf "$DIR"
echo "Device Monitor agent removed."
