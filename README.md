# ⚡ Charge

> AI 코딩 툴의 토큰 사용량과 비용을 iPhone에서 — 세션 한도, 주간 한도, 오늘 쓴 돈까지 한눈에.

Claude Code, Codex 같은 AI 코딩 툴을 쓰다 보면 "5시간 창이 얼마나 남았지?", "이번 주 한도 괜찮나?", "오늘 얼마 썼지?"가 늘 궁금해집니다. macOS에는 [CodexBar](https://github.com/steipete/CodexBar) 같은 훌륭한 메뉴바 앱이 있지만, **자리를 떠나 있거나 Windows를 쓰는 사람**은 볼 방법이 마땅치 않죠.

Charge는 데스크톱의 사용량 데이터를 가벼운 수집기로 모아 **iPhone 앱과 위젯**으로 보여줍니다.

이름은 배터리 **충전(charge)**과 요금 **청구(charge)**의 이중 의미입니다. 세션 한도는 배터리처럼 닳고, 비용은 청구서처럼 쌓이니까요.

## 기능

- **프로바이더별 레이트리밋 게이지** — Claude(세션 5h / 주간 / 모델별 주간), Codex(세션 / 주간), 리셋 카운트다운
- **페이스 예측** — 현재 소진 속도로 리셋 전에 한도에 도달할지 미리 경고 ("⚡ 이 속도면 4h 후 소진")
- **비용 대시보드** — 오늘 / 7일 / 30일 비용·토큰, 일별 차트, 모델별 비용 순위
- **세그먼트 필터** — 전체 / Claude / Codex 를 나눠서 보기
- **현재 5시간 블록** — 실시간 비용, 시간당 소진율($/h), 창 종료 시점 예상 총액
- **프로바이더 상태 배지** — Anthropic / OpenAI 상태 페이지 인시던트 표시
- **홈 화면 위젯** — 프로바이더별 게이지 (스몰: 적층 / 미디엄: 2열, 프로바이더 선택 가능)
- **잠금화면 위젯** — 1×1 고리형 게이지, 1×2 바형 게이지
- **다크 테마** — 앱 아이콘과 통일된 네이비 그라데이션

## 아키텍처

```
[데스크톱] 수집기 (Node.js, 5분 간격 스케줄)
    ├─ ccusage — 로컬 세션 로그에서 일별 비용·토큰 집계
    ├─ Claude OAuth usage API — 세션/주간 한도 % (로컬 자격증명 재사용)
    ├─ ~/.codex 세션 로그 — Codex 레이트리밋 스냅샷
    └─ 변경이 있을 때만 시크릿 Gist에 JSON 업로드
[GitHub Gist] charge.json — 데이터 저장소 (서버 불필요, 무료)
[iPhone] SwiftUI 앱 + WidgetKit 위젯 — raw URL 읽기 전용 조회
```

서버가 없습니다. 데이터는 본인의 시크릿 Gist에만 저장되고, 인증은 이미 로그인된 `gh` CLI 세션을 재사용합니다.

## 요구사항

- macOS (Windows 수집기는 로드맵 참고)
- [Node.js](https://nodejs.org) 18+
- [GitHub CLI](https://cli.github.com) — `gh auth login` 완료 상태 (gist 권한 포함)
- Xcode 15+ / iOS 17+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- (선택) [ccusage](https://github.com/ryoppippi/ccusage) 전역 설치 시 수집 속도 향상: `npm i -g ccusage`

## 설치

### 1. 데이터 저장용 Gist 생성

```bash
echo '{"generated_at":null,"daily":[],"live":null,"providers":[]}' > charge.json
gh gist create charge.json --desc "Charge usage data"
# 출력된 URL의 마지막 부분이 GIST_ID
```

### 2. 수집기 설정

```bash
cd collector
cp .env.example .env        # GIST_ID 입력
node collect.js --dry-run   # 데이터 파싱 확인
node collect.js             # 첫 업로드
./install.sh                # launchd 등록 (5분 간격)
```

### 3. iOS 앱 빌드

```bash
cp ios/Secrets.example.swift ios/Shared/Secrets.swift
# Secrets.swift 에 자신의 Gist raw URL 입력

cd ios
xcodegen generate
open Charge.xcodeproj
```

Xcode에서 `Charge`, `ChargeWidget` 두 타깃의 Signing 팀을 선택하고 기기에 Run 하세요.

## 운영

| 작업 | 명령 |
|------|------|
| 수동 수집 | `node collector/collect.js` |
| 수집기 로그 | `tail -f ~/Library/Logs/charge-collector.log` |
| 수집기 해제 | `launchctl unload ~/Library/LaunchAgents/com.charge.collector.plist` |

## 로드맵

- [ ] **Windows 수집기** — 수집기가 이미 Node라 포팅 부담이 적습니다 (자격증명 파일 폴백 + Task Scheduler). 이 프로젝트의 원래 동기가 "메뉴바 앱이 없는 Windows 사용자도 폰으로 사용량을 보게 하자"입니다
- [ ] **폰 단독 모드** — 앱에서 직접 로그인해 레이트리밋 %를 조회 (데스크톱 수집기 없이 동작)
- [ ] 임계값 푸시 알림
- [ ] 프로바이더 추가 (Gemini, Copilot, OpenRouter, …)
- [ ] 멀티유저 백엔드 (Supabase)

## 크레딧

- [ccusage](https://github.com/ryoppippi/ccusage) — 로컬 로그 비용 집계
- [CodexBar](https://github.com/steipete/CodexBar), [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) — 기능 설계에 큰 영감을 받았습니다

## 라이선스

[MIT](LICENSE)
