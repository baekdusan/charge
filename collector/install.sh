#!/bin/bash
# launchd에 수집기를 등록한다 (5분 간격).
set -euo pipefail

LABEL="com.charge.connect"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/charge-connect.log"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# 예전 이름(charge-collector)으로 등록된 잔재가 있으면 정리
OLD_PLIST="$HOME/Library/LaunchAgents/com.charge.collector.plist"
if [ -f "$OLD_PLIST" ]; then
  launchctl unload "$OLD_PLIST" 2>/dev/null || true
  rm -f "$OLD_PLIST"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>exec node "$SCRIPT_DIR/collect.js"</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "등록 완료: $LABEL (5분 간격). 로그: $LOG"
