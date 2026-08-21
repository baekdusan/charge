#!/bin/sh
# Xcode Cloud가 저장소를 clone한 직후 실행한다.
# 저장소엔 .xcodeproj(xcodegen 생성물)와 CloudConfig.txt(백엔드 주소)가 없으므로 여기서 복원한다.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH/ios"

# 1) 백엔드 설정 — 워크플로 환경 변수(secret)에서 복원.
#    xcodegen보다 먼저 만들어야 Shared 폴더 스캔 시 번들 리소스로 포함된다.
if [ -n "$CHARGE_CLOUD_URL" ] && [ -n "$CHARGE_CLOUD_ANON_KEY" ]; then
  printf '%s\n%s\n' "$CHARGE_CLOUD_URL" "$CHARGE_CLOUD_ANON_KEY" > Shared/CloudConfig.txt
  echo "CloudConfig.txt written"
else
  echo "warning: CHARGE_CLOUD_URL / CHARGE_CLOUD_ANON_KEY not set — building self-hosted-only (no account mode)"
fi

# 2) 프로젝트 생성
brew install xcodegen
xcodegen generate
