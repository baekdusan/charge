#!/usr/bin/env node
// Charge 수집기 — ccusage로 토큰 사용량을 뽑아 Charge 백엔드에 업로드한다.
// 사용법: node collect.js [--dry-run] [--days N]
// 인증: `npx charge-collector <페어링코드>`가 저장한 ~/.charge/config.json의 디바이스 토큰

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const DRY_RUN = process.argv.includes("--dry-run");
const daysArg = process.argv.indexOf("--days");
const parsedDays = daysArg > -1 ? parseInt(process.argv[daysArg + 1], 10) : NaN;
const DAYS = Number.isFinite(parsedDays) && parsedDays > 0 ? parsedDays : 60;
const CACHE_FILE = path.join(__dirname, ".last-payload.json");
const HOME = process.env.HOME ?? process.env.USERPROFILE;
const WIN = process.platform === "win32";
const EXTRA_PATH = WIN ? "" : ":/opt/homebrew/bin:/usr/local/bin";

function run(cmd, args, timeout = 120_000) {
  return execFileSync(cmd, args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    timeout,
    env: { ...process.env, PATH: `${process.env.PATH}${EXTRA_PATH}` },
    // Windows에서 npx/ccusage는 .cmd 셔틀이라 셸을 거쳐야 실행된다 (인자는 모두 고정 문자열)
    shell: WIN,
  });
}

function runCcusage(args) {
  // 전역 설치본이 있으면 사용(빠름), 없으면 npx로 대체
  try {
    return JSON.parse(run("ccusage", args));
  } catch (e) {
    console.error(`ccusage 직접 실행 실패(${e.code ?? e.message}), npx로 재시도`);
    return JSON.parse(run("npx", ["-y", "ccusage@latest", ...args], 300_000));
  }
}

// 프로바이더 계정 식별자 해시 — 원문 대신 해시만 업로드 (다른 계정이면 카드가 분리되도록)
function accountHash(id) {
  if (!id) return null;
  return require("node:crypto").createHash("sha256").update(String(id)).digest("hex").slice(0, 12);
}

/// 리셋 시각이 이미 지난 창은 무효 처리 (리셋 후 100% 박제 방지)
function dropExpired(w) {
  if (!w) return null;
  if (w.resets_at && new Date(w.resets_at).getTime() < Date.now()) return null;
  return w;
}

function sinceStr(days) {
  const d = new Date(Date.now() - days * 86400_000);
  return `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
}

function collectDaily() {
  const data = runCcusage(["daily", "--json", "--since", sinceStr(DAYS)]);
  let rows = data.daily ?? [];
  // 에이전트별 행과 "all" 집계 행이 섞여 있으면 "all"만 사용해 중복 합산을 방지
  if (rows.some((r) => r.agent === "all")) rows = rows.filter((r) => r.agent === "all");
  const byDay = new Map();
  for (const r of rows) {
    const e = byDay.get(r.period) ?? {
      period: r.period,
      total_cost: 0, total_tokens: 0, input_tokens: 0, output_tokens: 0,
      cache_read_tokens: 0, cache_creation_tokens: 0, models: [],
    };
    e.total_cost += r.totalCost ?? 0;
    e.total_tokens += r.totalTokens ?? 0;
    e.input_tokens += r.inputTokens ?? 0;
    e.output_tokens += r.outputTokens ?? 0;
    e.cache_read_tokens += r.cacheReadTokens ?? 0;
    e.cache_creation_tokens += r.cacheCreationTokens ?? 0;
    e.models = e.models.concat(r.modelBreakdowns ?? []);
    byDay.set(r.period, e);
  }
  return [...byDay.values()].sort((a, b) => a.period.localeCompare(b.period));
}

function collectLive() {
  const data = runCcusage(["blocks", "--active", "--json"]);
  return (data.blocks ?? []).find((b) => b.isActive) ?? null;
}

// Claude Code 자격증명: macOS는 Keychain, Windows/Linux는 ~/.claude/.credentials.json
function claudeCredentials() {
  try {
    return JSON.parse(run("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]));
  } catch {
    return JSON.parse(fs.readFileSync(path.join(HOME, ".claude", ".credentials.json"), "utf8"));
  }
}

// Claude: Claude Code OAuth 세션을 재사용해 공식 usage API 조회
async function claudeProvider() {
  try {
    const cred = claudeCredentials();
    const oauth = cred.claudeAiOauth ?? cred;
    const token = oauth.accessToken;
    // rateLimitTier "default_claude_max_20x" → "Max 20x", 없으면 subscriptionType "max" → "Max"
    const tier = /max_(\d+)x/.exec(oauth.rateLimitTier ?? "");
    const plan = tier
      ? `Max ${tier[1]}x`
      : oauth.subscriptionType
        ? oauth.subscriptionType[0].toUpperCase() + oauth.subscriptionType.slice(1)
        : null;
    const res = await fetch("https://api.anthropic.com/api/oauth/usage", {
      headers: { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) return null;
    const d = await res.json();
    // 계정 UUID → 해시 (프로필 조회 실패 시 null — 캐시 폴백이 채워준다)
    let account = null;
    try {
      const pr = await fetch("https://api.anthropic.com/api/oauth/profile", {
        headers: { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
        signal: AbortSignal.timeout(10_000),
      });
      if (pr.ok) account = accountHash((await pr.json()).account?.uuid);
    } catch {}
    const win = (w, mins) =>
      w ? { percent: w.utilization ?? 0, resets_at: w.resets_at ?? null, window_minutes: mins } : null;
    // limits 배열의 weekly_scoped 항목 = 모델별 주간 한도 (예: "Fable only")
    const extras = (d.limits ?? [])
      .filter((l) => l.kind === "weekly_scoped" && l.scope?.model?.display_name)
      .map((l) => ({
        name: l.scope.model.display_name,
        window: { percent: l.percent ?? 0, resets_at: l.resets_at ?? null, window_minutes: 10080 },
      }));
    return {
      id: "claude",
      name: "Claude",
      plan,
      account,
      session: dropExpired(win(d.five_hour, 300)),
      weekly: dropExpired(win(d.seven_day, 10080)),
      extras: extras.length ? extras : null,
    };
  } catch (e) {
    console.error(`claude 프로바이더 수집 실패: ${e.message ?? e}`);
    return null;
  }
}

// Codex: 최신 세션 로그에 기록된 rate_limits 스냅샷 파싱
function codexProvider() {
  try {
    const dir = path.join(HOME, ".codex", "sessions");
    let latest = null;
    (function walk(d) {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p);
        else if (e.name.endsWith(".jsonl")) {
          const m = fs.statSync(p).mtimeMs;
          if (!latest || m > latest.m) latest = { p, m };
        }
      }
    })(dir);
    if (!latest) return null;

    const findRL = (o) => {
      if (!o || typeof o !== "object") return null;
      if (o.rate_limits) return o.rate_limits;
      for (const v of Object.values(o)) {
        const r = findRL(v);
        if (r) return r;
      }
      return null;
    };
    let rl = null;
    for (const line of fs.readFileSync(latest.p, "utf8").split("\n")) {
      if (!line.includes('"rate_limits"')) continue;
      try {
        rl = findRL(JSON.parse(line)) ?? rl;
      } catch {}
    }
    if (!rl) return null;
    // auth.json id_token JWT의 chatgpt_plan_type ("education" 등) + 계정 식별자
    let plan = null;
    let account = null;
    try {
      const auth = JSON.parse(fs.readFileSync(path.join(HOME, ".codex", "auth.json"), "utf8"));
      const seg = auth.tokens.id_token.split(".")[1];
      const claims = JSON.parse(Buffer.from(seg, "base64url").toString("utf8"));
      const a = claims["https://api.openai.com/auth"] ?? {};
      if (a.chatgpt_plan_type) plan = a.chatgpt_plan_type[0].toUpperCase() + a.chatgpt_plan_type.slice(1);
      account = accountHash(a.chatgpt_account_id);
    } catch {}
    const win = (w) =>
      w
        ? {
            percent: w.used_percent ?? 0,
            resets_at: w.resets_at ? new Date(w.resets_at * 1000).toISOString() : null,
            window_minutes: w.window_minutes ?? null,
          }
        : null;
    return {
      id: "codex",
      name: "Codex",
      plan,
      account,
      session: dropExpired(win(rl.primary)),
      weekly: dropExpired(win(rl.secondary)),
      extras: null,
    };
  } catch (e) {
    console.error(`codex 프로바이더 수집 실패: ${e.message ?? e}`);
    return null;
  }
}

// 프로바이더 상태 페이지 (Statuspage 공용 API)
async function statusOf(url) {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(8_000) });
    if (!res.ok) return null;
    const d = await res.json();
    return { indicator: d.status?.indicator ?? "none", description: d.status?.description ?? null };
  } catch {
    return null;
  }
}

async function collectProviders() {
  const [claude, codex, claudeStatus, codexStatus] = await Promise.all([
    claudeProvider(),
    Promise.resolve(codexProvider()),
    statusOf("https://status.anthropic.com/api/v2/status.json"),
    statusOf("https://status.openai.com/api/v2/status.json"),
  ]);
  if (claude) claude.status = claudeStatus;
  if (codex) codex.status = codexStatus;
  return [claude, codex].filter(Boolean);
}

// 업로드 설정 — 우선순위: CHARGE_* 환경변수(테스트용) → ~/.charge/config.json(페어링)
function resolveMode() {
  if (process.env.CHARGE_TOKEN && process.env.CHARGE_URL && process.env.CHARGE_ANON) {
    return { url: process.env.CHARGE_URL, anon: process.env.CHARGE_ANON, token: process.env.CHARGE_TOKEN };
  }
  const conf = path.join(process.env.CHARGE_HOME ?? path.join(HOME, ".charge"), "config.json");
  try {
    return JSON.parse(fs.readFileSync(conf, "utf8"));
  } catch {
    return null;
  }
}

// 디바이스 토큰으로 charge_upload RPC 호출 (서버가 본인 행에만 기록)
async function pairedUpload(mode, daily, live, providers) {
  const res = await fetch(`${mode.url}/rest/v1/rpc/charge_upload`, {
    method: "POST",
    headers: {
      apikey: mode.anon,
      Authorization: `Bearer ${mode.anon}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_token: mode.token, p_daily: daily, p_live: live, p_providers: providers }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) throw new Error(`업로드 실패 (${res.status}): ${await res.text()}`);
}

(async () => {
  // 이전 성공 페이로드 캐시 — 일부 수집이 실패해도 그 부분만 이전 값으로 유지
  let cache = {};
  try {
    cache = JSON.parse(fs.readFileSync(CACHE_FILE, "utf8"));
  } catch {}

  let daily, live, providers;
  try {
    daily = collectDaily();
  } catch (e) {
    console.error(`daily 수집 실패, 이전 값 유지: ${e.message ?? e}`);
    daily = cache.daily ?? [];
  }
  try {
    live = collectLive();
  } catch (e) {
    console.error(`live 수집 실패, 이전 값 유지: ${e.message ?? e}`);
    live = cache.live ?? null;
  }
  providers = await collectProviders();
  // 일부 프로바이더만 실패해도 목록에서 사라지지 않게 이전 값으로 채운다 (앱 설정 토글 유지)
  for (const prev of cache.providers ?? []) {
    if (!providers.some((p) => p.id === prev.id)) providers.push(prev);
  }
  // 계정 식별 실패 시 마지막으로 알려진 계정 해시 유지 (계정 미상('')과 실제 계정 행이 갈라지는 것 방지)
  for (const p of providers) {
    if (!p.account) p.account = (cache.providers ?? []).find((c) => c.id === p.id)?.account ?? null;
  }

  if (DRY_RUN) {
    console.log(JSON.stringify({ daily: daily.slice(-1), live, providers }, null, 2));
    console.log(`\n[dry-run] daily ${daily.length}행 + live + providers ${providers.length}개 업로드 예정`);
    return;
  }

  const mode = resolveMode();
  if (!mode) {
    console.error("페어링이 안 돼 있습니다. 앱에서 코드를 발급받아 `npx charge-collector <코드>`를 실행하세요.");
    process.exit(1);
  }

  const now = new Date().toISOString();
  await pairedUpload(mode, daily, live, providers);

  fs.writeFileSync(CACHE_FILE, JSON.stringify({ daily, live, providers }));
  console.log(`[${now}] daily ${daily.length}행 + live + providers ${providers.length}개 업로드 완료`);
})().catch((e) => {
  console.error(e.message ?? e);
  process.exit(1);
});
