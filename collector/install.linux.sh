#!/bin/bash
# Linux/WSL에 수집기를 등록한다 (5분 간격).
# systemd 사용자 세션이 있으면 타이머로 등록하고, 없으면(WSL에서 흔하다) cron 한 줄을 안내한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${CHARGE_HOME:-$HOME/.charge}"
LOG="$LOG_DIR/collector.log"

NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  echo "Node.js를 찾을 수 없습니다."
  echo "배포판 패키지나 https://nodejs.org 로 설치한 뒤 다시 실행해주세요."
  exit 1
fi

mkdir -p "$LOG_DIR"

# systemctl 이 있어도 사용자 세션이 안 뜬 경우가 많다 (WSL, 컨테이너, SSH) — 실제로 물어본다
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"

  cat > "$UNIT_DIR/charge-connect.service" <<EOF
[Unit]
Description=Charge usage collector

[Service]
Type=oneshot
ExecStart=$NODE $SCRIPT_DIR/collect.js --log $LOG
EOF

  cat > "$UNIT_DIR/charge-connect.timer" <<EOF
[Unit]
Description=Charge usage collector (5분 간격)

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now charge-connect.timer
  echo "등록 완료: charge-connect.timer (5분 간격). 로그: $LOG"
  echo "해제하려면: systemctl --user disable --now charge-connect.timer"
  exit 0
fi

# 여기까지 왔으면 자동 등록은 못 한다. 종료 코드 3으로 알려 cli.js가 안내를 덧붙이게 한다.
echo "systemd 사용자 세션을 찾지 못했습니다 (WSL에서는 흔한 일입니다)."
echo "아래 한 줄을 crontab에 넣으면 5분마다 수집합니다:"
echo
echo "  */5 * * * * $NODE $SCRIPT_DIR/collect.js --log $LOG"
echo
echo "등록: crontab -e   (cron이 안 돌고 있으면: sudo service cron start)"
exit 3
