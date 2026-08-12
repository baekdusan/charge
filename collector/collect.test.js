// Charge collector 단위 테스트 — 실행: node --test collector/
// 순수 함수만 검증한다 (네트워크·ccusage 불필요).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const C = require("./collect");

const futureReset = "2099-01-02T03:04:05Z";

test("T01 accountHash: 결정적 12자 해시, 빈 값은 null", () => {
  assert.equal(C.accountHash(null), null);
  assert.equal(C.accountHash(""), null);
  const h = C.accountHash("user-uuid-123");
  assert.equal(h.length, 12);
  assert.equal(h, C.accountHash("user-uuid-123"));
  assert.notEqual(h, C.accountHash("user-uuid-456"));
});

test("T02 dropExpired: 리셋이 지난 창은 무효, 미래·미상은 유지", () => {
  const past = { percent: 100, resets_at: new Date(Date.now() - 60_000).toISOString() };
  const future = { percent: 50, resets_at: futureReset };
  const noReset = { percent: 10, resets_at: null };
  assert.equal(C.dropExpired(past), null);
  assert.deepEqual(C.dropExpired(future), future);
  assert.deepEqual(C.dropExpired(noReset), noReset);
  assert.equal(C.dropExpired(null), null);
});

test("T03 normalizeResetAt: 초/밀리초 epoch·ISO 문자열 처리, 무효는 null", () => {
  const sec = 1_800_000_000;
  assert.equal(C.normalizeResetAt(sec), new Date(sec * 1000).toISOString());
  assert.equal(C.normalizeResetAt(sec * 1000), new Date(sec * 1000).toISOString());
  assert.equal(C.normalizeResetAt("2026-07-21T00:00:00Z"), "2026-07-21T00:00:00.000Z");
  assert.equal(C.normalizeResetAt("garbage"), null);
  assert.equal(C.normalizeResetAt(null), null);
  assert.equal(C.normalizeResetAt(""), null);
});

test("T04 normalizeRateWindow: 퍼센트 클램프·라벨 결정·무효 입력", () => {
  const w = C.normalizeRateWindow({ usedPercent: 150, resetsAt: futureReset, windowMinutes: 300 }, "primary");
  assert.equal(w.percent, 100);
  assert.equal(w.label, "Session");
  const neg = C.normalizeRateWindow({ percent: -5, resetsAt: futureReset, windowMinutes: 10_080 }, "secondary");
  assert.equal(neg.percent, 0);
  assert.equal(neg.label, "Weekly");
  assert.equal(C.normalizeRateWindow({ resetsAt: futureReset }, "primary"), null); // 퍼센트 없음
  assert.equal(C.normalizeRateWindow(null, "primary"), null);
  // 같은 길이 창이 중복이면 슬롯 접두사로 구분
  const dup = C.normalizeRateWindow({ percent: 10, windowMinutes: 300 }, "secondary", true);
  assert.equal(dup.label, "Secondary session");
});

test("T04c normalizeRateWindow: 빈 수치는 0%가 아니라 창 없음, 후보는 '유효한' 첫 값으로", () => {
  const base = { resetsAt: futureReset, windowMinutes: 300 };
  // ?? 체인이면 "", false, []가 Number()에서 0으로 둔갑해 0% 게이지가 그대로 올라갔다
  for (const empty of ["", "   ", false, [], {}, "abc", null, undefined]) {
    const label = JSON.stringify(empty) ?? "undefined";
    assert.equal(C.normalizeRateWindow({ ...base, usedPercent: empty }, "primary"), null, `usedPercent=${label}`);
    assert.equal(C.normalizeRateWindow({ ...base, percent: empty }, "primary"), null, `percent=${label}`);
    assert.equal(C.normalizeRateWindow({ ...base, utilization: empty }, "primary"), null, `utilization=${label}`);
  }
  // 앞 후보가 유효하지 않으면 뒤 후보로 넘어간다 (??는 null/undefined만 건너뛴다)
  assert.equal(C.normalizeRateWindow({ ...base, usedPercent: "", percent: 42 }, "primary").percent, 42);
  assert.equal(C.normalizeRateWindow({ ...base, usedPercent: [], percent: false, utilization: 63 }, "primary").percent, 63);
  // 진짜 0%(정상 사용 0)는 앞 후보에서 그대로 채택돼야 한다, 0을 건너뛰면 게이지가 사라진다
  assert.equal(C.normalizeRateWindow({ ...base, usedPercent: 0, percent: 77 }, "primary").percent, 0);
  assert.equal(C.normalizeRateWindow({ ...base, usedPercent: "12.5" }, "primary").percent, 12.5);

  // 실제로 antigravity 창을 만드는 경로(CodexBar 브리지)까지 같은 규칙이 적용된다
  const holes = C.codexBarEntryToProvider({
    provider: "antigravity",
    usage: {
      primary: { usedPercent: "", resetsAt: futureReset, windowMinutes: 300 },
      secondary: { usedPercent: false, resetsAt: futureReset, windowMinutes: 10_080 },
      extraRateWindows: [{ title: "Gemini 3 Pro", usedPercent: [], resetsAt: futureReset, windowMinutes: 10_080 }],
    },
  });
  assert.equal(holes, null); // 빈 수치뿐이면 창이 하나도 없는 엔트리 = 업로드 대상 아님
  const real = C.codexBarEntryToProvider({
    provider: "antigravity",
    usage: { primary: { usedPercent: "", percent: 0, resetsAt: futureReset, windowMinutes: 300 } },
  });
  assert.equal(real.session.percent, 0);
});

test("T04b percentValue: 빈 값은 null, 진짜 0%는 0 (Number()의 0 함정)", () => {
  // Number(null), Number(""), Number(false), Number([])는 전부 0이고 finite다 , 
  // finite 검사만으로는 "수치 없음"이 0%로 둔갑해 서버의 빈 창 가드를 통과한다
  for (const empty of [null, undefined, "", "   ", false, true, [], {}, [1], "abc", NaN, Infinity]) {
    assert.equal(C.percentValue(empty), null, `${JSON.stringify(empty)}는 값이 아니다`);
  }
  // 진짜 0%(정상 사용 0)는 반드시 살아야 한다
  assert.equal(C.percentValue(0), 0);
  assert.equal(C.percentValue(0.5), 0.5);
  assert.equal(C.percentValue(97), 97);
  assert.equal(C.percentValue(-3), -3);
  // API가 숫자를 문자열로 주는 경우까지만 인정 (공백 문자열은 위에서 이미 탈락)
  assert.equal(C.percentValue("0"), 0);
  assert.equal(C.percentValue("12.5"), 12.5);
});

test("T05 durationLabel / titleCaseProvider / usefulPlan", () => {
  assert.equal(C.durationLabel(300), "Session");
  assert.equal(C.durationLabel(1440), "Daily");
  assert.equal(C.durationLabel(10_080), "Weekly");
  assert.equal(C.durationLabel(43_200), "Monthly");
  assert.equal(C.durationLabel(123), null);
  assert.equal(C.titleCaseProvider("azure-openai"), "Azure Openai");
  assert.equal(C.titleCaseProvider("kimi"), "Kimi");
  assert.equal(C.usefulPlan("api"), null); // 제네릭 값은 플랜이 아님
  assert.equal(C.usefulPlan("oauth", "Pro"), null); // 첫 텍스트 값 기준
  assert.equal(C.usefulPlan(null, "Pro"), "Pro");
});

test("T06 parseCodexBarJSON: 배열/단일 객체/진단 라인 섞임/깨진 입력", () => {
  assert.deepEqual(C.parseCodexBarJSON('[{"provider":"gemini"}]'), [{ provider: "gemini" }]);
  assert.deepEqual(C.parseCodexBarJSON('{"provider":"gemini"}'), [{ provider: "gemini" }]);
  const noisy = 'diagnostic\n[{"provider":"cursor"}]\ntrailing';
  assert.deepEqual(C.parseCodexBarJSON(noisy), [{ provider: "cursor" }]);
  assert.equal(C.parseCodexBarJSON("not json at all"), null);
  assert.equal(C.parseCodexBarJSON(""), null);
});

test("T07 codexBarEntryToProvider: 창 매핑·중복 길이 라벨·계정 비노출", () => {
  const email = "person@example.com";
  const provider = C.codexBarEntryToProvider({
    provider: "gemini",
    source: "auto",
    usage: {
      plan: "AI Pro",
      identity: { accountEmail: email },
      primary: { usedPercent: 11, resetsAt: futureReset, windowMinutes: 1440 },
      secondary: { usedPercent: 22, resetsAt: futureReset, windowMinutes: 1440 },
      tertiary: { usedPercent: 33, resetsAt: futureReset, windowMinutes: 1440 },
      extraRateWindows: [
        { title: "Gemini 2.5 Pro", usedPercent: 44, resetsAt: futureReset, windowMinutes: 10_080 },
      ],
    },
  });
  assert.equal(provider.id, "gemini");
  assert.equal(provider.name, "Gemini");
  assert.equal(provider.plan, "AI Pro");
  assert.equal(provider.account, C.accountHash(email));
  assert.match(provider.account, /^[a-f0-9]{12}$/);
  assert.equal(provider.session.label, "Primary daily");
  assert.equal(provider.weekly.label, "Secondary daily");
  assert.equal(provider.extras[0].window.label, "Tertiary daily");
  assert.equal(provider.extras[1].window.label, "Gemini 2.5 Pro");
  assert.equal(JSON.stringify(provider).includes(email), false); // 원문 이메일 미노출
  assert.equal(provider.collector_source, "codexbar");
});

test("T07b codexBarEntryToProvider: 불투명 계정 ID가 이메일보다 우선(사전 대입 방지)", () => {
  const email = "person@example.com";
  const accountId = "acct_9f3c1e77-opaque";
  const provider = C.codexBarEntryToProvider({
    provider: "gemini",
    usage: {
      identity: { accountEmail: email, accountId },
      primary: { usedPercent: 11, resetsAt: futureReset, windowMinutes: 1440 },
    },
  });
  // 이메일과 불투명 ID가 모두 있으면 해시는 이메일이 아니라 불투명 ID로 계산돼야 한다
  assert.equal(provider.account, C.accountHash(accountId));
  assert.notEqual(provider.account, C.accountHash(email));
});

test("T08 codexBarEntryToProvider 제외 규칙 + resolveMode 우선순위", () => {
  const win = { usedPercent: 1, resetsAt: futureReset, windowMinutes: 300 };
  // claude/codex는 자체 수집 우선이므로 브리지에서 제외, 에러·빈 엔트리도 제외
  assert.equal(C.codexBarEntryToProvider({ provider: "claude", usage: { primary: win } }), null);
  assert.equal(C.codexBarEntryToProvider({ provider: "codex", usage: { primary: win } }), null);
  assert.equal(C.codexBarEntryToProvider({ provider: "cursor", error: { message: "offline" } }), null);
  assert.equal(C.codexBarEntryToProvider({ provider: "gemini", usage: {} }), null);

  // resolveMode: env > config.json > null
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "charge-test-"));
  const saved = { ...process.env };
  try {
    process.env.CHARGE_HOME = tmp;
    delete process.env.CHARGE_TOKEN;
    delete process.env.CHARGE_URL;
    delete process.env.CHARGE_ANON;
    assert.equal(C.resolveMode(), null);
    fs.writeFileSync(path.join(tmp, "config.json"),
      JSON.stringify({ url: "https://x.supabase.co", anon: "a", token: "t" }));
    assert.equal(C.resolveMode().token, "t");
    process.env.CHARGE_TOKEN = "envtok";
    process.env.CHARGE_URL = "https://env.supabase.co";
    process.env.CHARGE_ANON = "envanon";
    assert.equal(C.resolveMode().token, "envtok");
  } finally {
    for (const k of ["CHARGE_HOME", "CHARGE_TOKEN", "CHARGE_URL", "CHARGE_ANON"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("T09 sanitizeCachedProvider: 캐시 복원 시 만료 창 제거, 유효 창·항목은 유지", () => {
  const past = new Date(Date.now() - 60_000).toISOString();
  const p = C.sanitizeCachedProvider({
    id: "claude",
    session: { percent: 27, resets_at: past },
    weekly: { percent: 50, resets_at: futureReset },
    extras: [
      { name: "X", window: { percent: 1, resets_at: past } },
      { name: "Y", window: { percent: 2, resets_at: futureReset } },
    ],
  });
  assert.equal(p.session, null); // 리셋 지난 창은 재업로드 금지
  assert.equal(p.weekly.percent, 50);
  assert.equal(p.extras.length, 1);
  assert.equal(p.extras[0].name, "Y");
  // 창이 하나도 안 남으면 복원 자체를 포기한다, 전부 null인 껍데기를 며칠 묵은
  // collected_at과 함께 올리면 앱엔 빈 카드가 뜨고 서버 행의 나이가 되감긴다
  const empty = C.sanitizeCachedProvider({
    id: "x",
    collected_at: "2026-08-01T00:00:00.000Z",
    session: { percent: 1, resets_at: past },
    weekly: { percent: 2, resets_at: past },
    extras: [{ name: "Z", window: { percent: 3, resets_at: past } }],
  });
  assert.equal(empty, null);
  // extras 하나만 살아 있어도 표시할 게 있으니 복원한다
  const extrasOnly = C.sanitizeCachedProvider({
    id: "x",
    session: { percent: 1, resets_at: past },
    weekly: null,
    extras: [{ name: "Z", window: { percent: 3, resets_at: futureReset } }],
  });
  assert.equal(extrasOnly.id, "x");
  assert.equal(extrasOnly.session, null);
  assert.equal(extrasOnly.extras.length, 1);
  assert.equal(C.sanitizeCachedProvider(null), null);
});

test("T09g mergeCachedProviders: 빈 카드가 되는 캐시 항목은 페이로드에서 빠진다", () => {
  const past = new Date(Date.now() - 60_000).toISOString();
  const cached = [
    // 며칠 전 관측 후 리셋이 다 지난 항목, 복원하면 빈 카드 + 되감긴 나이가 올라간다
    { id: "codex", account: "h1", collected_at: "2026-08-01T00:00:00.000Z", session: { percent: 97, resets_at: past }, weekly: null, extras: null },
    { id: "claude", account: "h2", collected_at: "2026-08-01T00:00:00.000Z", session: { percent: 12, resets_at: futureReset }, weekly: null, extras: null },
  ];
  const r = C.mergeCachedProviders({ providers: [], cached, codexBarComplete: false, statuses: {} });
  assert.deepEqual(r.providers.map((p) => p.id), ["claude"]);
  // 빠진 항목엔 상태도 지어내지 않는다 (서버의 은퇴 delete에는 20분 유예가 있다)
  assert.deepEqual(r.statuses, { claude: "stale" });
});

test("T09b sanitizeCachedProvider: collected_at 보존 (신선도 규칙의 핵심)", () => {
  const collectedAt = "2026-08-01T00:00:00.000Z";
  const p = C.sanitizeCachedProvider({
    id: "claude",
    collected_at: collectedAt,
    session: { percent: 7, resets_at: futureReset },
    weekly: null,
    extras: null,
  });
  // 캐시 폴백은 관측 시각을 갱신하면 안 된다 — 갱신하면 만료 토큰 기기가
  // 건강한 기기의 최신 업로드를 서버 신선도 규칙에서 이겨버린다
  assert.equal(p.collected_at, collectedAt);
  assert.equal(p.session.percent, 7);
});

test("T09c codexBarEntryToProvider: 성공 엔트리에 collected_at(now) 기록", () => {
  const before = Date.now();
  const p = C.codexBarEntryToProvider({
    provider: "gemini",
    usage: { primary: { usedPercent: 5, resetsAt: futureReset, windowMinutes: 300 } },
  });
  const t = new Date(p.collected_at).getTime();
  assert.ok(Number.isFinite(t));
  assert.ok(t >= before && t <= Date.now());
});

test("T09d claudeProvider: 401→auth_expired, 5xx→error, 성공→ok+collected_at, 자격증명 없음→상태 없음", async () => {
  const creds = async () => ({ claudeAiOauth: { accessToken: "tok", rateLimitTier: "default_claude_max_20x" } });
  const failWith = (code) => async () => ({ ok: false, status: code });

  const r401 = await C.claudeProvider({ fetchFn: failWith(401), loadCredentials: creds });
  assert.equal(r401.provider, null);
  assert.equal(r401.status, "auth_expired");

  const r500 = await C.claudeProvider({ fetchFn: failWith(500), loadCredentials: creds });
  assert.equal(r500.provider, null);
  assert.equal(r500.status, "error");

  const okFetch = async (url) =>
    String(url).includes("/usage")
      ? {
          ok: true,
          status: 200,
          json: async () => ({
            five_hour: { utilization: 7, resets_at: futureReset },
            seven_day: { utilization: 30, resets_at: futureReset },
            limits: [],
          }),
        }
      : { ok: true, status: 200, json: async () => ({ account: { uuid: "user-uuid" } }) };
  const before = Date.now();
  const rOk = await C.claudeProvider({ fetchFn: okFetch, loadCredentials: creds });
  assert.equal(rOk.status, "ok");
  assert.equal(rOk.provider.session.percent, 7);
  assert.equal(rOk.provider.plan, "Max 20x");
  assert.equal(rOk.provider.account, C.accountHash("user-uuid"));
  const t = new Date(rOk.provider.collected_at).getTime();
  assert.ok(t >= before && t <= Date.now());

  // 자격증명 자체가 없으면 미설치 — collect_status에 항목을 만들지 않는다
  const missing = await C.claudeProvider({
    fetchFn: failWith(200),
    loadCredentials: async () => { throw new Error("no credentials"); },
  });
  assert.equal(missing.provider, null);
  assert.equal(missing.status, null);
});

test("T09e freshestCredentials: expiresAt이 더 나중인 소스를 고른다 (SSH 세션이 파일에만 토큰을 갱신하는 경우)", () => {
  const keychain = { claudeAiOauth: { accessToken: "old", expiresAt: 1000 } };
  const file = { claudeAiOauth: { accessToken: "new", expiresAt: 2000 } };
  assert.equal(C.freshestCredentials([keychain, file]).claudeAiOauth.accessToken, "new");
  assert.equal(C.freshestCredentials([file, keychain]).claudeAiOauth.accessToken, "new");
  // 소스가 하나뿐이면 그대로, expiresAt이 없으면(구형 포맷) 앞선 소스 유지
  assert.equal(C.freshestCredentials([keychain]).claudeAiOauth.accessToken, "old");
  assert.equal(
    C.freshestCredentials([{ claudeAiOauth: { accessToken: "a" } }, { claudeAiOauth: { accessToken: "b" } }])
      .claudeAiOauth.accessToken,
    "a",
  );
});

test("T10 collectCodexBarProviders: CLI가 도는 동안 이벤트 루프가 살아있다 (Claude fetch 기아 회귀 방지)",
  { skip: process.platform === "win32" }, async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "charge-test-"));
  const cli = path.join(tmp, "fake-codexbar.sh");
  fs.writeFileSync(cli, [
    "#!/bin/sh",
    "sleep 1",
    `echo '[{"provider":"gemini","usage":{"primary":{"usedPercent":10,"resetsAt":"${futureReset}","windowMinutes":300}}}]'`,
    "",
  ].join("\n"), { mode: 0o755 });
  const saved = { ...process.env };
  try {
    process.env.CHARGE_CODEXBAR_CLI = cli;
    delete process.env.CHARGE_DISABLE_CODEXBAR;
    let timerFired = false;
    setTimeout(() => { timerFired = true; }, 200);
    const result = await C.collectCodexBarProviders();
    // 예전 동기(execFileSync) 구현에서는 CLI 1초 동안 루프가 멈춰 이 타이머가 못 돌았다
    assert.equal(timerFired, true);
    assert.equal(result.complete, true);
    assert.equal(result.providers.length, 1);
    assert.equal(result.providers[0].id, "gemini");
    assert.deepEqual(result.statuses, { gemini: "ok" });
  } finally {
    for (const k of ["CHARGE_CODEXBAR_CLI", "CHARGE_DISABLE_CODEXBAR"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("T09f claudeProvider: 깨어난 직후 네트워크 실패는 한 번 재시도해 살린다", async () => {
  const creds = async () => ({ claudeAiOauth: { accessToken: "tok" } });
  let calls = 0;
  // 1회차는 잠에서 깬 직후처럼 네트워크 계층에서 죽고, 2회차에 Wi-Fi가 붙은 상황
  const flaky = async (url) => {
    calls += 1;
    if (calls === 1) throw new TypeError("fetch failed");
    return String(url).includes("/usage")
      ? {
          ok: true,
          status: 200,
          json: async () => ({ five_hour: { utilization: 5, resets_at: futureReset }, limits: [] }),
        }
      : { ok: true, status: 200, json: async () => ({ account: { uuid: "u" } }) };
  };
  const r = await C.claudeProvider({ fetchFn: flaky, loadCredentials: creds });
  assert.equal(r.status, "ok");
  assert.equal(r.provider.session.percent, 5);

  // 상태 코드가 온 응답은 재시도하지 않는다 (401을 두 번 물어봐야 답이 같다)
  let authCalls = 0;
  const always401 = async () => { authCalls += 1; return { ok: false, status: 401 }; };
  const r401 = await C.claudeProvider({ fetchFn: always401, loadCredentials: creds });
  assert.equal(r401.status, "auth_expired");
  assert.equal(authCalls, 1);
});

test("T11 claudeProvider: 200인데 수치가 비면 0%가 아니라 창 없음", async () => {
  const creds = async () => ({ claudeAiOauth: { accessToken: "tok" } });
  const fetchFn = async (url) =>
    String(url).includes("/usage")
      ? {
          ok: true,
          status: 200,
          json: async () => ({
            five_hour: { resets_at: futureReset }, // utilization 누락
            seven_day: { utilization: 30, resets_at: futureReset },
            limits: [
              { kind: "weekly_scoped", scope: { model: { display_name: "Fable" } }, resets_at: futureReset },
              { kind: "weekly_scoped", scope: { model: { display_name: "Opus" } }, percent: 12, resets_at: futureReset },
            ],
          }),
        }
      : { ok: false, status: 500 };
  const r = await C.claudeProvider({ fetchFn, loadCredentials: creds });
  assert.equal(r.status, "ok");
  // 0%로 올리면 서버의 빈 창 가드를 통과해 다른 기기의 멀쩡한 게이지를 덮는다
  assert.equal(r.provider.session, null);
  assert.equal(r.provider.weekly.percent, 30);
  assert.equal(r.provider.extras.length, 1);
  assert.equal(r.provider.extras[0].name, "Opus");
  assert.equal(r.provider.extras[0].window.percent, 12);
});

test("T11b claudeProvider: null/\"\"/false/[]는 0%가 아니라 창 없음, 진짜 0%는 살린다", async () => {
  const creds = async () => ({ claudeAiOauth: { accessToken: "tok" } });
  // 200 응답에 utilization/percent만 갈아끼우는 usage API 스텁
  const usage = (value) => async (url) =>
    String(url).includes("/usage")
      ? {
          ok: true,
          status: 200,
          json: async () => ({
            five_hour: { utilization: value, resets_at: futureReset },
            seven_day: { utilization: value, resets_at: futureReset },
            limits: [
              { kind: "weekly_scoped", scope: { model: { display_name: "Opus" } }, percent: value, resets_at: futureReset },
            ],
          }),
        }
      : { ok: false, status: 500 };

  // Number()에 맡기면 이 값들이 전부 0%로 둔갑해 다른 기기의 멀쩡한 게이지를 0으로 덮는다.
  // 창이 하나도 안 남으면 프로바이더 자체를 안 올린다(빈 카드가 신선한 스탬프로 이기는 것 방지).
  for (const empty of [null, "", false, [], {}, "abc"]) {
    const r = await C.claudeProvider({ fetchFn: usage(empty), loadCredentials: creds });
    const label = JSON.stringify(empty);
    assert.equal(r.provider, null, `provider: ${label}`);
    assert.equal(r.status, "stale", `status: ${label}`);
  }

  // 진짜 0%(정상 사용 0)는 창이 살아 있어야 한다, 0을 버리면 게이지가 통째로 사라진다
  const zero = await C.claudeProvider({ fetchFn: usage(0), loadCredentials: creds });
  assert.equal(zero.provider.session.percent, 0);
  assert.equal(zero.provider.weekly.percent, 0);
  assert.equal(zero.provider.extras[0].window.percent, 0);
  assert.equal(zero.provider.extras[0].window.label, "Opus weekly");
  // 숫자 문자열도 값으로 인정
  const str = await C.claudeProvider({ fetchFn: usage("12.5"), loadCredentials: creds });
  assert.equal(str.provider.session.percent, 12.5);
});

test("T12 codexSnapshotWindows: rate_limits 없는 최신 파일은 건너뛰고 mtime을 그 파일 것으로", async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "charge-test-"));
  const write = (name, lines, mtimeMs) => {
    const p = path.join(tmp, name);
    fs.writeFileSync(p, lines.join("\n"));
    fs.utimesSync(p, mtimeMs / 1000, mtimeMs / 1000);
    return p;
  };
  const resetSec = Math.floor(Date.parse(futureReset) / 1000);
  try {
    const older = Date.now() - 3 * 3600_000;
    write("new.jsonl", ['{"type":"message","content":"no limits here"}'], Date.now() - 60_000);
    write("old.jsonl", [
      '{"type":"event","payload":{"rate_limits":{"primary":{"used_percent":41,"resets_at":' + resetSec + ',"window_minutes":300}}}}',
      '{"type":"event","payload":{"rate_limits":{"primary":{"used_percent":42,"resets_at":' + resetSec + ',"window_minutes":300},"secondary":{"used_percent":8,"window_minutes":10080}}}}',
    ], older);
    const snap = await C.codexSnapshotWindows(tmp);
    assert.equal(snap.session.percent, 42); // 파일 안에서는 마지막 스냅샷이 최신
    assert.equal(snap.weekly.percent, 8);
    // collected_at은 "지금"이 아니라 그 스냅샷이 들어 있던 파일의 mtime
    assert.equal(Math.abs(Date.parse(snap.collected_at) - older) < 2000, true);

    // 수치가 비면 0%가 아니라 창 없음, 둘 다 비면 스냅샷 자체가 없음
    write("blank.jsonl", ['{"rate_limits":{"primary":{"window_minutes":300},"secondary":{"used_percent":3}}}'], Date.now());
    const partial = await C.codexSnapshotWindows(tmp);
    assert.equal(partial.session, null);
    assert.equal(partial.weekly.percent, 3);
    fs.rmSync(path.join(tmp, "blank.jsonl"));
    fs.rmSync(path.join(tmp, "old.jsonl"));
    assert.equal(await C.codexSnapshotWindows(tmp), null); // 훑을 파일에 rate_limits가 없다
    assert.equal(await C.codexSnapshotWindows(path.join(tmp, "nope")), null); // Codex 미설치
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("T12b codexSnapshotWindows: 빈 수치는 창 없음, 진짜 0%는 유지, 만료 창은 여기서 걸러진다", async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "charge-test-"));
  const write = (name, line, mtimeMs) => {
    const p = path.join(tmp, name);
    fs.writeFileSync(p, line);
    fs.utimesSync(p, mtimeMs / 1000, mtimeMs / 1000);
  };
  const futureSec = Math.floor(Date.parse(futureReset) / 1000);
  const pastSec = Math.floor((Date.now() - 3600_000) / 1000);
  try {
    // null/""/false/[]는 Number()로는 전부 0%가 된다, 창 없음으로 떨어져야 한다
    for (const empty of ["null", '""', "false", "[]"]) {
      write("holes.jsonl", `{"rate_limits":{"primary":{"used_percent":${empty},"resets_at":${futureSec},"window_minutes":300}}}`, Date.now());
      const r = await C.codexSnapshotWindows(tmp);
      assert.equal(r.session, null, `used_percent=${empty}`);
      assert.equal(r.weekly, null, `used_percent=${empty}`);
    }
    // 진짜 0%는 살아야 한다
    write("holes.jsonl", `{"rate_limits":{"primary":{"used_percent":0,"resets_at":${futureSec},"window_minutes":300}}}`, Date.now());
    assert.equal((await C.codexSnapshotWindows(tmp)).session.percent, 0);

    // 리셋이 이미 지난 창만 있는 3일 묵은 스냅샷: 창은 여기서 전부 제거되고 관측 사실만 남는다.
    // 예전엔 만료 판정이 codexProvider에서야 돌아 이 스냅샷이 "창이 있다"고 통과했다.
    const old = Date.now() - 3 * 86400_000;
    fs.rmSync(path.join(tmp, "holes.jsonl"));
    write("expired.jsonl", `{"rate_limits":{"primary":{"used_percent":97,"resets_at":${pastSec},"window_minutes":300},"secondary":{"used_percent":88,"resets_at":${pastSec},"window_minutes":10080}}}`, old);
    const stale = await C.codexSnapshotWindows(tmp);
    assert.equal(stale.session, null); // 리셋 후 97% 박제 금지
    assert.equal(stale.weekly, null);
    assert.ok(Math.abs(Date.parse(stale.collected_at) - old) < 2000); // 관측 시각은 그대로 보고
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("T12d codexSnapshotWindows: 최근 20개까지 훑는다 (짧은 세션이 연달아도 스냅샷을 놓치지 않는다)", async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "charge-test-"));
  const resetSec = Math.floor(Date.parse(futureReset) / 1000);
  const snapshotLine = `{"rate_limits":{"primary":{"used_percent":57,"resets_at":${resetSec},"window_minutes":300}}}`;
  // rate_limits 없는 파일 n개를 최신순으로 깔고, 그 다음 자리에 멀쩡한 스냅샷을 둔다
  const layout = (blanks) => {
    fs.rmSync(tmp, { recursive: true, force: true });
    fs.mkdirSync(tmp, { recursive: true });
    const base = Date.now();
    for (let i = 0; i < blanks; i += 1) {
      const p = path.join(tmp, `blank-${i}.jsonl`);
      fs.writeFileSync(p, '{"type":"message","content":"no limits here"}');
      fs.utimesSync(p, (base - i * 60_000) / 1000, (base - i * 60_000) / 1000);
    }
    const p = path.join(tmp, "snapshot.jsonl");
    fs.writeFileSync(p, snapshotLine);
    fs.utimesSync(p, (base - blanks * 60_000) / 1000, (base - blanks * 60_000) / 1000);
  };
  try {
    // 한도가 5면 6번째 파일의 멀쩡한 스냅샷을 놓치고 status "error"가 된다
    layout(5);
    assert.equal((await C.codexSnapshotWindows(tmp)).session.percent, 57);
    // 20번째까지는 찾아낸다
    layout(19);
    assert.equal((await C.codexSnapshotWindows(tmp)).session.percent, 57);
    // 21번째부터는 한도 밖, 5분 주기를 지키려면 훑는 범위에 끝이 있어야 한다
    layout(20);
    assert.equal(await C.codexSnapshotWindows(tmp), null);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("T12c codexLiveWindows: 빈 수치는 0%가 아니라 창 없음, 진짜 0%는 살린다", async () => {
  const auth = { accessToken: "tok", accountId: "acct" };
  const resetSec = Math.floor(Date.parse(futureReset) / 1000);
  const respond = (primary) => async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      rate_limit: { primary_window: primary, secondary_window: null },
      plan_type: "pro",
    }),
  });
  for (const empty of [null, "", false, []]) {
    const r = await C.codexLiveWindows(auth, {
      fetchFn: respond({ used_percent: empty, reset_at: resetSec, limit_window_seconds: 18_000 }),
    });
    // 창이 하나도 안 남으면 live 자체가 없는 것, 스냅샷 폴백으로 넘긴다
    assert.equal(r, null, `used_percent=${JSON.stringify(empty)}`);
  }
  const zero = await C.codexLiveWindows(auth, {
    fetchFn: respond({ used_percent: 0, reset_at: resetSec, limit_window_seconds: 18_000 }),
  });
  assert.equal(zero.session.percent, 0);
  assert.equal(zero.session.window_minutes, 300);
  assert.equal(zero.plan, "Pro");
});

test("T13 dedupeProviders: (id, account) 한 키에 하나만 남기고 신선한 쪽을 고른다", () => {
  const at = (iso) => ({ collected_at: iso });
  const old = { id: "codex", account: "aaa", percent: 1, ...at("2026-08-01T00:00:00.000Z") };
  const fresh = { id: "codex", account: "aaa", percent: 2, ...at("2026-08-02T00:00:00.000Z") };
  assert.deepEqual(C.dedupeProviders([old, fresh]).map((p) => p.percent), [2]);
  assert.deepEqual(C.dedupeProviders([fresh, old]).map((p) => p.percent), [2]);
  // 계정이 다르면 서버에서도 다른 행, 접으면 안 된다
  assert.equal(C.dedupeProviders([fresh, { ...fresh, account: "bbb" }]).length, 2);
  // 스탬프가 없으면 나이 미상이라 스탬프가 있는 쪽에 진다 (순서와 무관)
  const unknown = { id: "codex", account: "aaa", percent: 9 };
  assert.deepEqual(C.dedupeProviders([fresh, unknown]).map((p) => p.percent), [2]);
  assert.deepEqual(C.dedupeProviders([unknown, fresh]).map((p) => p.percent), [2]);
  // 둘 다 미상이면 뒤엣것
  assert.deepEqual(C.dedupeProviders([unknown, { ...unknown, percent: 10 }]).map((p) => p.percent), [10]);
  // account null과 ''는 서버에서 같은 행 (coalesce)
  assert.equal(C.dedupeProviders([{ id: "x", account: null }, { id: "x" }]).length, 1);
});

test("T14 mergeCachedProviders: 판정 없는 캐시 복원은 stale, 기존 판정은 보존", () => {
  const fresh = { id: "claude", account: "h1", collected_at: "2026-08-02T00:00:00.000Z" };
  const cached = [
    // 살아 있는 창이 하나는 있어야 복원 대상이다 (창이 전부 만료면 sanitize가 통째로 뺀다)
    { id: "claude", account: "h1", collected_at: "2026-07-01T00:00:00.000Z", session: { percent: 4, resets_at: futureReset } },
    { id: "gemini", account: "h2", collector_source: "codexbar", session: { percent: 5, resets_at: futureReset } },
    { id: "cursor", account: "h3", collector_source: "codexbar", session: { percent: 6, resets_at: futureReset } },
  ];
  // CodexBar CLI가 통째로 죽어 statuses에 항목이 없는 상황 (complete=false)
  const r = C.mergeCachedProviders({
    providers: [fresh],
    cached,
    codexBarComplete: false,
    statuses: { claude: "ok", cursor: "auth_expired" },
  });
  assert.deepEqual(r.providers.map((p) => p.id).sort(), ["claude", "cursor", "gemini"]);
  assert.equal(r.providers.find((p) => p.id === "claude").collected_at, fresh.collected_at); // 캐시가 신선분을 못 덮는다
  assert.equal(r.statuses.claude, "ok"); // 정상 수집분은 그대로
  assert.equal(r.statuses.gemini, "stale"); // 판정이 없던 복원분만 stale
  assert.equal(r.statuses.cursor, "auth_expired"); // 이미 실패로 기록된 건 덮지 않는다

  // CodexBar가 정상 완료했으면 사라진 codexbar 항목은 사용자가 끈 것, 복원도 stale도 없다
  const complete = C.mergeCachedProviders({ providers: [], cached, codexBarComplete: true, statuses: {} });
  assert.deepEqual(complete.providers.map((p) => p.id), ["claude"]);
  assert.deepEqual(complete.statuses, { claude: "stale" });

  // 수집이 통째로 죽어 상태 미상(null)이면 null 그대로, 없는 판정을 지어내지 않는다
  assert.equal(C.mergeCachedProviders({ providers: [], cached, statuses: null }).statuses, null);
});

test("T14b mergeCachedProviders: 구버전 캐시엔 collected_at을 만들어 붙이지 않는다", () => {
  const r = C.mergeCachedProviders({
    providers: [],
    cached: [{ id: "codex", account: "h1", session: { percent: 3, resets_at: futureReset } }],
    statuses: {},
  });
  const p = r.providers[0];
  // epoch(1970)로 찍던 우회는 앱까지 "56년 전"으로 새어 나갔다 , 
  // 이제 키를 아예 안 넣어 서버가 "나이 미상"으로 판정하게 둔다
  assert.equal("collected_at" in p, false);
  assert.equal(JSON.stringify(p).includes("1970"), false);
  assert.equal(p.session.percent, 3);
  // 계정 해시가 비면 캐시의 마지막 값으로 채운다
  const filled = C.mergeCachedProviders({
    providers: [{ id: "codex", account: null, collected_at: "2026-08-02T00:00:00.000Z" }],
    cached: [{ id: "codex", account: "h1" }],
    statuses: {},
  });
  assert.equal(filled.providers[0].account, "h1");
});

test("T15 collectLive: 활성 블록에 관측 시각을 붙인다 (charge_live 신선도 판정용)", async () => {
  const before = Date.now();
  const run = async () => ({ blocks: [{ id: "b0", isActive: false }, { id: "b1", isActive: true, costUSD: 1 }] });
  const live = await C.collectLive({ run });
  assert.equal(live.id, "b1");
  const t = Date.parse(live.collected_at);
  assert.ok(t >= before && t <= Date.now());
  assert.equal(await C.collectLive({ run: async () => ({ blocks: [] }) }), null);
});

test("T16 pairedUpload: 구버전 서버(404/PGRST202) 재시도는 상태 없이 보내고 흔적을 남긴다", async () => {
  const mode = { url: "https://x.supabase.co", anon: "a", token: "t" };
  const bodies = [];
  const fetchFn = async (_url, opts) => {
    bodies.push(JSON.parse(opts.body));
    return bodies.length === 1
      ? { ok: false, status: 404, text: async () => "PGRST202: function not found" }
      : { ok: true, status: 200, text: async () => "" };
  };
  const logs = [];
  const savedError = console.error;
  console.error = (...args) => logs.push(args.map(String).join(" "));
  try {
    await C.pairedUpload(mode, [], null, [], { claude: "ok" }, { fetchFn });
  } finally {
    console.error = savedError;
  }
  assert.equal(bodies.length, 2);
  assert.deepEqual(bodies[0].p_collect_status, { claude: "ok" });
  // 구버전 시그니처엔 파라미터 자체가 없다, 이번 사이클 상태는 반영되지 않는다
  assert.equal("p_collect_status" in bodies[1], false);
  // 상태가 왜 비었는지 로그 없이는 알 수 없으므로 반드시 흔적이 남아야 한다
  assert.equal(logs.some((l) => l.includes("collect_status")), true);

  // 정상 서버면 한 번만 호출하고 상태를 함께 보낸다
  const okBodies = [];
  await C.pairedUpload(mode, [], null, [], { claude: "ok" }, {
    fetchFn: async (_url, opts) => {
      okBodies.push(JSON.parse(opts.body));
      return { ok: true, status: 200, text: async () => "" };
    },
  });
  assert.equal(okBodies.length, 1);
});

test("T17 fetchOnceRetried: 시도마다 새 타임아웃 예산 (1차가 예산 끝에서 죽어도 2차는 온전히 돈다)", async () => {
  const timeoutMs = 300;
  const nearBudget = timeoutMs - 80; // 예산을 거의 다 쓰는 시간
  const seen = [];
  const fetchFn = async (_url, opts) => {
    const record = { signal: opts.signal, header: opts.headers?.a, abortedAtStart: opts.signal.aborted, abortedLate: null };
    seen.push(record);
    await new Promise((r) => setTimeout(r, nearBudget));
    if (seen.length === 1) throw new TypeError("fetch failed"); // 잠에서 깬 직후의 네트워크 계층 실패
    record.abortedLate = opts.signal.aborted; // 1차 예산을 물려받았다면 여기선 이미 만료다
    return { ok: true, status: 200 };
  };
  const res = await C.fetchOnceRetried(fetchFn, "https://x", { headers: { a: "1" } }, { timeoutMs, delayMs: 20 });

  assert.equal(res.ok, true);
  assert.equal(seen.length, 2);
  assert.notEqual(seen[0].signal, seen[1].signal); // 시그널 재사용 금지
  assert.equal(seen[1].abortedAtStart, false); // 2차가 시작부터 abort된 채 출발하면 재시도가 무의미하다
  assert.equal(seen[1].abortedLate, false); // 예전 구현이면 여기서 true (1차가 예산을 다 썼다)
  assert.equal(seen[0].signal.aborted, true); // 1차 예산은 진작 소진됐다 = 재사용했다면 못 살아남을 상황
  assert.deepEqual([seen[0].header, seen[1].header], ["1", "1"]); // 호출자 옵션(헤더)은 그대로 전달

  // 상태 코드가 온 요청, 타임아웃은 재시도하지 않는다 (기존 규칙 유지)
  let timeoutCalls = 0;
  await assert.rejects(
    () => C.fetchOnceRetried(async () => {
      timeoutCalls += 1;
      const e = new Error("aborted");
      e.name = "TimeoutError";
      throw e;
    }, "https://x", {}, { timeoutMs: 50, delayMs: 5 }),
    { name: "TimeoutError" },
  );
  assert.equal(timeoutCalls, 1);
});

test("T18 codexProvider: 만료 창만 남은 스냅샷은 올리지 않고 stale로 보고한다", async () => {
  const auth = { plan: "Pro", account: "h1" };
  const base = { hasCodex: () => true, loadAuth: () => auth, liveWindows: async () => null };

  // 3일 묵어 리셋이 다 지난 스냅샷, 창이 전부 null인 프로바이더를 올리면 앱엔 빈 카드가 뜨고
  // 서버 행의 collected_at이 며칠 전으로 되감긴다. 아예 안 올리고 캐시 폴백에 맡긴다.
  const expired = await C.codexProvider({
    ...base,
    snapshotWindows: () => ({ session: null, weekly: null, collected_at: "2026-08-10T00:00:00.000Z" }),
  });
  assert.equal(expired.provider, null);
  // "error"면 앱이 재로그인/수집 실패 경고를 띄운다, 깨진 건 없고 데이터가 낡았을 뿐이다
  assert.equal(expired.status, "stale");

  // 관측 자체가 없으면(실시간, 스냅샷 둘 다 실패) 여전히 error
  const nothing = await C.codexProvider({ ...base, snapshotWindows: () => null });
  assert.equal(nothing.provider, null);
  assert.equal(nothing.status, "error");

  // 살아 있는 창이 하나라도 있으면 스냅샷 폴백으로 올라가고 관측 시각은 mtime 그대로
  const usable = await C.codexProvider({
    ...base,
    snapshotWindows: () => ({
      session: { percent: 41, resets_at: futureReset },
      weekly: { percent: 8, resets_at: new Date(Date.now() - 60_000).toISOString() }, // 만료분은 여기서도 제거
      collected_at: "2026-08-10T00:00:00.000Z",
    }),
  });
  assert.equal(usable.status, "stale");
  assert.equal(usable.provider.session.percent, 41);
  assert.equal(usable.provider.weekly, null);
  assert.equal(usable.provider.plan, "Pro");
  assert.equal(usable.provider.collected_at, "2026-08-10T00:00:00.000Z");

  // 실시간 조회가 되면 ok + 지금이 관측 시각, 스냅샷은 아예 읽지 않는다
  let snapshotRead = 0;
  const before = Date.now();
  const live = await C.codexProvider({
    ...base,
    liveWindows: async () => ({ session: { percent: 5, resets_at: futureReset }, weekly: null, plan: "Plus" }),
    snapshotWindows: () => { snapshotRead += 1; return null; },
  });
  assert.equal(live.status, "ok");
  assert.equal(live.provider.plan, "Plus");
  assert.equal(snapshotRead, 0);
  assert.ok(Date.parse(live.provider.collected_at) >= before);

  // Codex 미설치면 collect_status에 항목을 만들지 않는다
  assert.deepEqual(await C.codexProvider({ hasCodex: () => false }), { provider: null, status: null });
});

test("T18b codexProvider: live 조회는 됐는데 창이 전부 만료면 ok가 아니라 stale", async () => {
  const past = new Date(Date.now() - 60_000).toISOString();
  let snapshotRead = 0;
  const r = await C.codexProvider({
    hasCodex: () => true,
    loadAuth: () => ({ plan: "Pro", account: "h1" }),
    liveWindows: async () => ({
      session: { percent: 97, resets_at: past },
      weekly: { percent: 88, resets_at: past },
      plan: "Plus",
    }),
    snapshotWindows: () => { snapshotRead += 1; return null; },
  });
  assert.equal(r.provider, null); // 전부 null인 빈 카드는 올리지 않는다
  // 조회는 성공했지만 이번 사이클에 올라가는 건 캐시 폴백뿐이다, "ok"는 거짓말이다
  assert.equal(r.status, "stale");
  assert.equal(snapshotRead, 0); // live가 성공했으니 스냅샷은 여전히 안 읽는다
});
