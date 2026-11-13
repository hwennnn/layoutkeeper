#!/bin/bash
set -uo pipefail
LABEL=dev.layoutkeeper.agent
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" /usr/local/bin/layoutkeeper "$HOME/.local/bin/layoutkeeper"; rm -rf "$HOME/.local/libexec/layoutkeeper"
rm -rf "$HOME/Applications/LayoutKeeper.app"
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1
echo "Removed daemon, app and CLI. Saved layouts kept in ~/Library/Application Support/LayoutKeeper (delete with --purge)."
[ "${1:-}" = "--purge" ] && rm -rf "$HOME/Library/Application Support/LayoutKeeper" && echo "Purged saved layouts."
exit 0
