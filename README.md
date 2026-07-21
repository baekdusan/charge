# ⚡ Charge

> AI 코딩 툴의 토큰 사용량과 비용을 iPhone에서 — 세션 한도, 주간 한도, 오늘 쓴 돈까지 한눈에.

Claude Code, Codex 같은 AI 코딩 툴을 쓰다 보면 "5시간 창이 얼마나 남았지?", "이번 주 한도 괜찮나?", "오늘 얼마 썼지?"가 늘 궁금해집니다. macOS에는 [CodexBar](https://github.com/steipete/CodexBar) 같은 훌륭한 메뉴바 앱이 있지만, **자리를 떠나 있거나 Windows를 쓰는 사람**은 볼 방법이 마땅치 않죠.

Charge는 데스크톱의 사용량 데이터를 가벼운 수집기로 모아 **iPhone 앱과 위젯**으로 보여줍니다.

이름은 배터리 **충전(charge)**과 요금 **청구(charge)**의 이중 의미입니다. 세션 한도는 배터리처럼 닳고, 비용은 청구서처럼 쌓이니까요.

## 기능

- **프로바이더별 레이트리밋 게이지** — Claude(세션 5h / 주간 / 모델별 주간), Codex(세션 / 주간), 리셋 카운트다운, 창 경과 시간 마커
- **플랜 배지 & 계정 구분** — 구독 플랜(Max 20x, Education 등) 자동 감지, 머신마다 다른 계정을 쓰면 계정별 카드로 분리 + 머신 이름 표시
- **PC 연결 상태** — 수집기가 살아 있는지, 어느 머신이 언제 마지막으로 보고했는지 상단에 표시
- **페이스 예측** — 현재 소진 속도로 리셋 전에 한도에 도달할지 미리 경고 ("⚡ 이 속도면 4h 후 소진")
- **비용 대시보드** — 오늘 / 7일 / 30일 비용·토큰, 일별 차트, 모델별 비용 순위
- **세그먼트 필터** — 전체 / Claude / Codex 를 나눠서 보기
- **현재 5시간 블록** — 실시간 비용, 시간당 소진율($/h), 창 종료 시점 예상 총액
- **프로바이더 상태 배지** — Anthropic / OpenAI 상태 페이지 인시던트 표시
- **스트릭 잔디** — GitHub 잔디 스타일의 최근 70일 히트맵 (그날 쓴 비용만큼 진해짐) + 연속 사용일 🔥
- **홈 화면 위젯** — 프로바이더별 게이지 (스몰: 적층 / 미디엄: 2열, 프로바이더 선택 가능)
- **잠금화면 위젯 5종** — 링 게이지 / 큰 숫자 / 막대(사용량+시간 마커) / 요약 / 인라인, 위젯별 프로바이더 선택
- **온보딩 & 설정** — Apple 로그인 후 터미널 명령 한 줄이면 연결 완료, 프로바이더 표시 켜고 끄기, 게이지 임계값 조정
- **다크 테마** — 앱 아이콘과 통일된 네이비 그라데이션

## 아키텍처

```
[iPhone] Apple 로그인 → 페어링 코드 발급 → RLS로 본인 행만 조회
[데스크톱] 수집기 (Node.js, 5분 간격 스케줄)
    ├─ ccusage — 로컬 세션 로그에서 일별 비용·토큰 집계
    ├─ Claude OAuth usage API — 세션/주간 한도 % + 플랜 (로컬 자격증명 재사용)
    ├─ ~/.codex — Codex 레이트리밋·플랜 스냅샷
    └─ 디바이스 토큰으로 charge_upload RPC 호출
[Supabase] Postgres + Auth — 사용자별 격리(RLS), 디바이스 토큰은 해시만 저장
```

앱은 로그인한 본인 데이터만 읽을 수 있고, 수집기는 페어링으로 발급받은 디바이스 토큰으로 본인 행에만 씁니다.

## 사용자 설치 (2분)

1. iPhone에 Charge 설치 → **Apple로 로그인**
2. 앱이 보여주는 명령을 컴퓨터 터미널에 붙여넣기:
   ```bash
   npx charge-collector <페어링코드>
   ```
3. 끝 — 페어링, 첫 수집, 5분 간격 자동 수집 등록까지 한 번에 됩니다.

요구사항은 [Node.js](https://nodejs.org) 18+뿐입니다 (macOS/Windows). Claude 자격증명은 macOS에선 Keychain, Windows에선 `~/.claude/.credentials.json`에서 자동으로 읽습니다. (선택) `npm i -g ccusage`를 해두면 수집이 빨라집니다.

## 개발 빌드

```bash
cd ios
xcodegen generate    # Xcode 15+ / iOS 17+ / XcodeGen 필요
open Charge.xcodeproj
```

백엔드 주소는 `ios/Shared/CloudConfig.txt`(1행 URL, 2행 anon key)와 `collector/cloud.json`에 있습니다 (gitignore 대상 — 자기 Supabase 프로젝트에 `supabase/schema-v2.sql`을 실행하고 채우면 됩니다).

> App Group(`group.com.dusan.charge`)을 사용하므로 포크해서 쓸 때는 번들 ID와 그룹 ID를 자신의 팀에 맞게 `project.yml`에서 바꿔주세요.

## 운영

| 작업 | 명령 |
|------|------|
| 수동 수집 1회 | `npx charge-collector run` |
| 수집기 로그 (macOS) | `tail -f ~/Library/Logs/charge-collector.log` |
| 수집기 로그 (Windows) | `%USERPROFILE%\charge-collector.log` |
| 수집기 해제 (macOS) | `launchctl unload ~/Library/LaunchAgents/com.charge.collector.plist` |
| 수집기 해제 (Windows) | `Unregister-ScheduledTask -TaskName ChargeCollector` |
| 페어링 해제 | `npx charge-collector unpair` |

## 여러 컴퓨터에서 쓰기

앱 설정 → "다른 컴퓨터 페어링"으로 코드를 새로 발급받아 각 머신에서 `npx charge-collector <코드>`를 실행하면 됩니다.

일별 비용/토큰은 **머신별 행으로 따로 저장되고 앱이 날짜별로 합산**해 보여줍니다. 맥북에서 $40, 맥미니에서 $10을 썼다면 앱에는 $50으로 표시되고, 어느 한 대가 꺼져 있어도 다른 머신의 기록은 유지됩니다. 레이트리밋·플랜은 계정 단위 값이라 어떤 머신이 올려도 항상 최신입니다.

## 로드맵

- [x] **Windows 수집기** — 자격증명 파일 폴백 + `install.ps1`(Task Scheduler). 실기 검증은 아직 (Windows 머신에서 `--dry-run`부터 확인 권장)
- [ ] **리셋 로컬 알림** — 리셋 시각은 미리 알 수 있으므로 서버 없이 iOS 로컬 알림 예약으로 "한도가 리셋됐어요" 알림 가능
- [ ] **폰 단독 모드** — 앱에서 직접 로그인해 레이트리밋 %를 조회 (데스크톱 수집기 없이 동작)
- [x] 멀티유저 백엔드 — Apple 로그인 + 페어링 코드 + RLS 격리 (`supabase/schema-v2.sql`)
- [x] 멀티 머신 수집 병합 — 디바이스별 행 저장 + 앱에서 날짜별 합산
- [ ] 임계값 푸시 알림
- [ ] 프로바이더 추가 (Gemini, Copilot, OpenRouter, …)

## 크레딧

- [ccusage](https://github.com/ryoppippi/ccusage) — 로컬 로그 비용 집계
- [CodexBar](https://github.com/steipete/CodexBar), [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) — 기능 설계에 큰 영감을 받았습니다

## 라이선스

[MIT](LICENSE)
