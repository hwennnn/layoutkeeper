#!/bin/bash
# Build layoutkeeper, install the real binary under ~/.local/libexec, the CLI on PATH,
# a never-rebuilt launcher app (~/Applications/LayoutKeeper.app) that holds the Accessibility grant,
# and a LaunchAgent that runs it.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=dev.layoutkeeper.agent
APP="$HOME/Applications/LayoutKeeper.app"
STUB="$APP/Contents/MacOS/LayoutKeeper"
LIBEXEC="$HOME/.local/libexec/layoutkeeper"
BIN="$LIBEXEC/layoutkeeper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/LayoutKeeper.log"
RESET=0; [ "${1:-}" = "--reset-tcc" ] && RESET=1

echo "▸ building"
swift build -c release 2>&1 | grep -E "error|warning: |Build complete" || true
[ -x .build/release/layoutkeeper ] && [ -x .build/release/LayoutKeeperAgent ] || { echo "build failed"; exit 1; }

echo "▸ installing $BIN"
mkdir -p "$LIBEXEC" "$HOME/Library/LaunchAgents" "$HOME/.local/bin"
install -m 755 .build/release/layoutkeeper "$BIN.new" && mv -f "$BIN.new" "$BIN"
ln -sf "$BIN" "$HOME/.local/bin/layoutkeeper"
[ -w /usr/local/bin ] && ln -sf "$BIN" /usr/local/bin/layoutkeeper || true

# The launcher app is only (re)written when missing or explicitly reset: its signature is what macOS
# remembers in the Accessibility list, so we must not touch it on ordinary rebuilds.
if [ ! -x "$STUB" ] || [ "$RESET" = 1 ]; then
  echo "▸ installing launcher $APP (needs a fresh Accessibility grant)"
  rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp .build/release/LayoutKeeperAgent "$STUB"
  [ -f assets/AppIcon.icns ] || swift scripts/make-icon.swift assets/AppIcon.icns >/dev/null
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>LayoutKeeper</string>
  <key>CFBundleDisplayName</key><string>LayoutKeeper</string>
  <key>CFBundleExecutable</key><string>LayoutKeeper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/layoutkeeper/Version.swift)</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - --identifier "$LABEL" "$APP" 2>/dev/null
  tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
  NEED_GRANT=1
else
  echo "▸ launcher unchanged (Accessibility grant preserved)"
  NEED_GRANT=0
fi

echo "▸ LaunchAgent $LABEL"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$STUB</string></array>
  <key>EnvironmentVariables</key><dict><key>LAYOUTKEEPER_BIN</key><string>$BIN</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
sleep 3

echo
"$BIN" status || true
echo
if [ "$NEED_GRANT" = 1 ] || ! "$BIN" ping 2>/dev/null | grep -q "trusted=true"; then
  cat <<MSG
──────────────────────────────────────────────────────────────
ONE MANUAL STEP: enable “LayoutKeeper” in
  System Settings ▸ Privacy & Security ▸ Accessibility
(it is already in the list; flip the toggle and the daemon picks it up within 15s)
──────────────────────────────────────────────────────────────
MSG
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
fi
