// Charge collector 단위 테스트 — 실행: node --test collector/
// 순수 함수만 검증한다 (네트워크·ccusage 불필요).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const C = require("./collect");
const I = require("./identity");

const futureReset = "2099-01-02T03:04:05Z";

test("T01 accountHash: 결정적 12자 해시, 빈 값은 null", () => {
  assert.equal(C.accountHash(null), null);
  assert.equal(C.accountHash(""), null);
  const h = C.accountHash("user-uuid-123");
  assert.equal(h.length, 12);
  assert.equal(h, C.accountHash("user-uuid-123"));
  assert.notEqual(h, C.accountHash("user-uuid-456"));
});

test("T01b installation id: 토큰과 독립적으로 재사용하고 깨진 파일은 복구", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "charge-device-id-"));
  try {
    const file = path.join(dir, "device.json");
    const first = "123e4567-e89b-42d3-a456-426614174000";
    const second = "123e4567-e89b-42d3-a456-426614174001";
    assert.equal(I.resolveInstallationID(file, { randomUUID: () => first }), first);
    assert.equal(I.resolveInstallationID(file, { randomUUID: () => second }), first);
    fs.writeFileSync(file, "broken");
    assert.equal(I.resolveInstallationID(file, { randomUUID: () => second }), second);
    assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).installation_id, second);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("T01c unknown account: 같은 설치/프로바이더만 같은 격리 키", () => {
  const a = "123e4567-e89b-42d3-a456-426614174000";
  const b = "123e4567-e89b-42d3-a456-426614174001";
  assert.match(I.unknownAccountKey(a, "claude"), /^unknown:[a-f0-9]{16}$/);
  assert.equal(I.unknownAccountKey(a, "claude"), I.unknownAccountKey(a, "claude"));
  assert.notEqual(I.unknownAccountKey(a, "claude"), I.unknownAccountKey(b, "claude"));
  assert.notEqual(I.unknownAccountKey(a, "claude"), I.unknownAccountKey(a, "codex"));
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
    hasClaude: () => false,
  });
  assert.equal(missing.provider, null);
  assert.equal(missing.status, null);
});

test("Claude detection distinguishes missing login, absent tools, 403 and 429", async () => {
  const detected = await C.claudeProvider({
    hasClaude: () => true,
    loadCredentials: async () => { throw new Error("keychain unavailable"); },
    fetchFn: async () => { throw new Error("must not query without credentials"); },
  });
  assert.deepEqual(detected, { provider: null, status: "error:credentials_missing" });
  for (const [code, expected] of [[403, "error:access_denied"], [429, "error:rate_limited"]]) {
    const result = await C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: "test-token" } }),
      // 프로필은 정상이고 usage만 거절한다 (프로필 429는 게이트를 걸어 usage를 보내지 않는다, T27)
      fetchFn: async (url) => (String(url).endsWith("/profile")
        ? { ok: true, status: 200, json: async () => ({ account: { uuid: "u" } }) }
        : { ok: false, status: code }),
    });
    // 0.2.0부터 429에는 K1 계약대로 ";retry_at=<초>" 파라미터가 붙는다, 접두사는 그대로다
    assert.equal(result.status.split(";")[0], expected);
    if (code === 429) assert.match(result.status, /^error:rate_limited;retry_at=\d+$/);
  }
});

test("Claude credentials follow the selected store and never fall back to another account", async () => {
  const home = path.join(os.tmpdir(), "charge-claude-home");
  const custom = path.join(home, "work");
  const env = { CLAUDE_CONFIG_DIR: custom };
  const location = C.claudeCredentialLocation(env, home);
  assert.equal(location.file, path.join(custom, ".credentials.json"));
  assert.match(location.service, /^Claude Code-credentials-[a-f0-9]{8}$/);
  const requested = [];
  const creds = await C.claudeCredentials({ env, home,
    run: async (_cmd, args) => {
      requested.push(args[2]);
      return JSON.stringify({ claudeAiOauth: { expiresAt: 999999 } }); // unusable, though newer
    },
    read: (file) => {
      assert.equal(file, location.file);
      return JSON.stringify({ claudeAiOauth: { accessToken: "work", expiresAt: 1000 } });
    },
  });
  assert.equal(creds.claudeAiOauth.accessToken, "work");
  assert.equal(creds.credentialSource, "file");
  assert.deepEqual(requested, [location.service]);
  const pinned = C.claudeCredentialLocation({ ...env, CLAUDE_SECURESTORAGE_CONFIG_DIR: "" }, home);
  assert.equal(pinned.service, "Claude Code-credentials");
  assert.equal(pinned.file, path.join(home, ".claude", ".credentials.json"));
  assert.equal(pinned.configDir, custom);
  const independent = C.claudeCredentialLocation({ ...env, CLAUDE_SECURESTORAGE_CONFIG_DIR: custom + "-login" }, home);
  assert.notEqual(independent.service, location.service);
  assert.equal(independent.file, path.join(custom + "-login", ".credentials.json"));
  assert.equal(
    C.claudeCredentialLocation({ CLAUDE_CONFIG_DIR: "cafe\u0301" }, home).service,
    C.claudeCredentialLocation({ CLAUDE_CONFIG_DIR: "caf\u00e9" }, home).service
  );
  await assert.rejects(C.claudeCredentials({ env, home,
    run: async () => { throw new Error("not found"); },
    read: () => { throw new Error("not found"); },
  }), /로그인/);
});

test("Collection health persists real attempts and resets on recovery, gaps and pairing changes", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "charge-health-"));
  const file = path.join(dir, "health.json");
  const start = Date.parse("2026-09-14T00:00:00Z");
  const record = (statuses, minutes, extra = {}) => C.recordCollectionHealth(statuses,
    { file, scope: "device-a", now: start + minutes * 60_000, ...extra });
  try {
    for (let i = 0; i < 5; i++) {
      const status = i % 2 ? "auth_expired" : "error:rate_limited";
      const result = record({ claude: status, codex: "ok" }, i * 5);
      assert.equal(result.claude, `${status};failures=${i + 1};since=${start / 1000}`);
      assert.equal(result.codex, "ok");
    }
    const before = fs.readFileSync(file, "utf8");
    record({ claude: "error" }, 25, { persist: false });
    assert.equal(fs.readFileSync(file, "utf8"), before, "dry-run must not count attempts");
    assert.equal(record({ claude: "error" }, 25).claude, `error;failures=6;since=${start / 1000}`);
    assert.deepEqual(record({ claude: "ok" }, 30), { claude: "ok" });
    assert.equal(record({ claude: "error" }, 35).claude, `error;failures=1;since=${start / 1000 + 35 * 60}`);
    assert.equal(record({ claude: "error" }, 60).claude, `error;failures=1;since=${start / 1000 + 60 * 60}`);
    assert.equal(record({ claude: "error" }, 65, { scope: "device-b" }).claude,
      `error;failures=1;since=${start / 1000 + 65 * 60}`);
    fs.writeFileSync(file, "corrupt");
    assert.match(record({ claude: "error" }, 70).claude, /failures=1;/);
    assert.equal(record(null, 75), null);
    assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).failures, {});
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("Collection health does not carry failed streaks through stale, missing or invalid observations", () => {
  const now = Date.now();
  const previous = { claude: { count: 4, since: now - 20 * 60_000, lastAttempt: now - 5 * 60_000 } };
  for (const statuses of [{ claude: "stale" }, {}, null]) {
    assert.deepEqual(C.advanceCollectionHealth(statuses, previous, now).failures, {});
  }
  for (const bad of [null, { count: -1 }, { ...previous.claude, lastAttempt: now + 60_000 }]) {
    assert.match(C.advanceCollectionHealth({ claude: "error" }, { claude: bad }, now).statuses.claude, /failures=1;/);
  }
});

test("T09e freshestCredentials: 만료가 알려진 소스보다 미래/미상 소스, 그중 가장 늦은 만료, 미상끼리는 Keychain (D2)", async () => {
  const now = Date.parse("2026-09-15T00:00:00Z");
  const src = (accessToken, expiresAt) => ({ claudeAiOauth: { accessToken, expiresAt } });
  const pick = (sources) => C.freshestCredentials(sources, now).claudeAiOauth.accessToken;
  // 둘 다 만료면 더 늦게 만료된 쪽 (SSH 세션이 파일에만 토큰을 갱신하는 경우), 순서와 무관
  assert.equal(pick([src("old", 1000), src("new", 2000)]), "new");
  assert.equal(pick([src("new", 2000), src("old", 1000)]), "new");
  assert.equal(pick([src("old", 1000)]), "old");
  // 만료 미상끼리는 앞선 소스(Keychain)
  assert.equal(pick([src("a"), src("b")]), "a");
  // 만료가 알려진 소스보다 미상, 미상보다 미래 만료, 미래 중에서는 가장 늦은 만료
  assert.equal(pick([src("expired", now - 60_000), src("unknown")]), "unknown");
  assert.equal(pick([src("unknown"), src("future", now + 3600_000)]), "future");
  assert.equal(pick([src("sooner", now + 3600_000), src("later", now + 7200_000)]), "later");
  // 30초 안에 만료되는 소스는 만료로 친다
  assert.equal(pick([src("almost", now + 10_000), src("unknown")]), "unknown");
  // 1e11 미만은 초 단위, 문자열은 미상
  assert.equal(pick([src("seconds", Math.floor((now + 3600_000) / 1000)), src("unknown")]), "seconds");
  assert.equal(pick([src("expired", now - 60_000), src("string", String(now + 3600_000))]), "string");
  assert.equal(C.epochMs(1_789_430_400), 1_789_430_400_000);
  assert.equal(C.epochMs(1_789_430_400_000), 1_789_430_400_000);
  for (const unknown of ["1789430400000", null, undefined, 0, -1, Number.NaN, Number.POSITIVE_INFINITY, {}]) {
    assert.equal(C.epochMs(unknown), null, String(unknown));
  }

  // claudeCredentials는 고른 소스를 credentialSource로 붙여 준다 (진단 로그용)
  const load = (keychain, file) => C.claudeCredentials({
    env: {}, home: os.tmpdir(), now,
    run: async () => JSON.stringify(keychain),
    read: () => JSON.stringify(file),
  });
  const fromFile = await load(src("expired", now - 60_000), src("fresh", now + 3600_000));
  assert.deepEqual([fromFile.claudeAiOauth.accessToken, fromFile.credentialSource], ["fresh", "file"]);
  const fromKeychain = await load(src("unknown"), src("expired", now - 60_000));
  assert.deepEqual([fromKeychain.claudeAiOauth.accessToken, fromKeychain.credentialSource], ["unknown", "keychain"]);
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
  let usageCalls = 0;
  // usage 1회차는 잠에서 깬 직후처럼 네트워크 계층에서 죽고, 2회차에 Wi-Fi가 붙은 상황 (프로필은 정상)
  const flaky = async (url) => {
    if (!String(url).includes("/usage")) return { ok: true, status: 200, json: async () => ({ account: { uuid: "u" } }) };
    usageCalls += 1;
    if (usageCalls === 1) throw new TypeError("fetch failed");
    return {
      ok: true,
      status: 200,
      json: async () => ({ five_hour: { utilization: 5, resets_at: futureReset }, limits: [] }),
    };
  };
  const r = await C.claudeProvider({ fetchFn: flaky, loadCredentials: creds });
  assert.equal(r.status, "ok");
  assert.equal(r.provider.session.percent, 5);
  assert.equal(usageCalls, 2);

  // 상태 코드가 온 응답은 재시도하지 않는다 (401을 두 번 물어봐야 답이 같다)
  let authCalls = 0;
  const always401 = async (url) => {
    if (String(url).includes("/usage")) authCalls += 1;
    return { ok: false, status: 401 };
  };
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
  // 계정 해시가 비어도 예전 계정이라고 추정하지 않는다. 로그인 전환 직후 프로필 조회만
  // 실패한 경우 새 계정 값을 예전 계정 행에 덮는 것보다 기기별 미상으로 격리하는 편이 안전하다.
  const unidentified = C.mergeCachedProviders({
    providers: [{ id: "codex", account: null, collected_at: "2026-08-02T00:00:00.000Z" }],
    cached: [{ id: "codex", account: "h1" }],
    statuses: {},
  });
  assert.equal(unidentified.providers[0].account, null);
  const namespaced = C.namespaceUnknownAccounts(unidentified.providers, "123e4567-e89b-42d3-a456-426614174000");
  assert.match(namespaced[0].account, /^unknown:[a-f0-9]{16}$/);
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

// ---- 0.2.0: 429 게이트, 로컬 만료, 401 구분, 계정 해시, 조회 임대, 요청 간격, 상태 파라미터, 캐시 위생, 자체 점검 ----

function withTempDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "charge-020-"));
  return Promise.resolve()
    .then(() => fn(dir))
    .finally(() => fs.rmSync(dir, { recursive: true, force: true }));
}

async function quietly(fn) {
  const saved = { log: console.log, error: console.error };
  const lines = [];
  console.log = (...args) => lines.push(args.map(String).join(" "));
  console.error = (...args) => lines.push(args.map(String).join(" "));
  try {
    return { value: await fn(), lines };
  } finally {
    console.log = saved.log;
    console.error = saved.error;
  }
}

const usageBody = () => JSON.stringify({ five_hour: { utilization: 7, resets_at: futureReset }, seven_day: { utilization: 30, resets_at: futureReset }, limits: [] });

test("T20 parseRetryAfter: 초, HTTP 날짜, 0, 깨진 값", () => {
  const now = Date.parse("2026-09-15T00:00:00Z");
  assert.equal(C.parseRetryAfter("120", now), 120);
  assert.equal(C.parseRetryAfter(" 3600 ", now), 3600);
  assert.equal(C.parseRetryAfter("0", now), 0);
  assert.equal(C.parseRetryAfter(new Date(now + 90_000).toUTCString(), now), 90);
  assert.equal(C.parseRetryAfter(new Date(now - 90_000).toUTCString(), now), 0); // 지난 날짜는 0
  // HTTP 날짜 세 형식은 모두 GMT다. 시간대 표기가 없는 asctime도 이 PC의 시간대와 무관하게 읽는다
  const savedTZ = process.env.TZ;
  process.env.TZ = "Asia/Seoul";
  try {
    assert.equal(C.parseRetryAfter("Tue, 15 Sep 2026 00:10:00 GMT", now), 600);
    assert.equal(C.parseRetryAfter("Tuesday, 15-Sep-26 00:10:00 GMT", now), 600);
    assert.equal(C.parseRetryAfter("Tue Sep 15 00:10:00 2026", now), 600);
  } finally {
    if (savedTZ === undefined) delete process.env.TZ;
    else process.env.TZ = savedTZ;
  }
  for (const garbage of [null, undefined, "", "soon", "1.5", "-5", "12abc", "2026-09-15"]) {
    assert.equal(C.parseRetryAfter(garbage, now), null, JSON.stringify(garbage));
  }
  assert.equal(C.parseRetryAfter("99999999999", now), 86_400); // 비정상적으로 큰 값은 하루로 자른다
});

test("T21 rate-limit gate math: Retry-After N은 N+60초, 0/없음/깨짐은 300초에서 1.5배씩 1800초까지", () => {
  const now = 1_000_000_000_000;
  const scope = { account: null, credential: "0123456789abcdef" };
  const delta = C.nextRateLimitGate(null, scope, "120", now);
  assert.deepEqual(delta, { ...scope, retryAt: now + 180_000, backoff: 0, cause: "retry-after" });
  const sequence = [];
  let gate = null;
  for (let i = 0; i < 7; i += 1) {
    gate = C.nextRateLimitGate(gate, scope, i % 2 ? "garbage" : "0", now);
    sequence.push(gate.backoff);
    assert.equal(gate.retryAt, now + gate.backoff * 1000);
    assert.equal(gate.cause, "backoff");
  }
  assert.deepEqual(sequence, [300, 450, 675, 1013, 1520, 1800, 1800]);
  // Retry-After가 온 429 사이에도 백오프 진행은 보존된다
  const kept = C.nextRateLimitGate({ ...scope, retryAt: now, backoff: 675, cause: "backoff" }, scope, "30", now);
  assert.equal(kept.backoff, 675);
  assert.equal(kept.cause, "retry-after");
  assert.equal(C.nextRateLimitGate(kept, scope, null, now).backoff, 1013);
  // 확실히 다른 계정의 백오프는 잇지 않는다 (계정을 모르면 같은 계정일 수 있어 잇는다)
  const previous = { account: "aaaaaaaaaaaa", credential: scope.credential, retryAt: now, backoff: 1800, cause: "backoff" };
  assert.equal(C.nextRateLimitGate(previous, { account: "bbbbbbbbbbbb", credential: scope.credential }, "0", now).backoff, 300);
  assert.equal(C.nextRateLimitGate(previous, { account: null, credential: scope.credential }, "0", now).backoff, 1800);
  // 파일에서 읽을 때: 형식이 틀리거나 시계가 크게 뒤로 간 기록은 게이트 없음
  assert.deepEqual(C.parseRateLimitGate(delta, now), delta);
  for (const broken of [
    { ...delta, cause: "later" },
    { ...delta, account: "UPPERCASE123" },
    { ...delta, credential: "short" },
    { ...delta, backoff: 99_999 },
    { ...delta, retryAt: now + 90_000_000 },
    null,
    "gate",
  ]) {
    assert.equal(C.parseRateLimitGate(broken, now), null, JSON.stringify(broken));
  }
});

test("T21b gate scope: account when known, Retry-After deadlines survive token changes, backoff allows one probe (D12)", () => {
  const now = 1_000_000_000_000;
  const A = "aaaaaaaaaaaa";
  const B = "bbbbbbbbbbbb";
  const k1 = "1111111111111111";
  const k2 = "2222222222222222";
  const gate = (cause, account = A) => ({ account, credential: k1, retryAt: now + 600_000, backoff: 300, cause });
  const blocks = (g, scope) => C.blockingRateLimitGate(g, scope, now) !== null;
  for (const cause of ["retry-after", "backoff"]) {
    assert.equal(blocks(gate(cause), { account: A, credential: k1 }), true, `${cause}: same account and credential`);
    assert.equal(blocks(gate(cause), { account: null, credential: k1 }), true, `${cause}: same credential, account unknown`);
    assert.equal(blocks(gate(cause), { account: B, credential: k1 }), false, `${cause}: another account is another limit`);
    assert.equal(blocks({ ...gate(cause), retryAt: now }, { account: A, credential: k1 }), false, `${cause}: deadline passed`);
  }
  // 새 자격증명: 서버가 준 기한은 지키고, 계산한 백오프만 한 번 확인해 본다
  assert.equal(blocks(gate("retry-after"), { account: A, credential: k2 }), true);
  assert.equal(blocks(gate("retry-after"), { account: null, credential: k2 }), true);
  assert.equal(blocks(gate("retry-after", null), { account: B, credential: k2 }), true, "an unknown gate account cannot prove another account");
  assert.equal(blocks(gate("backoff"), { account: A, credential: k2 }), false);
  assert.equal(blocks(gate("backoff"), { account: null, credential: k2 }), false);
  assert.equal(C.blockingRateLimitGate(null, { account: A, credential: k1 }, now), null);
});

test("T22 429 gate state persists, blocks per scope, probes once after a token change and clears on 200", async () => {
  await withTempDir(async (dir) => {
    const stateFile = path.join(dir, "state.json");
    const accountFile = path.join(dir, "account.json");
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    let now = t0;
    const calls = [];
    const usageCalls = () => calls.filter((url) => url.endsWith("/usage")).length;
    let reply = () => new Response('{"error":{"type":"rate_limit_error"}}', { status: 429, headers: { "Retry-After": "0" } });
    // 프로필은 늘 acct-a를 답한다. local은 .claude.json이 알려주는 계정 (프로필이 게이트에 막혔을 때 쓰인다)
    const provider = (refreshToken, { local = null } = {}) => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: `access-${refreshToken}`, refreshToken } }),
      fetchFn: async (url) => {
        calls.push(String(url));
        return String(url).endsWith("/profile")
          ? new Response(JSON.stringify({ account: { uuid: "acct-a" } }), { status: 200 })
          : reply();
      },
      readAccountUuid: local ? async () => local : null,
      stateFile,
      accountFile,
      now: () => now,
    });

    const first = (await quietly(() => provider("r1"))).value;
    assert.equal(first.status, `error:rate_limited;retry_at=${t0 / 1000 + 300}`);
    assert.equal(usageCalls(), 1);
    assert.deepEqual(JSON.parse(fs.readFileSync(stateFile, "utf8")), {
      gate: { account: C.accountHash("acct-a"), credential: C.credentialKey("r1"), retryAt: t0 + 300_000, backoff: 300, cause: "backoff" },
      lastRequestAt: t0,
      lastStatus: first.status,
      lastToken: C.credentialKey("access-r1"),
    });
    assert.equal(fs.readFileSync(stateFile, "utf8").includes("access-"), false); // 토큰 원문은 저장하지 않는다
    if (process.platform !== "win32") assert.equal(fs.statSync(stateFile).mode & 0o777, 0o600);

    now = t0 + 60_000;
    const blocked = await quietly(() => provider("r1"));
    assert.equal(blocked.value.status, `error:rate_limited;retry_at=${t0 / 1000 + 300};deferred=1`);
    assert.equal(usageCalls(), 1, "no request while the gate is active");
    assert.equal(blocked.lines.length, 1, blocked.lines.join("\n"));
    assert.ok(blocked.lines[0].startsWith("claude usage 요청 안 함 (gated) retry_at=2026-09-15T00:05:00.000Z cause=backoff generation="), blocked.lines[0]);
    assert.ok(blocked.lines[0].endsWith(`account=${C.accountHash("acct-a")}`), blocked.lines[0]);

    // 계산한 백오프는 새 자격증명으로 한 번 확인해 본다. 새 자격증명의 계정을 아직 모르면 그 확인은 프로필 요청이고,
    // 같은 계정이라고 나오면 usage는 이번 사이클에 보내지 않는다 (한 사이클에 한 번만 확인한다)
    now = t0 + 250_000;
    const profileProbe = await quietly(() => provider("r2"));
    assert.equal(calls.filter((url) => url.endsWith("/profile")).length, 2);
    assert.equal(usageCalls(), 1, "the profile request was this cycle's only probe");
    assert.equal(profileProbe.value.status, `error:rate_limited;retry_at=${t0 / 1000 + 300};deferred=1`);
    assert.equal(profileProbe.lines.length, 1, profileProbe.lines.join("\n"));
    assert.match(profileProbe.lines[0], /\(gated\) .*cause=backoff/);
    // 계정을 안 다음 사이클(백오프가 아직 남았다)에 usage로 확인한다. 또 429면 300이 아니라 이어서 450
    now = t0 + 260_000;
    const probe = (await quietly(() => provider("r2"))).value;
    assert.equal(usageCalls(), 2);
    assert.equal(probe.status, `error:rate_limited;retry_at=${now / 1000 + 450}`);
    now += 60_000;
    await quietly(() => provider("r2"));
    assert.equal(usageCalls(), 2, "the probe is only one request");

    // 서버가 Retry-After N초로 준 기한은 토큰이 바뀌어도, 새 토큰의 계정을 아직 몰라도 지킨다
    now = t0 + 711_000;
    reply = () => new Response("{}", { status: 429, headers: { "Retry-After": "3600" } });
    const explicit = (await quietly(() => provider("r2"))).value;
    assert.equal(usageCalls(), 3);
    const deadline = now + 3_660_000;
    assert.equal(explicit.status, `error:rate_limited;retry_at=${deadline / 1000}`);
    now += 300_000;
    for (const token of ["r3", "r4"]) {
      const held = await quietly(() => provider(token));
      assert.equal(held.value.status, `error:rate_limited;retry_at=${deadline / 1000};deferred=1`, token);
      assert.match(held.lines.join("\n"), /cause=retry-after/);
    }
    assert.equal(usageCalls(), 3);
    assert.equal(calls.filter((url) => url.endsWith("/profile")).length, 2, "the profile request obeys the gate too");

    // .claude.json이 다른 계정(B)이라고 알려주면 그 계정의 한도가 아니다. 200이면 게이트를 지운다
    reply = () => new Response(usageBody(), { status: 200 });
    const other = (await quietly(() => provider("r5", { local: "acct-b" }))).value;
    assert.equal(other.status, "ok");
    assert.equal(other.provider.account, C.accountHash("acct-b"));
    assert.equal(usageCalls(), 4);
    assert.equal(JSON.parse(fs.readFileSync(stateFile, "utf8")).gate, null);

    // 깨진 상태 파일은 게이트 없음
    now += 300_000;
    fs.writeFileSync(stateFile, "{not json");
    await quietly(() => provider("r5", { local: "acct-b" }));
    assert.equal(usageCalls(), 5);
  });
});

test("T23 expired token is reported locally without a request or a lease claim, unknown expiry still requests (D2)", async () => {
  const now = Date.parse("2026-09-15T00:00:00Z");
  for (const expiresAt of [now + 10_000, now - 3600_000, Math.floor((now + 5_000) / 1000)]) {
    let requested = false;
    let claimed = false;
    const { value, lines } = await quietly(() => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", refreshToken: "ref", expiresAt }, credentialSource: "file" }),
      fetchFn: async () => { requested = true; throw new Error("must not request"); },
      claimLease: async () => { claimed = true; return true; },
      now: () => now,
    }));
    assert.deepEqual(value, { provider: null, status: "auth_expired" }, String(expiresAt));
    assert.equal(requested, false);
    assert.equal(claimed, false, "an expired device must not hold the lease");
    assert.equal(lines.length, 1, lines.join("\n"));
    const expected = `claude usage 요청 안 함 (expired) expires_at=${new Date(C.epochMs(expiresAt)).toISOString()} source=file generation=${C.credentialKey("ref").slice(0, 8)}`;
    assert.ok(lines[0].startsWith(expected), lines[0]);
    assert.equal(/tok|ref/.test(lines[0].slice(expected.length)), false);
  }
  // 만료 시각이 숫자가 아니거나(문자열 포함) 0 이하, 무한대면 미상이다: 요청은 평소처럼 나간다
  for (const expiresAt of [String(now - 3600_000), 0, -5, Number.POSITIVE_INFINITY, null, now + 3600_000]) {
    let requested = 0;
    const { value } = await quietly(() => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", expiresAt } }),
      fetchFn: async (url) => {
        if (!String(url).endsWith("/usage")) return new Response("{}", { status: 403 });
        requested += 1;
        return new Response(usageBody(), { status: 200 });
      },
      now: () => now,
    }));
    assert.equal(requested, 1, String(expiresAt));
    assert.equal(value.status, "ok", String(expiresAt));
  }
});

test("T24 401 is revoked only for explicit revoked or invalid credential wording, everything else is expired (D8)", async () => {
  const cases = [
    ['{"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired. Please obtain a new token or refresh your existing token."}}', "auth_expired"],
    ['{"error":{"message":"OAuth token has been revoked"}}', "auth_expired:revoked"],
    ['{"error":{"message":"Invalid bearer token"}}', "auth_expired:revoked"],
    ['{"error":"invalid_grant"}', "auth_expired:revoked"],
    ['{"error":"invalid grant"}', "auth_expired:revoked"],
    ['{"error":{"message":"Invalid authentication credentials"}}', "auth_expired:revoked"],
    ['{"error":{"message":"invalid access token"}}', "auth_expired:revoked"],
    ['{"error":{"message":"Invalid request"}}', "auth_expired"],
    ['{"error":{"message":"invalid x-api-key"}}', "auth_expired"],
    ['{"error":{"message":"invalid token"}}', "auth_expired"],
    ["", "auth_expired"],
    ["unauthorized", "auth_expired"],
  ];
  for (const [body, expected] of cases) {
    const { value } = await quietly(() => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok" } }),
      fetchFn: async () => new Response(body, { status: 401 }),
    }));
    assert.equal(value.status, expected, body);
    assert.equal(C.unauthorizedStatus(body), expected, body);
  }
  // 본문은 2KB까지만 본다, 그 뒤의 단어로 판정이 바뀌지 않는다
  const { value } = await quietly(() => C.claudeProvider({
    loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok" } }),
    fetchFn: async () => new Response(`${" ".repeat(4096)}revoked`, { status: 401 }),
  }));
  assert.equal(value.status, "auth_expired");
});

test("T25 non-2xx logs status, Retry-After and a short body without tokens or control characters", async () => {
  const secret = "sk-ant-oat01-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789";
  const body = `{"error":"rate limited","echo":"Bearer ${secret}","jwt":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9eyJzdWIiOiIxMjM0NTY3ODkwIn0","hex":"0123456789abcdef0123456789abcdef","pad":"${"z ".repeat(300)}"}`;
  const { value, lines } = await quietly(() => C.claudeProvider({
    loadCredentials: async () => ({ claudeAiOauth: { accessToken: secret } }),
    fetchFn: async (url) => (String(url).endsWith("/profile")
      ? new Response(JSON.stringify({ account: { uuid: "u" } }), { status: 200 })
      : new Response(body, { status: 429, headers: { "Retry-After": "3600" } })),
  }));
  assert.match(value.status, /^error:rate_limited;retry_at=\d+$/);
  const line = lines.find((l) => l.startsWith("claude usage API 429"));
  assert.ok(line, lines.join("\n"));
  assert.match(line, /Retry-After: 3600/);
  assert.match(line, /rate limited/);
  assert.equal(lines.join("\n").includes(secret), false);
  assert.equal(lines.join("\n").includes("0123456789abcdef0123456789abcdef"), false);
  assert.equal(lines.join("\n").includes("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"), false);
  assert.ok(C.sanitizeLogSnippet(body).length <= 200);
  assert.equal(C.sanitizeLogSnippet(`Authorization: Bearer abc.def`), "Authorization: Bearer [redacted]");
  // 제어 문자(줄바꿈, ESC, 글자 방향 전환)는 자르기 전에 공백으로 바뀐다, 로그 줄을 위조하지 못한다
  const esc = String.fromCharCode(27);
  const forged = `ok${String.fromCharCode(10)}[2026-09-15T00:00:00Z] 업로드 완료 ${esc}[2J${String.fromCharCode(0x202e)}txt`;
  const cleaned = C.sanitizeLogSnippet(forged);
  assert.equal(/[\p{Cc}\p{Bidi_Control}]/u.test(cleaned), false, cleaned);
  assert.ok(cleaned.startsWith("ok [2026-09-15T00:00:00Z]"), cleaned);
  const edge = C.sanitizeLogSnippet(`${"a b ".repeat(49)}ab${esc}[31m`, 200);
  assert.equal(edge.includes(esc), false);
  assert.ok(edge.length <= 200);
});

test("T26 User-Agent is charge-connect/<version> on every Anthropic request", async () => {
  const agents = [];
  await quietly(() => C.claudeProvider({
    loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok" } }),
    fetchFn: async (url, options) => {
      agents.push([String(url), options.headers["User-Agent"]]);
      return String(url).endsWith("/usage")
        ? new Response(usageBody(), { status: 200 })
        : new Response(JSON.stringify({ account: { uuid: "u" } }), { status: 200 });
    },
  }));
  const version = require("./package.json").version;
  assert.equal(C.USER_AGENT, `charge-connect/${version}`);
  // D3: 계정을 알아야 임대를 잡으므로 프로필이 usage보다 먼저다
  assert.deepEqual(agents, [
    ["https://api.anthropic.com/api/oauth/profile", `charge-connect/${version}`],
    ["https://api.anthropic.com/api/oauth/usage", `charge-connect/${version}`],
  ]);
  assert.equal(agents.some(([, ua]) => /claude-code|claude-cli/i.test(ua)), false);
});

test("T27 account hash follows the credential: cache, one profile request, then .claude.json only for a shared store (D3)", async () => {
  await withTempDir(async (dir) => {
    // 전역 설정 위치: CLAUDE_CONFIG_DIR 안, 없으면 홈 바로 아래
    const custom = path.join(dir, "work");
    fs.mkdirSync(custom);
    fs.writeFileSync(path.join(dir, ".claude.json"), JSON.stringify({ oauthAccount: { accountUuid: "home-uuid", emailAddress: "a@example.com" } }));
    fs.writeFileSync(path.join(custom, ".claude.json"), JSON.stringify({ oauthAccount: { accountUuid: "work-uuid" } }));
    assert.equal(C.claudeCredentialLocation({}, dir).globalConfig, path.join(dir, ".claude.json"));
    assert.equal(C.claudeCredentialLocation({ CLAUDE_CONFIG_DIR: custom }, dir).globalConfig, path.join(custom, ".claude.json"));
    assert.equal(await C.readClaudeAccountUuid({ env: {}, home: dir }), "home-uuid");
    assert.equal(await C.readClaudeAccountUuid({ env: { CLAUDE_CONFIG_DIR: custom }, home: dir }), "work-uuid");
    assert.equal(await C.readClaudeAccountUuid({ env: {}, home: path.join(dir, "missing") }), null);
    // 자격증명 저장소가 설정 폴더와 다르면 .claude.json의 계정을 이 자격증명의 계정으로 믿지 않는다
    assert.equal(await C.readClaudeAccountUuid({ env: { CLAUDE_CONFIG_DIR: custom, CLAUDE_SECURESTORAGE_CONFIG_DIR: "" }, home: dir }), null);
    assert.equal(await C.readClaudeAccountUuid({ env: { CLAUDE_SECURESTORAGE_CONFIG_DIR: path.join(dir, "elsewhere") }, home: dir }), null);
    assert.equal(await C.readClaudeAccountUuid({ env: { CLAUDE_SECURESTORAGE_CONFIG_DIR: "" }, home: dir }), "home-uuid");
    assert.equal(await C.readClaudeAccountUuid({ env: { CLAUDE_CONFIG_DIR: custom, CLAUDE_SECURESTORAGE_CONFIG_DIR: custom }, home: dir }), "work-uuid");

    const calls = [];
    const fetchFn = (profile) => async (url) => {
      calls.push(String(url).split("/").pop());
      if (String(url).endsWith("/usage")) return new Response(usageBody(), { status: 200 });
      return profile();
    };
    const creds = (refreshToken) => async () => ({ claudeAiOauth: { accessToken: `access-${refreshToken}`, refreshToken } });
    const accountFile = path.join(dir, "account.json");
    const profile = () => new Response(JSON.stringify({ account: { uuid: "profile-uuid" } }), { status: 200 });
    const local = () => C.readClaudeAccountUuid({ env: {}, home: dir });

    // 프로필이 .claude.json보다 먼저다 (.claude.json은 다른 로그인의 계정일 수 있다). 결과는 자격증명 키로 기억한다
    const r1 = await quietly(() => C.claudeProvider({ loadCredentials: creds("r1"), fetchFn: fetchFn(profile), readAccountUuid: local, accountFile }));
    assert.equal(r1.value.provider.account, C.accountHash("profile-uuid"));
    assert.deepEqual(calls.splice(0), ["profile", "usage"]);
    assert.deepEqual(JSON.parse(fs.readFileSync(accountFile, "utf8")), { credential: C.credentialKey("r1"), account: C.accountHash("profile-uuid") });
    assert.equal(fs.readFileSync(accountFile, "utf8").includes("profile-uuid"), false);
    const again = await quietly(() => C.claudeProvider({ loadCredentials: creds("r1"), fetchFn: fetchFn(profile), readAccountUuid: local, accountFile }));
    assert.equal(again.value.provider.account, C.accountHash("profile-uuid"));
    assert.deepEqual(calls.splice(0), ["usage"]);
    for (const secret of ["profile-uuid", "home-uuid", "a@example.com"]) {
      assert.equal([...r1.lines, ...again.lines].join("\n").includes(secret), false, secret);
    }

    // 리프레시 토큰이 없으면 액세스 토큰으로 키를 만든다
    await quietly(() => C.claudeProvider({ loadCredentials: async () => ({ claudeAiOauth: { accessToken: "only-access" } }), fetchFn: fetchFn(profile), accountFile }));
    assert.equal(JSON.parse(fs.readFileSync(accountFile, "utf8")).credential, C.credentialKey("only-access"));
    calls.splice(0);

    // 일시적 실패(429, 5xx, 네트워크)는 한 시간 기억하고 그동안은 .claude.json으로 대신한다, 한 시간 뒤 다시 묻는다
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    const transient = [
      ["429", () => new Response("{}", { status: 429, headers: { "retry-after": "0" } })],
      ["500", () => new Response("{}", { status: 500 })],
      ["network", () => { throw new TypeError("fetch failed"); }],
    ];
    for (const [label, failure] of transient) {
      const stateFile = path.join(dir, `state-${label}.json`);
      let reply = failure;
      const at = (ms) => ({ loadCredentials: creds(`r2-${label}`), fetchFn: fetchFn(() => reply()), readAccountUuid: local, accountFile, stateFile, now: () => ms });
      const first = await quietly(() => C.claudeProvider(at(t0)));
      assert.deepEqual(JSON.parse(fs.readFileSync(accountFile, "utf8")), { credential: C.credentialKey(`r2-${label}`), account: null, retryAt: t0 + 3600_000 }, label);
      if (label === "429") {
        // 프로필 429도 usage와 같은 게이트를 건다, 그 사이클에 usage는 보내지 않는다
        assert.deepEqual(calls.splice(0), ["profile"], label);
        assert.equal(first.value.status, `error:rate_limited;retry_at=${t0 / 1000 + 300};deferred=1`);
        assert.equal(JSON.parse(fs.readFileSync(stateFile, "utf8")).gate.cause, "backoff");
      } else {
        assert.deepEqual(calls.splice(0), ["profile", "usage"], label);
        assert.equal(first.value.provider.account, C.accountHash("home-uuid"), `${label}: .claude.json fallback`);
      }
      await quietly(() => C.claudeProvider(at(t0 + 30 * 60_000)));
      assert.deepEqual(calls.splice(0), ["usage"], `${label}: no profile retry inside the hour`);
      reply = profile;
      const later = await quietly(() => C.claudeProvider(at(t0 + 61 * 60_000)));
      assert.equal(later.value.provider.account, C.accountHash("profile-uuid"), label);
      assert.deepEqual(calls.splice(0), ["profile", "usage"], `${label}: asks again after the hour`);
    }

    // 확정된 거절(403)은 자격증명이 바뀔 때까지 기억해 다시 묻지 않는다
    const denied = (ms) => ({ loadCredentials: creds("r3"), fetchFn: fetchFn(() => new Response("{}", { status: 403 })), accountFile, now: () => ms });
    const r3 = await quietly(() => C.claudeProvider(denied(t0)));
    assert.equal(r3.value.provider.account, null);
    assert.deepEqual(calls.splice(0), ["profile", "usage"]);
    await quietly(() => C.claudeProvider(denied(t0 + 7 * 3600_000)));
    assert.deepEqual(calls.splice(0), ["usage"]);

    // 저장소가 설정 폴더와 다르면 .claude.json을 쓰지 않아 계정은 미상이다
    const separate = await quietly(() => C.claudeProvider({
      loadCredentials: creds("r4"),
      fetchFn: fetchFn(() => new Response("{}", { status: 403 })),
      readAccountUuid: () => C.readClaudeAccountUuid({ env: { CLAUDE_SECURESTORAGE_CONFIG_DIR: path.join(dir, "elsewhere") }, home: dir }),
      accountFile,
    }));
    assert.equal(separate.value.provider.account, null);
  });
});

test("T28 poll lease: another device's lease skips the request, failures fail open, gated holders still claim (D1)", async () => {
  await withTempDir(async (dir) => {
    const now = Date.parse("2026-09-15T00:00:00Z");
    const account = C.accountHash("acct-uuid");
    const generation = C.credentialKey("ref").slice(0, 8);
    const stateFile = path.join(dir, "state.json");
    const accountFile = path.join(dir, "account.json");
    const blockingState = JSON.stringify({
      gate: { account, credential: C.credentialKey("ref"), retryAt: now + 600_000, backoff: 300, cause: "backoff" },
      lastRequestAt: null,
      lastStatus: null,
    });
    const attempt = async ({ lease, known = true, state = null }) => {
      // 계정 캐시를 미리 채워 프로필 요청 없이 계정을 안다 (known=false면 확정된 미상)
      fs.writeFileSync(accountFile, JSON.stringify({ credential: C.credentialKey("ref"), account: known ? account : null }));
      if (state === null) fs.rmSync(stateFile, { force: true });
      else fs.writeFileSync(stateFile, state);
      let usage = 0;
      const claims = [];
      const { value, lines } = await quietly(() => C.claudeProvider({
        loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", refreshToken: "ref" } }),
        fetchFn: async (url) => {
          if (!String(url).endsWith("/usage")) throw new Error(`unexpected ${url}`);
          usage += 1;
          return new Response(usageBody(), { status: 200 });
        },
        claimLease: async (claimed) => {
          claims.push(claimed);
          if (lease instanceof Error) throw lease;
          return lease;
        },
        stateFile,
        accountFile,
        now: () => now,
      }));
      return { value, lines, usage, claims, state: fs.existsSync(stateFile) ? fs.readFileSync(stateFile, "utf8") : null };
    };

    const denied = await attempt({ lease: false });
    assert.deepEqual(denied.value, { provider: null, status: "shared" });
    assert.equal(denied.usage, 0);
    assert.deepEqual(denied.claims, [account]);
    assert.deepEqual(denied.lines, [`claude usage 요청 안 함 (shared) generation=${generation} account=${account}, 같은 계정을 다른 기기가 이번 주기에 조회합니다`]);
    assert.equal(denied.state, null, "a shared cycle writes no request state");

    // 거절은 게이트보다 먼저다, 게이트 상태는 그대로 둔다
    const deniedWhileGated = await attempt({ lease: false, state: blockingState });
    assert.equal(deniedWhileGated.value.status, "shared");
    assert.equal(deniedWhileGated.state, blockingState);

    // 게이트에 막힌 임대 보유 기기도 매 사이클 임대를 잡는다 (같은 사용자의 다른 기기가 같이 조용해진다)
    const gatedHolder = await attempt({ lease: true, state: blockingState });
    assert.match(gatedHolder.value.status, /^error:rate_limited;retry_at=\d+;deferred=1$/);
    assert.deepEqual(gatedHolder.claims, [account]);
    assert.equal(gatedHolder.usage, 0);

    // 허락, 그리고 JSON false가 아닌 모든 결과(예외 포함)는 허락으로 본다
    for (const [label, lease] of [["granted", true], ["rpc threw", new Error("timeout")], ["undefined", undefined], ["null", null], ["string false", "false"]]) {
      const r = await attempt({ lease });
      assert.equal(r.value.status, "ok", label);
      assert.equal(r.usage, 1, label);
      assert.deepEqual(r.claims, [account], label);
    }
    // 계정을 모르면 임대를 잡지 않고 평소처럼 수집한다
    const unknown = await attempt({ lease: false, known: false });
    assert.deepEqual(unknown.claims, []);
    assert.equal(unknown.usage, 1);
    assert.equal(unknown.value.status, "ok");
  });
});

test("T29 shared cycles keep this device's cached Claude row out of the payload but in the cache file (D4)", () => {
  const cached = [
    { id: "claude", account: "h1", collected_at: new Date().toISOString(), session: { percent: 4, resets_at: futureReset } },
    { id: "codex", account: "h2", collected_at: new Date().toISOString(), session: { percent: 5, resets_at: futureReset } },
  ];
  const shared = C.mergeCachedProviders({ providers: [], cached, statuses: { claude: "shared", codex: "ok" } });
  assert.deepEqual(shared.providers.map((p) => p.id), ["codex"]);
  assert.equal(shared.statuses.claude, "shared");
  // 캐시 파일에는 마지막 정상 Claude 값이 남는다 (관측 시각 그대로)
  assert.deepEqual(shared.cache.map((p) => p.id).sort(), ["claude", "codex"]);
  assert.equal(shared.cache.find((p) => p.id === "claude").collected_at, cached[0].collected_at);
  // 쿨다운 중이나 간격 보류(지난 결과 재사용)에는 예전처럼 캐시가 마지막 값을 올린다
  for (const status of ["error:rate_limited;retry_at=1;deferred=1", "ok"]) {
    const r = C.mergeCachedProviders({ providers: [], cached, statuses: { claude: status } });
    assert.deepEqual(r.providers.map((p) => p.id).sort(), ["claude", "codex"], status);
    assert.equal(r.cache, r.providers, status);
    assert.equal(r.statuses.claude, status);
  }
});

test("T30 claimPollLease posts token, provider and account, and only JSON false denies", async () => {
  const mode = { url: "https://x.supabase.co", anon: "anon", token: "device" };
  let seen = null;
  const denied = await C.claimPollLease(mode, "claude", "0123456789ab", {
    fetchFn: async (url, options) => {
      seen = { url: String(url), options };
      return new Response("false", { status: 200 });
    },
  });
  assert.equal(denied, false);
  assert.equal(seen.url, "https://x.supabase.co/rest/v1/rpc/charge_claim_poll");
  assert.equal(seen.options.method, "POST");
  assert.deepEqual(JSON.parse(seen.options.body), { p_token: "device", p_provider: "claude", p_account: "0123456789ab" });
  assert.equal(seen.options.headers.apikey, "anon");
  assert.ok(seen.options.signal);
  assert.equal(await C.claimPollLease(mode, "claude", "a", { fetchFn: async () => new Response("true", { status: 200 }) }), true);
  for (const [label, fetchFn] of [
    ["old server 404 PGRST202", async () => new Response('{"code":"PGRST202"}', { status: 404 })],
    ["500", async () => new Response("{}", { status: 500 })],
    ["network", async () => { throw new TypeError("fetch failed"); }],
    ["timeout", async () => { throw Object.assign(new Error("aborted"), { name: "TimeoutError" }); }],
    ["not json", async () => new Response("<html>", { status: 200 })],
    ["null", async () => new Response("null", { status: 200 })],
    ["string false", async () => new Response('"false"', { status: 200 })],
  ]) {
    assert.equal(await C.claimPollLease(mode, "claude", "a", { fetchFn }), true, label);
  }
  // 계정 미상이나 미페어링이면 묻지 않고 허락
  const never = async () => { throw new Error("must not call"); };
  assert.equal(await C.claimPollLease(mode, "claude", null, { fetchFn: never }), true);
  assert.equal(await C.claimPollLease(null, "claude", "a", { fetchFn: never }), true);
});

test("T31 health annotator preserves parameters, keeps one streak across kinds and stores the latest kind", () => {
  const start = Date.parse("2026-09-15T00:00:00Z");
  const first = C.advanceCollectionHealth({ claude: "error:rate_limited;retry_at=1789430400", codex: "ok", _collector: "0.2.0" }, {}, start);
  assert.equal(first.statuses.claude, `error:rate_limited;retry_at=1789430400;failures=1;since=${start / 1000}`);
  assert.equal(first.statuses.codex, "ok");
  assert.equal(first.statuses._collector, "0.2.0");
  assert.deepEqual(first.failures.claude, { count: 1, since: start, lastAttempt: start, kind: "error:rate_limited" });
  assert.equal("_collector" in first.failures, false);

  const second = C.advanceCollectionHealth({ claude: "auth_expired:revoked;failures=9;since=1;extra=x" }, first.failures, start + 5 * 60_000);
  // 기존 failures/since 파라미터는 새 값으로 바뀌고 중복되지 않는다, 다른 파라미터는 앞에 그대로
  assert.equal(second.statuses.claude, `auth_expired:revoked;extra=x;failures=2;since=${start / 1000}`);
  assert.equal(second.failures.claude.kind, "auth_expired:revoked");
  // 12분 연속성 규칙은 그대로
  const gap = C.advanceCollectionHealth({ claude: "error" }, second.failures, start + 5 * 60_000 + 12 * 60_000 + 1);
  assert.match(gap.statuses.claude, /;failures=1;/);
  // shared, stale, ok는 연속 실패가 아니다
  assert.deepEqual(C.advanceCollectionHealth({ claude: "shared" }, second.failures, start + 10 * 60_000), { statuses: { claude: "shared" }, failures: {} });
  // D13: 요청 간격 때문에 미룬 사이클(held)은 연속 실패를 늘리지도 끊지도 않는다
  const held = C.advanceCollectionHealth({ claude: "error:rate_limited;retry_at=1;deferred=1" }, second.failures, start + 7 * 60_000, ["claude"]);
  assert.equal(held.statuses.claude, `error:rate_limited;retry_at=1;deferred=1;failures=2;since=${start / 1000}`);
  assert.deepEqual(held.failures.claude, second.failures.claude);
  // 이미 끊긴 연속 실패는 이어 붙이지 않는다, held인 정상 상태도 그대로
  assert.deepEqual(C.advanceCollectionHealth({ claude: "error" }, second.failures, start + 60 * 60_000, ["claude"]), { statuses: { claude: "error" }, failures: {} });
  assert.deepEqual(C.advanceCollectionHealth({ claude: "ok" }, second.failures, start + 7 * 60_000, ["claude"]), { statuses: { claude: "ok" }, failures: {} });
});

test("T32 cached windows without a reset time expire after their window length", () => {
  const now = Date.parse("2026-09-15T12:00:00Z");
  const ago = (minutes) => new Date(now - minutes * 60_000).toISOString();
  const provider = (collected_at) => ({
    id: "claude",
    account: "h1",
    collected_at,
    session: { percent: 0, resets_at: null, window_minutes: 300 },
    weekly: { percent: 12, resets_at: null, window_minutes: 10_080 },
    extras: [{ name: "Opus", window: { percent: 3, resets_at: null, window_minutes: 10_080 } }],
  });

  const recent = C.sanitizeCachedProvider(provider(ago(299)), now);
  assert.equal(recent.session.percent, 0);
  assert.equal(recent.weekly.percent, 12);

  const hoursOld = C.sanitizeCachedProvider(provider(ago(301)), now);
  assert.equal(hoursOld.session, null); // 세션 창(300분)이 지났다
  assert.equal(hoursOld.weekly.percent, 12);
  assert.equal(hoursOld.extras.length, 1);

  assert.equal(C.sanitizeCachedProvider(provider(ago(10_081)), now), null); // 주간 창까지 지나면 복원할 게 없다
  // window_minutes가 없으면 슬롯 기본값(세션 300, 주간 10080)
  const noMinutes = C.sanitizeCachedProvider({ id: "x", collected_at: ago(400), session: { percent: 1, resets_at: null }, weekly: { percent: 2, resets_at: null } }, now);
  assert.equal(noMinutes.session, null);
  assert.equal(noMinutes.weekly.percent, 2);
  // 관측 시각을 모르면 리셋 미상 창의 나이를 증명할 수 없어 버린다, 리셋 시각을 아는 창은 예전처럼 유지
  const unknownAge = C.sanitizeCachedProvider({ id: "x", session: { percent: 1, resets_at: null }, weekly: { percent: 2, resets_at: futureReset } }, now);
  assert.equal(unknownAge.session, null);
  assert.equal(unknownAge.weekly.percent, 2);
  const knownReset = C.sanitizeCachedProvider({ ...provider(ago(20_000)), session: { percent: 9, resets_at: futureReset, window_minutes: 300 } }, now);
  assert.equal(knownReset.session.percent, 9);
});

test("T33 codex snapshot replay drops reset-less windows older than their window", async () => {
  const snapshotAt = new Date(Date.now() - 6 * 3600_000).toISOString();
  const r = await C.codexProvider({
    hasCodex: () => true,
    loadAuth: () => ({ plan: "Pro", account: "h1" }),
    liveWindows: async () => null,
    snapshotWindows: () => ({
      session: { percent: 0, resets_at: null, window_minutes: 300 },
      weekly: { percent: 20, resets_at: null, window_minutes: 10_080 },
      collected_at: snapshotAt,
    }),
  });
  assert.equal(r.status, "stale");
  assert.equal(r.provider.session, null);
  assert.equal(r.provider.weekly.percent, 20);
});

test("T34 collect_status carries the collector version under the reserved _collector key", () => {
  const version = require("./package.json").version;
  assert.equal(C.PACKAGE_VERSION, version);
  assert.deepEqual(C.withCollectorVersion({ claude: "ok" }), { claude: "ok", _collector: version });
  assert.equal(C.withCollectorVersion(null), null); // 수집이 통째로 실패한 미상은 그대로
  assert.deepEqual(C.withCollectorVersion({ claude: "ok" }, null), { claude: "ok" }); // 버전을 못 읽으면 생략
});

test("T35 local request spacing: within 240 s of the last request, repeat its status without a request (D13)", async () => {
  await withTempDir(async (dir) => {
    const stateFile = path.join(dir, "state.json");
    const accountFile = path.join(dir, "account.json");
    const account = C.accountHash("acct");
    fs.writeFileSync(accountFile, JSON.stringify({ credential: C.credentialKey("ref"), account }));
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    let reply = () => new Response(usageBody(), { status: 200 });
    let usage = 0;
    const claims = [];
    const run = (ms) => quietly(() => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", refreshToken: "ref" } }),
      fetchFn: async () => { usage += 1; return reply(); },
      claimLease: async () => { claims.push(ms); return true; },
      stateFile,
      accountFile,
      now: () => ms,
    }));

    const first = await run(t0);
    assert.equal(first.value.status, "ok");
    assert.equal(usage, 1);
    assert.deepEqual(JSON.parse(fs.readFileSync(stateFile, "utf8")), { gate: null, lastRequestAt: t0, lastStatus: "ok", lastToken: C.credentialKey("tok"), leaseAt: t0 });

    // 잠에서 깬 launchd가 몰아서 띄운 실행: 임대는 갱신하고, 요청은 보내지 않고, 지난 결과를 싣는다
    const coalesced = await run(t0 + 30_000);
    assert.deepEqual(coalesced.value, { provider: null, status: "ok", held: true });
    assert.equal(usage, 1);
    assert.deepEqual(claims, [t0, t0 + 30_000], "a throttled lease holder still renews its lease");
    assert.deepEqual(coalesced.lines, [`claude usage 요청 안 함 (spacing) last_request=2026-09-15T00:00:00.000Z generation=${C.credentialKey("ref").slice(0, 8)} account=${account}`]);
    // 캐시 폴백이 마지막 정상 값을 올린다 (상태는 ok 그대로)
    const cached = [{ id: "claude", account, collected_at: new Date(t0).toISOString(), session: { percent: 4, resets_at: futureReset } }];
    const merged = C.mergeCachedProviders({ providers: [], cached, statuses: { claude: coalesced.value.status } });
    assert.deepEqual(merged.providers.map((p) => p.id), ["claude"]);
    assert.equal(merged.statuses.claude, "ok");

    // 정확히 240초면 다시 묻는다. HTTP 오류도 요청 시도로 기록된다
    reply = () => new Response("{}", { status: 500 });
    const failed = await run(t0 + 240_000);
    assert.equal(failed.value.status, "error");
    assert.equal(usage, 2);
    const heldError = await run(t0 + 300_000);
    assert.deepEqual(heldError.value, { provider: null, status: "error", held: true });
    assert.equal(usage, 2);

    // 연속 실패는 늘지도 끊기지도 않는다 (collectProviders가 held로 넘긴다)
    const health = path.join(dir, "health.json");
    const since = (t0 + 240_000) / 1000;
    assert.equal(C.recordCollectionHealth({ claude: failed.value.status }, { file: health, now: t0 + 240_000 }).claude, `error;failures=1;since=${since}`);
    assert.equal(C.recordCollectionHealth({ claude: heldError.value.status }, { file: health, now: t0 + 300_000, held: ["claude"] }).claude, `error;failures=1;since=${since}`);
    assert.equal(JSON.parse(fs.readFileSync(health, "utf8")).failures.claude.lastAttempt, t0 + 240_000);
    assert.equal(C.recordCollectionHealth({ claude: "error" }, { file: health, now: t0 + 540_000 }).claude, `error;failures=2;since=${since}`);

    // rate_limited 결과를 되풀이할 때는 retry_at을 두고 deferred=1을 붙인다
    fs.writeFileSync(stateFile, JSON.stringify({ gate: null, lastRequestAt: t0 + 600_000, lastStatus: "error:rate_limited;retry_at=1789431000" }));
    const heldLimited = await run(t0 + 700_000);
    assert.equal(heldLimited.value.status, "error:rate_limited;retry_at=1789431000;deferred=1");
    assert.equal(usage, 2);

    // 시계가 뒤로 가 마지막 요청이 미래로 보이거나, 기록이 깨졌으면 막지 않는다
    reply = () => new Response(usageBody(), { status: 200 });
    fs.writeFileSync(stateFile, JSON.stringify({ gate: null, lastRequestAt: t0 + 10 * 3600_000, lastStatus: "ok" }));
    await run(t0 + 800_000);
    assert.equal(usage, 3);
    for (const broken of [{ lastRequestAt: t0 + 790_000, lastStatus: "ok; rm -rf /" }, { lastRequestAt: "soon", lastStatus: "ok" }, { lastRequestAt: t0 + 790_000 }]) {
      fs.writeFileSync(stateFile, JSON.stringify({ gate: null, ...broken }));
      const before = usage;
      await run(t0 + 800_000);
      assert.equal(usage, before + 1, JSON.stringify(broken));
    }
  });
});

test("T36 a cycle without credentials logs exactly one line, and deferred marks only rate-limited repeats (D7)", async () => {
  for (const detected of [true, false]) {
    const { value, lines } = await quietly(() => C.claudeProvider({
      hasClaude: () => detected,
      loadCredentials: async () => { throw new Error("none"); },
      fetchFn: async () => { throw new Error("must not request"); },
    }));
    assert.equal(value.status, detected ? "error:credentials_missing" : null);
    assert.equal(lines.length, 1, lines.join("\n"));
    assert.ok(lines[0].startsWith("claude usage 요청 안 함 (no-credentials), "), lines[0]);
  }
  assert.equal(C.deferredStatus("error:rate_limited;retry_at=5"), "error:rate_limited;retry_at=5;deferred=1");
  assert.equal(C.deferredStatus("error:rate_limited;deferred=1;retry_at=5"), "error:rate_limited;retry_at=5;deferred=1");
  for (const status of ["ok", "error", "auth_expired", "auth_expired:revoked", "stale"]) assert.equal(C.deferredStatus(status), status);
});

test("T37 collect.js --self-test loads every runtime module and exits without network, processes or state (D9)", () => {
  const { spawnSync } = require("node:child_process");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "charge-self-test-"));
  try {
    const appDir = path.join(root, ".charge", "app");
    fs.mkdirSync(appDir, { recursive: true });
    const pkg = require("./package.json");
    for (const name of [...pkg.files.filter((file) => file.endsWith(".js")), "package.json"]) {
      fs.copyFileSync(path.join(__dirname, name), path.join(appDir, name));
    }
    // 설치 직후 점검 중에는 진행 표시가 있는 게 정상이다, 자체 점검은 되돌리지 않는다
    const marker = JSON.stringify({ backup: path.join(root, "missing-backup"), files: ["collect.js"], added: [] });
    fs.writeFileSync(path.join(appDir, ".update-in-progress.json"), marker);
    const preload = path.join(root, "no-io.js");
    fs.writeFileSync(preload, [
      'const cp = require("node:child_process");',
      'for (const name of ["exec", "execFile", "execFileSync", "execSync", "spawn", "spawnSync", "fork"]) cp[name] = () => { throw new Error("child process during self-test: " + name); };',
      'globalThis.fetch = async () => { throw new Error("network during self-test"); };',
    ].join(String.fromCharCode(10)));
    const env = { ...process.env, HOME: root, USERPROFILE: root, CHARGE_HOME: path.join(root, ".charge") };
    const before = fs.readdirSync(appDir).sort();
    const run = spawnSync(process.execPath, ["-r", preload, path.join(appDir, "collect.js"), "--self-test"], { encoding: "utf8", env, timeout: 30_000 });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout.trim(), `charge-connect self-test ok ${pkg.version}`);
    assert.deepEqual(fs.readdirSync(appDir).sort(), before, "no state file is written");
    assert.equal(fs.readFileSync(path.join(appDir, ".update-in-progress.json"), "utf8"), marker, "the marker is left alone");
    assert.deepEqual(fs.readdirSync(path.join(root, ".charge")), ["app"]);

    // 런타임 모듈 하나가 불러오는 순간 죽으면 자체 점검이 실패한다
    fs.writeFileSync(path.join(appDir, "cli.js"), 'throw new Error("broken cli");');
    const broken = spawnSync(process.execPath, [path.join(appDir, "collect.js"), "--self-test"], { encoding: "utf8", env, timeout: 30_000 });
    assert.notEqual(broken.status, 0);
    assert.match(broken.stderr, /broken cli/);
    assert.equal(broken.stdout.includes("self-test ok"), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("T38 a profile 429 gates the account .claude.json reports, so another known account still requests (D12)", async () => {
  await withTempDir(async (dir) => {
    const stateFile = path.join(dir, "state.json");
    const accountFile = path.join(dir, "account.json");
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    let now = t0;
    let local = "uuid-a";
    let localReads = 0;
    let profile = () => new Response("{}", { status: 429, headers: { "Retry-After": "3600" } });
    const calls = [];
    const run = (refreshToken) => quietly(() => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: `access-${refreshToken}`, refreshToken } }),
      fetchFn: async (url) => {
        calls.push(String(url).split("/").pop());
        return String(url).endsWith("/profile") ? profile() : new Response(usageBody(), { status: 200 });
      },
      readAccountUuid: async () => { localReads += 1; return local; },
      stateFile,
      accountFile,
      now: () => now,
    }));

    // 프로필 429: 게이트는 .claude.json이 알려준 계정(A)으로 걸린다. .claude.json은 한 사이클에 한 번만 읽는다
    const first = await run("r1");
    const retryAt = t0 + 3_660_000;
    assert.deepEqual(calls.splice(0), ["profile"]);
    assert.equal(localReads, 1);
    assert.equal(first.value.status, `error:rate_limited;retry_at=${retryAt / 1000};deferred=1`);
    assert.deepEqual(JSON.parse(fs.readFileSync(stateFile, "utf8")).gate, {
      account: C.accountHash("uuid-a"), credential: C.credentialKey("r1"), retryAt, backoff: 0, cause: "retry-after",
    });

    // 같은 계정(A)은 토큰이 바뀌어도 서버가 준 기한까지 막힌다
    now = t0 + 300_000;
    profile = () => new Response(JSON.stringify({ account: { uuid: "uuid-a" } }), { status: 200 });
    const same = await run("r2");
    assert.deepEqual(calls.splice(0), []);
    assert.equal(same.value.status, `error:rate_limited;retry_at=${retryAt / 1000};deferred=1`);

    // 확실히 다른 계정(B)은 그 계정의 한도가 아니다: usage를 보내고, 200이면 게이트를 지운다
    now = t0 + 600_000;
    local = "uuid-b";
    const other = await run("r3");
    assert.deepEqual(calls.splice(0), ["usage"]);
    assert.equal(other.value.status, "ok");
    assert.equal(other.value.provider.account, C.accountHash("uuid-b"));
    assert.equal(JSON.parse(fs.readFileSync(stateFile, "utf8")).gate, null);
  });
});

test("T39 a lease holder whose requests keep failing stops renewing, so a healthy device of the same user takes over (D1)", async () => {
  await withTempDir(async (dir) => {
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    let clock = t0;
    const account = C.accountHash("shared-acct");
    // 서버 charge_claim_poll과 같은 규칙: 임대가 없거나, 끝났거나, 이 기기의 것이면 잡고 270초 동안 쥔다
    let lease = null;
    const device = (name, reply) => {
      const stateFile = path.join(dir, `${name}-state.json`);
      const accountFile = path.join(dir, `${name}-account.json`);
      fs.writeFileSync(accountFile, JSON.stringify({ credential: C.credentialKey(`refresh-${name}`), account }));
      const d = { usage: 0, claims: 0, access: `access-${name}`, reply, statuses: [], lines: [] };
      d.run = async () => {
        const { value, lines } = await quietly(() => C.claudeProvider({
          loadCredentials: async () => ({ claudeAiOauth: { accessToken: d.access, refreshToken: `refresh-${name}`, expiresAt: clock + 6 * 3600_000 } }),
          fetchFn: async (url) => {
            if (!String(url).endsWith("/usage")) throw new Error(`unexpected ${url}`);
            d.usage += 1;
            return d.reply();
          },
          claimLease: async () => {
            d.claims += 1;
            if (lease && lease.expiresAt > clock && lease.device !== name) return false;
            lease = { device: name, expiresAt: clock + 270_000 };
            return true;
          },
          stateFile,
          accountFile,
          now: () => clock,
        }));
        d.statuses.push(value.status);
        d.lines = lines;
        return value;
      };
      return d;
    };
    // 두 기기의 5분 주기는 offset(기본 30초)만큼 어긋나 있다
    const cycle = async (index, first, second, offset = 30_000) => {
      clock = t0 + index * 300_000;
      await first.run();
      clock += offset;
      await second.run();
    };
    const ok = () => new Response(usageBody(), { status: 200 });

    // 1. 서버가 거절한 토큰(로컬 만료 시각은 미래): 거절된 뒤로는 요청도 임대도 없고, 같은 사용자의 다른 기기가 이어받는다
    const x = device("x", () => new Response('{"error":{"message":"Invalid bearer token"}}', { status: 401 }));
    const y = device("y", ok);
    for (let i = 0; i < 12; i += 1) await cycle(i, x, y);
    assert.equal(x.usage, 1);
    assert.equal(x.claims, 1, "only the first cycle claims the lease");
    assert.deepEqual([...new Set(x.statuses)], ["auth_expired:revoked"]);
    assert.deepEqual(y.statuses, ["shared", ...Array(11).fill("ok")]);
    assert.equal(y.usage, 11);
    assert.equal(x.lines.length, 1, x.lines.join("\n"));
    const prefix = `claude usage 요청 안 함 (rejected) status=auth_expired:revoked last_request=2026-09-15T00:00:00.000Z generation=${C.credentialKey("refresh-x").slice(0, 8)} account=${account}, `;
    assert.ok(x.lines[0].startsWith(prefix), x.lines[0]);
    assert.match(x.lines[0], /\/login/);
    assert.equal(x.lines[0].includes("access-x"), false);

    // 한 시간 뒤에는 임대 없이 한 번만 다시 확인한다 (일시적인 401일 수 있다). 다른 기기의 임대는 그대로다
    await cycle(12, x, y);
    assert.equal(x.usage, 2);
    assert.equal(x.claims, 1);
    assert.equal(y.statuses.at(-1), "ok");

    // 토큰이 바뀌면(Claude Code를 열면) 바로 묻고 임대도 다시 잡는다
    x.access = "access-x-refreshed";
    x.reply = ok;
    await cycle(13, x, y);
    assert.equal(x.usage, 3);
    assert.equal(x.claims, 2);
    assert.equal(x.statuses.at(-1), "ok");
    assert.equal(y.statuses.at(-1), "shared");

    // 2. 429가 아닌 다른 실패(5xx): 요청은 매 사이클 보내고 임대는 한 사이클 걸러 잡는다. 거른 사이클에 멀쩡한 기기(q)가
    //    넘겨받으면, 실패하던 기기(p)는 다음 임대 확인에서 거절되어 shared로 물러난다 (둘이 매 사이클 같이 묻지 않는다).
    //    q의 주기는 60초 늦다 (30초면 q의 임대가 p의 주기 시각에 딱 끝나 서로 번갈아 넘겨받는다)
    lease = null;
    const p = device("p", () => new Response("{}", { status: 500 }));
    const q = device("q", ok);
    for (let i = 20; i < 25; i += 1) await cycle(i, p, q, 60_000);
    assert.deepEqual(p.statuses, ["error", "error", "shared", "shared", "shared"]);
    assert.equal(p.usage, 2);
    assert.equal(p.claims, 4, "the failing device skips the claim once, then keeps asking and is denied");
    assert.deepEqual(q.statuses, ["shared", "ok", "ok", "ok", "ok"]);
    assert.equal(q.usage, 4);
    assert.equal(p.lines.join("\n").includes("(shared)"), true);

    // 3. 같은 사용자의 다른 기기가 없으면 실패하는 기기가 매 사이클 요청해 복구를 바로 알아챈다. 임대는 한 사이클 걸러 잡는다
    lease = null;
    const solo = device("solo", () => new Response("{}", { status: 503 }));
    for (let i = 30; i < 34; i += 1) {
      clock = t0 + i * 300_000;
      await solo.run();
    }
    assert.deepEqual(solo.statuses, ["error", "error", "error", "error"]);
    assert.equal(solo.usage, 4);
    assert.equal(solo.claims, 2);
    // 복구하면 다시 매 사이클 임대를 잡는다
    solo.reply = ok;
    for (let i = 34; i < 37; i += 1) {
      clock = t0 + i * 300_000;
      await solo.run();
    }
    assert.deepEqual(solo.statuses.slice(4), ["ok", "ok", "ok"]);
    assert.equal(solo.usage, 7);
    assert.equal(solo.claims, 5);
  });
});

test("T40 overlapping runs on one device send one usage request, and a 200 does not clear a gate another run just set (D13)", async () => {
  await withTempDir(async (dir) => {
    const stateFile = path.join(dir, "state.json");
    const accountFile = path.join(dir, "account.json");
    const account = C.accountHash("acct");
    fs.writeFileSync(accountFile, JSON.stringify({ credential: C.credentialKey("ref"), account }));
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    let usage = 0;
    let release;
    let onRequest = () => {};
    const run = () => quietly(() => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", refreshToken: "ref" } }),
      fetchFn: async () => {
        usage += 1;
        onRequest();
        // 첫 실행의 응답은 두 번째 실행이 끝날 때까지 오지 않는다
        await new Promise((resolve) => { release = resolve; });
        return new Response(usageBody(), { status: 200 });
      },
      claimLease: async () => true,
      stateFile,
      accountFile,
      now: () => t0,
    }));

    // 1. 이 기기의 첫 요청(페어링 직후 스케줄러의 첫 실행과 CLI의 첫 수집이 겹친다): 뒤의 실행은 요청 없이 shared로 쉰다
    const first = run();
    while (!release) await new Promise((resolve) => setImmediate(resolve));
    const second = await run();
    assert.equal(usage, 1);
    assert.deepEqual(second.value, { provider: null, status: "shared", held: true });
    assert.equal(second.lines.length, 1, second.lines.join("\n"));
    assert.ok(second.lines[0].startsWith("claude usage 요청 안 함 (spacing) last_request=2026-09-15T00:00:00.000Z"), second.lines[0]);
    release();
    assert.equal((await first).value.status, "ok");
    assert.equal(JSON.parse(fs.readFileSync(stateFile, "utf8")).lastStatus, "ok");

    // 2. 지난 결과가 있으면 겹친 실행은 그 결과를 되풀이한다. 응답을 기다리는 동안 다른 실행이 429 게이트를 걸었으면
    //    먼저 시작한 실행의 200이 그 게이트를 지우지 않는다
    const later = t0 + 600_000;
    fs.writeFileSync(stateFile, JSON.stringify({ gate: null, lastRequestAt: later - 300_000, lastStatus: "error", lastToken: C.credentialKey("tok") }));
    const gate = { account, credential: C.credentialKey("ref"), retryAt: later + 3_660_000, backoff: 0, cause: "retry-after" };
    release = null;
    onRequest = () => {
      const saved = JSON.parse(fs.readFileSync(stateFile, "utf8"));
      assert.equal(saved.lastRequestAt, later, "the request time is written before the response");
      assert.equal(saved.lastStatus, "error", "the previous result is kept until the response");
      fs.writeFileSync(stateFile, JSON.stringify({ ...saved, gate }));
    };
    const runLater = () => quietly(() => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", refreshToken: "ref" } }),
      fetchFn: async () => {
        usage += 1;
        onRequest();
        await new Promise((resolve) => { release = resolve; });
        return new Response(usageBody(), { status: 200 });
      },
      claimLease: async () => true,
      stateFile,
      accountFile,
      now: () => later,
    }));
    const pending = runLater();
    while (!release) await new Promise((resolve) => setImmediate(resolve));
    onRequest = () => {};
    const overlapped = await runLater();
    assert.equal(usage, 2);
    assert.equal(overlapped.value.status, `error:rate_limited;retry_at=${gate.retryAt / 1000};deferred=1`, "the concurrent gate is honoured");
    release();
    assert.equal((await pending).value.status, "ok");
    const saved = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    assert.deepEqual(saved.gate, gate);
    assert.equal(saved.lastStatus, "ok");
  });
});

test("T41 a profile probe during a backoff defers usage only when it reports the gated account (D12)", async () => {
  await withTempDir(async (dir) => {
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    for (const [label, uuid, expected] of [["same account", "acct-a", ["profile"]], ["another account", "acct-b", ["profile", "usage"]]]) {
      const stateFile = path.join(dir, `${label}-state.json`);
      const accountFile = path.join(dir, `${label}-account.json`);
      fs.writeFileSync(stateFile, JSON.stringify({
        gate: { account: C.accountHash("acct-a"), credential: C.credentialKey("r1"), retryAt: t0 + 120_000, backoff: 300, cause: "backoff" },
        lastRequestAt: t0 - 180_000,
        lastStatus: "error:rate_limited;retry_at=1789430520",
        lastToken: C.credentialKey("access-r1"),
      }));
      const calls = [];
      const { value } = await quietly(() => C.claudeProvider({
        loadCredentials: async () => ({ claudeAiOauth: { accessToken: "access-r2", refreshToken: "r2" } }),
        fetchFn: async (url) => {
          calls.push(String(url).split("/").pop());
          return String(url).endsWith("/profile")
            ? new Response(JSON.stringify({ account: { uuid } }), { status: 200 })
            : new Response(usageBody(), { status: 200 });
        },
        stateFile,
        accountFile,
        now: () => t0 + 60_000,
      }));
      assert.deepEqual(calls, expected, label);
      assert.equal(value.status, label === "same account" ? `error:rate_limited;retry_at=${(t0 + 120_000) / 1000};deferred=1` : "ok", label);
    }
  });
});

test("T42 two collector processes of one device send exactly one usage request (interprocess spacing lock, D13)", async () => {
  const http = require("node:http");
  const { spawn } = require("node:child_process");
  await withTempDir(async (dir) => {
    const stateFile = path.join(dir, "state.json");
    const accountFile = path.join(dir, "account.json");
    fs.writeFileSync(accountFile, JSON.stringify({ credential: C.credentialKey("ref"), account: C.accountHash("acct") }));
    // localhost의 가짜 usage 서버: 요청 수를 세고, 응답은 늦춰 다른 프로세스가 그사이 판단하게 한다
    const hits = [];
    const server = http.createServer((req, res) => {
      hits.push({ url: req.url, at: Date.now(), authorization: req.headers.authorization });
      setTimeout(() => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(usageBody());
      }, 300);
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = server.address().port;
    // 두 프로세스는 임대를 잡은 뒤(둘 다 사이클 첫머리의 빈 상태를 이미 읽었다) 서로를 기다렸다가 동시에 판단으로 들어간다.
    // 잠금이 없으면 둘 다 빈 기록을 보고 둘 다 묻는다 (검토에서 재현된 같은 시각의 usage 요청 두 건).
    const child = path.join(dir, "child.js");
    fs.writeFileSync(child, [
      'const fs = require("node:fs");',
      'const path = require("node:path");',
      `const C = require(${JSON.stringify(path.join(__dirname, "collect.js"))});`,
      "const [tag, other] = process.argv.slice(2);",
      `const dir = ${JSON.stringify(dir)};`,
      "const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));",
      "C.claudeProvider({",
      '  loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", refreshToken: "ref" } }),',
      `  fetchFn: (url, init) => fetch("http://127.0.0.1:${port}/usage?tag=" + tag, init),`,
      "  claimLease: async () => {",
      '    fs.writeFileSync(path.join(dir, "ready-" + tag), "");',
      "    const deadline = Date.now() + 10_000;",
      '    while (!fs.existsSync(path.join(dir, "ready-" + other))) {',
      '      if (Date.now() > deadline) throw new Error("barrier timeout");',
      "      await sleep(2);",
      "    }",
      "    return true;",
      "  },",
      `  stateFile: ${JSON.stringify(stateFile)},`,
      `  accountFile: ${JSON.stringify(accountFile)},`,
      "}).then((result) => {",
      '  console.log("RESULT " + JSON.stringify(result));',
      "});",
    ].join("\n"));
    const run = (tag, other) => new Promise((resolve) => {
      const proc = spawn(process.execPath, [child, tag, other], { env: { ...process.env, NODE_OPTIONS: "" }, windowsHide: true });
      let stdout = "";
      let stderr = "";
      proc.stdout.on("data", (chunk) => { stdout += chunk; });
      proc.stderr.on("data", (chunk) => { stderr += chunk; });
      proc.on("close", (status) => resolve({ tag, status, stdout, stderr }));
    });
    try {
      const [a, b] = await Promise.all([run("a", "b"), run("b", "a")]);
      for (const proc of [a, b]) assert.equal(proc.status, 0, `${proc.tag}: ${proc.stderr}`);
      const results = [a, b].map((proc) => {
        const line = proc.stdout.split(/\r?\n/).find((l) => l.startsWith("RESULT "));
        assert.ok(line, `${proc.tag}: ${proc.stdout}\n${proc.stderr}`);
        return { tag: proc.tag, output: `${proc.stdout}${proc.stderr}`, ...JSON.parse(line.slice("RESULT ".length)) };
      });
      assert.equal(hits.length, 1, `usage requests: ${JSON.stringify(hits)}`);
      assert.equal(hits[0].authorization, "Bearer tok");
      const asked = results.filter((r) => r.status === "ok" && r.provider);
      const yielded = results.filter((r) => r.held === true);
      assert.equal(asked.length, 1, JSON.stringify(results));
      assert.equal(yielded.length, 1, JSON.stringify(results));
      assert.equal(yielded[0].provider, null);
      // 물러난 실행은 잠금에 막혔거나(reason=lock) 잠금을 받은 뒤 예약을 봤다 (spacing). 결과가 아직 없으면 shared, 이미 왔으면 그 결과
      assert.ok(["shared", "ok"].includes(yielded[0].status), JSON.stringify(yielded[0]));
      assert.match(yielded[0].output, /claude usage 요청 안 함 \(spacing\)/);
      assert.equal(yielded[0].output.split("요청 안 함").length - 1, 1, yielded[0].output);
      assert.equal(asked[0].output.includes("요청 안 함"), false, asked[0].output);
      // 잠금은 둘 다 풀었고 예약은 요청을 보낸 실행의 결과로 마무리됐다
      assert.equal(fs.existsSync(`${stateFile}.lock`), false);
      const saved = JSON.parse(fs.readFileSync(stateFile, "utf8"));
      assert.equal(saved.lastStatus, "ok");
      assert.equal(saved.lastToken, C.credentialKey("tok"));
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });
});

test("T43 spacing lock: a live holder makes the run yield like spacing, dead or old locks are taken over, fs errors fall back once", async () => {
  const { spawnSync } = require("node:child_process");
  await withTempDir(async (dir) => {
    const stateFile = path.join(dir, "state.json");
    const lockFile = `${stateFile}.lock`;
    const accountFile = path.join(dir, "account.json");
    const account = C.accountHash("acct");
    const generation = C.credentialKey("ref").slice(0, 8);
    fs.writeFileSync(accountFile, JSON.stringify({ credential: C.credentialKey("ref"), account }));
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    let usage = 0;
    const claims = [];
    const run = (ms, file = stateFile) => quietly(() => C.claudeProvider({
      loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", refreshToken: "ref" } }),
      fetchFn: async () => { usage += 1; return new Response(usageBody(), { status: 200 }); },
      claimLease: async () => { claims.push(ms); return true; },
      stateFile: file,
      accountFile,
      now: () => ms,
    }));

    // 1. 살아 있는 다른 실행이 잡고 있다 (이 테스트 프로세스의 pid): 임대는 갱신하고, 요청 없이, 기록이 없으니 shared로 물러난다
    fs.writeFileSync(lockFile, JSON.stringify({ pid: process.pid, at: t0 }));
    const held = await run(t0);
    assert.deepEqual(held.value, { provider: null, status: "shared", held: true });
    assert.equal(usage, 0);
    assert.deepEqual(claims, [t0], "a run blocked by the lock still renews its lease");
    assert.deepEqual(held.lines, [`claude usage 요청 안 함 (spacing) reason=lock generation=${generation} account=${account}`]);
    assert.equal(fs.existsSync(stateFile), false, "nothing is written while another run decides");
    assert.equal(fs.readFileSync(lockFile, "utf8"), JSON.stringify({ pid: process.pid, at: t0 }), "someone else's lock is left alone");
    // 지난 결과가 있으면 그 결과를 되풀이한다 (rate_limited에는 deferred=1)
    fs.writeFileSync(stateFile, JSON.stringify({ gate: null, lastRequestAt: t0 - 100_000, lastStatus: "ok", lastToken: C.credentialKey("tok") }));
    const heldOk = await run(t0 + 1_000);
    assert.deepEqual(heldOk.value, { provider: null, status: "ok", held: true });
    assert.deepEqual(heldOk.lines, [`claude usage 요청 안 함 (spacing) reason=lock last_request=${new Date(t0 - 100_000).toISOString()} generation=${generation} account=${account}`]);
    fs.writeFileSync(stateFile, JSON.stringify({ gate: null, lastRequestAt: t0 - 100_000, lastStatus: "error:rate_limited;retry_at=1789431000", lastToken: C.credentialKey("tok") }));
    const heldLimited = await run(t0 + 2_000);
    assert.equal(heldLimited.value.status, "error:rate_limited;retry_at=1789431000;deferred=1");
    assert.equal(usage, 0);
    fs.rmSync(stateFile, { force: true });

    // 2. 60초가 지난 잠금은 만든 실행이 살아 있어도 넘겨받는다, 요청 뒤에는 잠금이 풀려 있다
    fs.writeFileSync(lockFile, JSON.stringify({ pid: process.pid, at: t0 - C.REQUEST_LOCK_STALE_MS - 1 }));
    const takenOver = await run(t0);
    assert.equal(takenOver.value.status, "ok");
    assert.equal(usage, 1);
    assert.equal(fs.existsSync(lockFile), false, "the lock is released before the request and stays released");
    assert.equal(JSON.parse(fs.readFileSync(stateFile, "utf8")).lastRequestAt, t0);
    // 정확히 60초면 아직 살아 있는 잠금이다
    fs.writeFileSync(lockFile, JSON.stringify({ pid: process.pid, at: t0 + 300_000 - C.REQUEST_LOCK_STALE_MS }));
    assert.deepEqual((await run(t0 + 300_000)).value, { provider: null, status: "ok", held: true });
    assert.equal(usage, 1);
    fs.rmSync(lockFile, { force: true });

    // 3. 만든 프로세스가 이미 죽은 잠금은 최근 것이어도 넘겨받는다
    const exited = spawnSync(process.execPath, ["-e", ""]);
    fs.writeFileSync(lockFile, JSON.stringify({ pid: exited.pid, at: t0 + 600_000 }));
    assert.equal((await run(t0 + 600_000)).value.status, "ok");
    assert.equal(usage, 2);
    assert.equal(fs.existsSync(lockFile), false);

    // 4. 내용을 읽을 수 없는 잠금(막 만들어져 비어 있을 수 있다)은 파일 시각으로 본다: 방금 것은 살아 있고, 오래된 것은 넘겨받는다
    fs.writeFileSync(lockFile, "");
    assert.deepEqual((await run(t0 + 900_000)).value, { provider: null, status: "ok", held: true });
    assert.equal(usage, 2);
    const old = new Date(Date.now() - C.REQUEST_LOCK_STALE_MS - 5_000);
    fs.utimesSync(lockFile, old, old);
    assert.equal((await run(t0 + 900_000)).value.status, "ok");
    assert.equal(usage, 3);
    assert.equal(fs.existsSync(lockFile), false);

    // 5. 잠금 파일을 만들 수 없는 곳이면(폴더 없음) 한 줄 남기고 잠금 없이 판단한다, 사이클은 깨지지 않는다
    const missing = path.join(dir, "missing", "state.json");
    const fallback = await run(t0 + 1_200_000, missing);
    assert.equal(fallback.value.status, "ok");
    assert.equal(usage, 4);
    assert.equal(fallback.lines.filter((line) => line.includes("잠금 없이 판단합니다")).length, 1, fallback.lines.join("\n"));
    assert.match(fallback.lines.find((line) => line.includes("잠금 없이 판단합니다")), /ENOENT/);

    // 6. 잠금 함수 자체: 같은 프로세스가 두 번 잡을 수 없고, 푼 뒤에는 다시 잡힌다, 상태 파일이 없으면 잠금도 없다
    const first = C.acquireClaudeRequestLock(stateFile, t0);
    assert.equal(first.acquired, true);
    assert.deepEqual(JSON.parse(fs.readFileSync(lockFile, "utf8")), { pid: process.pid, at: t0 });
    if (process.platform !== "win32") assert.equal(fs.statSync(lockFile).mode & 0o777, 0o600);
    const second = C.acquireClaudeRequestLock(stateFile, t0 + 1);
    assert.deepEqual([second.acquired, second.held], [false, true]);
    second.release();
    assert.ok(fs.existsSync(lockFile), "a run that did not get the lock never removes it");
    first.release();
    assert.equal(fs.existsSync(lockFile), false);
    assert.equal(C.acquireClaudeRequestLock(stateFile, t0 + 2, { isAlive: () => false }).acquired, true);
    // 낡았다고 판정한 다른 실행이 그사이 새로 만든 잠금은 이 실행의 release가 지우지 않는다
    fs.writeFileSync(lockFile, JSON.stringify({ pid: 4242, at: t0 + 3 }));
    first.release();
    assert.ok(fs.existsSync(lockFile));
    fs.rmSync(lockFile, { force: true });
    const none = C.acquireClaudeRequestLock(null, t0);
    assert.deepEqual([none.acquired, none.held, none.error, typeof none.release], [false, false, null, "function"]);
  });
});

test("T44 stale spacing lock: the takeover is serialized so overlapping runs acquire it once, and an undeletable stale lock falls back (D13)", async () => {
  const { spawn, spawnSync } = require("node:child_process");
  const U = require("./updater");
  const realWrite = fs.writeFileSync;
  await withTempDir(async (dir) => {
    const stateFile = path.join(dir, "state.json");
    const lockFile = `${stateFile}.lock`;
    const takeover = `${lockFile}.takeover`;
    const t0 = Date.parse("2026-09-15T00:00:00Z");
    const deadPid = spawnSync(process.execPath, ["-e", ""]).pid;
    const stale = () => fs.writeFileSync(lockFile, JSON.stringify({ pid: deadPid, at: t0 }));

    // 1. 낡은 잠금을 본 두 실행: 이 실행이 넘겨받기 표시를 만들기 직전에 다른 실행이 먼저 넘겨받아 새 잠금을 만들었다.
    //    지우고 다시 만들면 그 새 잠금을 지우고 둘 다 잡는다. 표시 안에서 잠금이 바뀐 것을 보고 물러나야 한다
    stale();
    const other = JSON.stringify({ pid: process.pid, at: t0 });
    let interleaved = 0;
    fs.writeFileSync = (file, data, options) => {
      if (file === takeover && interleaved++ === 0) {
        fs.rmSync(lockFile, { force: true });
        realWrite(lockFile, other, { flag: "wx" });
      }
      return realWrite(file, data, options);
    };
    try {
      const lost = C.acquireClaudeRequestLock(stateFile, t0);
      assert.deepEqual([lost.acquired, lost.held, lost.error], [false, true, null]);
    } finally {
      fs.writeFileSync = realWrite;
    }
    assert.equal(interleaved, 1);
    assert.equal(fs.readFileSync(lockFile, "utf8"), other, "the other run's fresh lock is left alone");
    assert.equal(fs.existsSync(takeover), false, "the takeover marker is removed");
    fs.rmSync(lockFile, { force: true });

    // 2. 다른 실행이 지금 넘겨받는 중이면(방금 만든 표시) 물러난다, 낡은 잠금도 표시도 건드리지 않는다
    stale();
    fs.writeFileSync(takeover, "4242");
    const busy = C.acquireClaudeRequestLock(stateFile, t0);
    assert.deepEqual([busy.acquired, busy.held, busy.error], [false, true, null]);
    assert.equal(fs.readFileSync(lockFile, "utf8"), JSON.stringify({ pid: deadPid, at: t0 }));
    assert.equal(fs.readFileSync(takeover, "utf8"), "4242");
    // 3. 넘겨받다가 죽은 실행의 표시(60초 넘게 오래됐다)는 지우고 넘겨받는다
    const old = new Date(Date.now() - C.REQUEST_LOCK_STALE_MS - 5_000);
    fs.utimesSync(takeover, old, old);
    const taken = C.acquireClaudeRequestLock(stateFile, t0);
    assert.deepEqual([taken.acquired, taken.held, taken.error], [true, false, null]);
    assert.deepEqual(JSON.parse(fs.readFileSync(lockFile, "utf8")), { pid: process.pid, at: t0 });
    assert.equal(fs.existsSync(takeover), false);
    taken.release();
    assert.equal(fs.existsSync(lockFile), false);

    // 4. 낡은 잠금이 있는데 폴더에 쓸 수 없으면(넘겨받기 표시도 못 만든다) 살아 있는 잠금처럼 영원히 물러나지 않고, 잠금 없이 한 번 판단한다
    if (process.platform !== "win32" && process.getuid?.() !== 0) {
      const ro = path.join(dir, "readonly");
      fs.mkdirSync(ro);
      const roState = path.join(ro, "state.json");
      const accountFile = path.join(dir, "account.json");
      fs.writeFileSync(accountFile, JSON.stringify({ credential: C.credentialKey("ref"), account: C.accountHash("acct") }));
      fs.writeFileSync(`${roState}.lock`, JSON.stringify({ pid: deadPid, at: t0 - 3600_000 }));
      fs.chmodSync(ro, 0o555);
      try {
        let usage = 0;
        const fallback = await quietly(() => C.claudeProvider({
          loadCredentials: async () => ({ claudeAiOauth: { accessToken: "tok", refreshToken: "ref" } }),
          fetchFn: async () => { usage += 1; return new Response(usageBody(), { status: 200 }); },
          claimLease: async () => true,
          stateFile: roState,
          accountFile,
          now: () => t0,
        }));
        assert.equal(fallback.value.status, "ok");
        assert.equal(usage, 1);
        assert.equal(fallback.lines.filter((line) => line.includes("잠금 없이 판단합니다")).length, 1, fallback.lines.join("\n"));
        assert.match(fallback.lines.find((line) => line.includes("잠금 없이 판단합니다")), /EACCES/);
        assert.equal(fallback.lines.some((line) => line.includes("reason=lock")), false, fallback.lines.join("\n"));
      } finally {
        fs.chmodSync(ro, 0o755);
      }
    }

    // 5. 세 프로세스가 매 판마다 같은 낡은 잠금(죽은 pid)을 동시에 넘겨받으려 한다: 매번 정확히 하나만 잡는다
    const rounds = 25;
    const child = path.join(dir, "race.js");
    fs.writeFileSync(child, [
      'const fs = require("node:fs");',
      'const path = require("node:path");',
      `const C = require(${JSON.stringify(path.join(__dirname, "collect.js"))});`,
      "const [tag, rounds] = process.argv.slice(2);",
      `const dir = ${JSON.stringify(dir)};`,
      `const stateFile = ${JSON.stringify(stateFile)};`,
      "for (let i = 0; i < Number(rounds); i += 1) {",
      '  fs.writeFileSync(path.join(dir, `ready-${i}-${tag}`), "");',
      "  const go = path.join(dir, `go-${i}`);",
      "  const deadline = Date.now() + 20_000;",
      '  while (!fs.existsSync(go)) { if (Date.now() > deadline) throw new Error("barrier timeout"); }',
      "  const lock = C.acquireClaudeRequestLock(stateFile, Date.now());",
      '  process.stdout.write(`ROUND ${i} ${tag} ${lock.acquired ? "acquired" : lock.held ? "held" : "error"}\\n`);',
      "  // 잡은 실행은 셋이 모두 결과를 낼 때까지 잠금을 쥔다 (늦게 온 실행이 풀린 잠금을 정당하게 잡는 것과 구분하려고)",
      "  const done = path.join(dir, `done-${i}`);",
      '  if (lock.acquired) { while (!fs.existsSync(done)) { if (Date.now() > deadline) throw new Error("done timeout"); } lock.release(); }',
      "}",
    ].join("\n"));
    const tags = ["a", "b", "c"];
    const rows = new Map();
    const procs = tags.map((tag) => {
      const proc = spawn(process.execPath, [child, tag, String(rounds)], { env: { ...process.env, NODE_OPTIONS: "" }, windowsHide: true });
      let buffer = "";
      let stderr = "";
      proc.stdout.on("data", (chunk) => {
        buffer += chunk;
        let index;
        while ((index = buffer.indexOf("\n")) >= 0) {
          const [, round, who, outcome] = buffer.slice(0, index).split(" ");
          buffer = buffer.slice(index + 1);
          rows.set(Number(round), [...(rows.get(Number(round)) ?? []), { who, outcome }]);
        }
      });
      proc.stderr.on("data", (chunk) => { stderr += chunk; });
      const done = new Promise((resolve) => proc.on("close", (status) => resolve({ tag, status, stderr: () => stderr })));
      return { proc, done };
    });
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    try {
      for (let i = 0; i < rounds; i += 1) {
        const deadline = Date.now() + 20_000;
        while (!tags.every((tag) => fs.existsSync(path.join(dir, `ready-${i}-${tag}`)))) {
          assert.ok(Date.now() < deadline, `round ${i}: children did not arrive`);
          await sleep(1);
        }
        fs.rmSync(lockFile, { force: true });
        stale();
        fs.writeFileSync(path.join(dir, `go-${i}`), "");
        while ((rows.get(i)?.length ?? 0) < tags.length) {
          assert.ok(Date.now() < deadline, `round ${i}: children did not report`);
          await sleep(1);
        }
        fs.writeFileSync(path.join(dir, `done-${i}`), "");
        const outcomes = rows.get(i).map((row) => row.outcome).sort();
        assert.deepEqual(outcomes, ["acquired", "held", "held"], `round ${i}: ${JSON.stringify(rows.get(i))}`);
      }
      const results = await Promise.all(procs.map((p) => p.done));
      for (const result of results) assert.equal(result.status, 0, `${result.tag}: ${result.stderr()}`);
      assert.equal(fs.existsSync(lockFile), false, "the last acquirer released the lock");
      assert.equal(fs.existsSync(takeover), false);
    } finally {
      for (const { proc } of procs) proc.kill();
    }
  });
});
