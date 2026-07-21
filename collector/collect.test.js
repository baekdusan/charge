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
