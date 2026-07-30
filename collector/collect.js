#!/usr/bin/env node
// Charge 수집기 — ccusage로 토큰 사용량을 뽑아 Charge 백엔드에 업로드한다.
// 사용법: node collect.js [--dry-run] [--days N]
// 인증: `npx charge-connect <페어링코드>`가 저장한 ~/.charge/config.json의 디바이스 토큰

const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const fs = require("node:fs");
const path = require("node:path");

const execFileAsync = promisify(execFile);

const DRY_RUN = process.argv.includes("--dry-run");
const daysArg = process.argv.indexOf("--days");
const parsedDays = daysArg > -1 ? parseInt(process.argv[daysArg + 1], 10) : NaN;
const DAYS = Number.isFinite(parsedDays) && parsedDays > 0 ? parsedDays : 60;
const CACHE_FILE = path.join(__dirname, ".last-payload.json");
const HOME = process.env.HOME ?? process.env.USERPROFILE;
const WIN = process.platform === "win32";
const EXTRA_PATH = WIN ? "" : ":/opt/homebrew/bin:/usr/local/bin";
const DEFAULT_CODEXBAR_CLI = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI";

// 모든 외부 명령은 비동기로 실행한다 — 동기(execFileSync)는 이벤트 루프를 세워
// 진행 중인 fetch(AbortSignal 타이머 포함)를 전부 타임아웃시킨다.
// Windows에서 npx/ccusage는 .cmd 셔틀이라 셸을 거쳐야 실행된다 (인자는 모두 고정 문자열).
const execOpts = (timeout) => ({
  encoding: "utf8",
  maxBuffer: 64 * 1024 * 1024,
  timeout,
  env: { ...process.env, PATH: `${process.env.PATH}${EXTRA_PATH}` },
  shell: WIN,
});

async function runAsync(cmd, args, timeout = 120_000) {
  // promisify된 execFile은 실패 시에도 err.stdout/stderr를 붙여준다
  return (await execFileAsync(cmd, args, execOpts(timeout))).stdout;
}

async function runCcusage(args) {
  // 전역 설치본이 있으면 사용(빠름), 없으면 npx로 대체
  try {
    return JSON.parse(await runAsync("ccusage", args));
  } catch (e) {
    console.error(`ccusage 직접 실행 실패(${e.code ?? e.message}), npx로 재시도 — 'npm i -g ccusage'를 해두면 빨라집니다`);
    // --prefer-offline: npx 캐시가 있으면 레지스트리 조회 없이 재사용 (5분마다 재다운로드 방지)
    return JSON.parse(await runAsync("npx", ["-y", "--prefer-offline", "ccusage@latest", ...args], 300_000));
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

// 캐시에서 복원한 프로바이더도 신선 수집과 같은 만료 규칙을 적용한다.
// 안 하면 수집이 실패하는 동안 리셋이 지난 창이 무한 재업로드된다 (유령 게이지).
function sanitizeCachedProvider(prev) {
  if (!prev || typeof prev !== "object") return null;
  const extras = (prev.extras ?? [])
    .map((extra) => ({ ...extra, window: dropExpired(extra.window) }))
    .filter((extra) => extra.window);
  return {
    ...prev,
    session: dropExpired(prev.session),
    weekly: dropExpired(prev.weekly),
    extras: extras.length ? extras : null,
  };
}

const PROVIDER_NAMES = {
  "azure-openai": "Azure OpenAI",
  "openai": "OpenAI",
  "opencode": "OpenCode",
  "opencodego": "OpenCode Go",
  "openrouter": "OpenRouter",
  "vertexai": "Vertex AI",
  "alibaba-coding-plan": "Alibaba Coding Plan",
  "alibaba-token-plan": "Alibaba Token Plan",
  "antigravity": "Antigravity",
  "copilot": "GitHub Copilot",
  "deepseek": "DeepSeek",
  "jetbrains": "JetBrains",
  "minimax": "MiniMax",
  "perplexity": "Perplexity",
  "windsurf": "Windsurf",
  "zai": "Z.ai",
};

function titleCaseProvider(id) {
  return String(id)
    .split(/[-_.]+/)
    .filter(Boolean)
    .map((part) => part[0]?.toUpperCase() + part.slice(1))
    .join(" ");
}

function normalizeResetAt(value) {
  if (value == null || value === "") return null;
  const numeric = typeof value === "number" ? value : Number.NaN;
  const date = Number.isFinite(numeric)
    ? new Date(numeric < 10_000_000_000 ? numeric * 1000 : numeric)
    : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function durationLabel(minutes) {
  if (minutes === 300) return "Session";
  if (minutes === 1440) return "Daily";
  if (minutes === 10_080) return "Weekly";
  if (minutes === 43_200) return "Monthly";
  return null;
}

function explicitWindowLabel(window) {
  const value = window?.label ?? window?.title ?? window?.displayName ?? window?.name ?? window?.limitName;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function normalizeRateWindow(window, slot, duplicateDuration = false, forcedLabel = null) {
  if (!window || typeof window !== "object") return null;
  const percent = Number(window.usedPercent ?? window.percent ?? window.utilization);
  if (!Number.isFinite(percent)) return null;
  const rawMinutes = window.windowMinutes ?? window.window_minutes ?? window.durationMinutes;
  const parsedMinutes = rawMinutes == null ? null : Number(rawMinutes);
  const minutes = Number.isFinite(parsedMinutes) && parsedMinutes > 0 ? parsedMinutes : null;
  const baseLabel = durationLabel(minutes);
  const slotLabel = slot[0].toUpperCase() + slot.slice(1);
  const label = forcedLabel
    ?? explicitWindowLabel(window)
    ?? (duplicateDuration && baseLabel ? `${slotLabel} ${baseLabel.toLowerCase()}` : baseLabel)
    ?? slotLabel;
  return dropExpired({
    percent: Math.min(100, Math.max(0, percent)),
    resets_at: normalizeResetAt(window.resetsAt ?? window.resets_at ?? window.resetAt),
    window_minutes: minutes,
    label,
  });
}

function textValue(...values) {
  return values.find((value) => typeof value === "string" && value.trim())?.trim() ?? null;
}

function usefulPlan(...values) {
  const value = textValue(...values);
  if (!value) return null;
  const generic = new Set(["api", "auto", "browser", "cli", "cookie", "oauth", "unknown", "web"]);
  return generic.has(value.toLowerCase()) ? null : value;
}

function sinceStr(days) {
  const d = new Date(Date.now() - days * 86400_000);
  return `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
}

async function collectDaily() {
  const data = await runCcusage(["daily", "--json", "--since", sinceStr(DAYS)]);
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

async function collectLive() {
  const data = await runCcusage(["blocks", "--active", "--json"]);
  return (data.blocks ?? []).find((b) => b.isActive) ?? null;
}

// Claude Code 자격증명: macOS는 Keychain, Windows/Linux는 ~/.claude/.credentials.json
async function claudeCredentials() {
  try {
    return JSON.parse(await runAsync("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]));
  } catch {
    return JSON.parse(fs.readFileSync(path.join(HOME, ".claude", ".credentials.json"), "utf8"));
  }
}

// Claude: Claude Code OAuth 세션을 재사용해 공식 usage API 조회
async function claudeProvider() {
  try {
    const cred = await claudeCredentials();
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
    if (!res.ok) {
      // 401 = 토큰 만료 (Claude Code를 한 번 실행하면 갱신됨), 그 외는 일시 장애일 가능성
      console.error(`claude usage API ${res.status}${res.status === 401 ? " — 토큰 만료, Claude Code를 실행하면 갱신됩니다" : ""}`);
      return null;
    }
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
        window: {
          percent: l.percent ?? 0,
          resets_at: l.resets_at ?? null,
          window_minutes: 10080,
          label: `${l.scope.model.display_name} weekly`,
        },
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
// Codex 자격증명·계정 정보 (~/.codex/auth.json) — 없으면 null
function codexAuth() {
  try {
    const auth = JSON.parse(fs.readFileSync(path.join(HOME, ".codex", "auth.json"), "utf8"));
    let plan = null;
    let account = null;
    try {
      // id_token JWT의 chatgpt_plan_type ("education" 등) + 계정 식별자
      const seg = auth.tokens.id_token.split(".")[1];
      const claims = JSON.parse(Buffer.from(seg, "base64url").toString("utf8"));
      const a = claims["https://api.openai.com/auth"] ?? {};
      if (a.chatgpt_plan_type) plan = a.chatgpt_plan_type[0].toUpperCase() + a.chatgpt_plan_type.slice(1);
      account = accountHash(a.chatgpt_account_id);
    } catch {}
    return {
      accessToken: auth.tokens?.access_token ?? null,
      accountId: auth.tokens?.account_id ?? null,
      plan,
      account,
    };
  } catch {
    return null;
  }
}

// Codex 실시간 조회: Codex CLI 자신이 60초마다 폴링하는 것과 같은 엔드포인트를
// 로컬 OAuth 토큰으로 호출한다. 토큰 갱신은 하지 않는다 — 만료됐으면 null을 반환하고
// 스냅샷 폴백에 맡긴다 (CLI가 다음 실행 때 알아서 갱신해 둔다).
async function codexLiveWindows(auth) {
  if (!auth?.accessToken || !auth?.accountId) return null;
  try {
    const res = await fetch("https://chatgpt.com/backend-api/wham/usage", {
      headers: {
        Authorization: `Bearer ${auth.accessToken}`,
        "chatgpt-account-id": auth.accountId,
        "User-Agent": "charge-connect",
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) return null;
    const d = await res.json();
    const win = (w) =>
      w && Number.isFinite(Number(w.used_percent))
        ? {
            percent: Number(w.used_percent),
            resets_at: w.reset_at ? new Date(w.reset_at * 1000).toISOString() : null,
            window_minutes: Number.isFinite(Number(w.limit_window_seconds))
              ? Math.round(Number(w.limit_window_seconds) / 60)
              : null,
          }
        : null;
    const session = win(d.rate_limit?.primary_window);
    const weekly = win(d.rate_limit?.secondary_window);
    if (!session && !weekly) return null;
    const plan = usefulPlan(d.plan_type);
    return { session, weekly, plan: plan ? plan[0].toUpperCase() + plan.slice(1) : null };
  } catch {
    return null;
  }
}

// Codex 스냅샷 폴백: 가장 최근 세션 로그(.jsonl)에 기록된 마지막 rate_limits —
// 마지막으로 Codex를 실제 사용한 시점의 값이라 실시간 조회가 실패했을 때만 쓴다
function codexSnapshotWindows() {
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
  const win = (w) =>
    w
      ? {
          percent: w.used_percent ?? 0,
          resets_at: w.resets_at ? new Date(w.resets_at * 1000).toISOString() : null,
          window_minutes: w.window_minutes ?? null,
        }
      : null;
  return { session: win(rl.primary), weekly: win(rl.secondary) };
}

async function codexProvider() {
  try {
    const auth = codexAuth();
    const windows = (await codexLiveWindows(auth)) ?? codexSnapshotWindows();
    if (!windows) return null;
    return {
      id: "codex",
      name: "Codex",
      plan: windows.plan ?? auth?.plan ?? null,
      account: auth?.account ?? null,
      session: dropExpired(windows.session),
      weekly: dropExpired(windows.weekly),
      extras: null,
    };
  } catch (e) {
    console.error(`codex 프로바이더 수집 실패: ${e.message ?? e}`);
    return null;
  }
}

function extraWindowValues(value) {
  if (Array.isArray(value)) return value;
  if (!value || typeof value !== "object") return [];
  return Object.entries(value).map(([name, window]) => ({ name, ...(window ?? {}) }));
}

// CodexBar 공통 JSON을 Charge의 두 기본 창 + 추가 창 구조로 변환한다.
// 원본 identity는 절대 반환하지 않고 계정 식별값의 짧은 해시만 보낸다.
function codexBarEntryToProvider(entry) {
  if (!entry || entry.error || typeof entry !== "object") return null;
  const id = textValue(entry.provider, entry.id)?.toLowerCase();
  if (!id || id === "claude" || id === "codex") return null;

  const usage = entry.usage && typeof entry.usage === "object" ? entry.usage : entry;
  const identity = usage.identity && typeof usage.identity === "object"
    ? usage.identity
    : entry.identity && typeof entry.identity === "object" ? entry.identity : {};
  const slots = ["primary", "secondary", "tertiary"]
    .map((slot) => ({ slot, value: usage[slot] ?? entry[slot] }))
    .filter(({ value }) => value && typeof value === "object");
  const durationCounts = new Map();
  for (const { value } of slots) {
    const minutes = Number(value.windowMinutes ?? value.window_minutes ?? value.durationMinutes);
    if (Number.isFinite(minutes)) durationCounts.set(minutes, (durationCounts.get(minutes) ?? 0) + 1);
  }
  const normalizedWindows = slots
    .map(({ slot, value }) => {
      const minutes = Number(value.windowMinutes ?? value.window_minutes ?? value.durationMinutes);
      return {
        slot,
        window: normalizeRateWindow(value, slot, (durationCounts.get(minutes) ?? 0) > 1),
      };
    })
    .filter(({ window }) => window);
  const primary = normalizedWindows.find(({ slot }) => slot === "primary")?.window ?? null;
  const secondary = normalizedWindows.find(({ slot }) => slot === "secondary")?.window ?? null;

  const extras = normalizedWindows
    .filter(({ slot }) => slot === "tertiary")
    .map(({ window }) => ({ name: window.label, window }));
  const rawExtras = extraWindowValues(usage.extraRateWindows ?? entry.extraRateWindows);
  rawExtras.forEach((raw, index) => {
    const value = raw.window && typeof raw.window === "object" ? raw.window : raw;
    const label = explicitWindowLabel(raw)
      ?? explicitWindowLabel(value)
      ?? `Limit ${index + normalizedWindows.length + 1}`;
    const window = normalizeRateWindow(value, "limit", false, label);
    if (window) extras.push({ name: label, window });
  });

  if (!primary && !secondary && extras.length === 0) return null;
  const rawAccount = textValue(
    identity.accountEmail,
    identity.email,
    usage.accountEmail,
    entry.accountEmail,
    identity.accountId,
    usage.accountId,
    identity.accountOrganization,
    usage.accountOrganization
  );
  const plan = usefulPlan(
    usage.plan,
    identity.plan,
    usage.subscription,
    identity.subscription,
    usage.loginMethod,
    identity.loginMethod
  );

  return {
    id,
    name: textValue(entry.displayName, entry.providerName, usage.providerName) ?? PROVIDER_NAMES[id] ?? titleCaseProvider(id),
    plan,
    account: accountHash(rawAccount),
    session: primary,
    weekly: secondary,
    extras: extras.length ? extras : null,
    status: null,
    collector_source: "codexbar",
  };
}

function parseCodexBarJSON(raw) {
  const text = String(raw ?? "").trim();
  if (!text) return null;
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    const start = text.indexOf("[");
    const end = text.lastIndexOf("]");
    if (start < 0 || end <= start) return null;
    try {
      return JSON.parse(text.slice(start, end + 1));
    } catch {
      return null;
    }
  }
}

async function collectCodexBarProviders() {
  if (process.env.CHARGE_DISABLE_CODEXBAR === "1") return { providers: [], complete: false };
  const cli = process.env.CHARGE_CODEXBAR_CLI
    ?? (!WIN && fs.existsSync(DEFAULT_CODEXBAR_CLI) ? DEFAULT_CODEXBAR_CLI : null);
  if (!cli) return { providers: [], complete: false };

  let raw = "";
  let commandSucceeded = true;
  try {
    // CodexBar CLI는 실측 20초 이상 걸릴 수 있다 — 동기로 돌리면 그동안 이벤트 루프가
    // 멈춰 Claude/Codex fetch의 abort 타이머가 전부 발화하므로 반드시 비동기로.
    raw = await runAsync(cli, ["usage", "--format", "json"], 90_000);
  } catch (e) {
    commandSucceeded = false;
    raw = e.stdout?.toString?.() ?? "";
    if (!raw.trim()) {
      console.error(`CodexBar 프로바이더 수집 실패: ${e.message ?? e}`);
      return { providers: [], complete: false };
    }
  }

  const entries = parseCodexBarJSON(raw);
  if (!entries) {
    console.error("CodexBar 프로바이더 수집 실패: JSON 출력을 해석할 수 없습니다.");
    return { providers: [], complete: false };
  }
  const bridgeEntries = entries.filter((entry) => !["claude", "codex"].includes(entry?.provider));
  const providers = bridgeEntries.map(codexBarEntryToProvider).filter(Boolean);
  const complete = commandSucceeded && !bridgeEntries.some((entry) => entry?.error);
  for (const entry of bridgeEntries.filter((item) => item?.error)) {
    console.error(`CodexBar ${entry.provider ?? "프로바이더"} 수집 실패: ${entry.error.message ?? "알 수 없는 오류"}`);
  }
  return { providers, complete };
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
  const [claude, codex, claudeStatus, codexStatus, codexBar] = await Promise.all([
    claudeProvider(),
    codexProvider(),
    statusOf("https://status.anthropic.com/api/v2/status.json"),
    statusOf("https://status.openai.com/api/v2/status.json"),
    collectCodexBarProviders(),
  ]);
  if (claude) claude.status = claudeStatus;
  if (codex) codex.status = codexStatus;
  return {
    providers: [claude, codex, ...codexBar.providers].filter(Boolean),
    codexBarComplete: codexBar.complete,
  };
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

async function main() {
  // 이전 성공 페이로드 캐시 — 일부 수집이 실패해도 그 부분만 이전 값으로 유지
  let cache = {};
  try {
    cache = JSON.parse(fs.readFileSync(CACHE_FILE, "utf8"));
  } catch {}

  // ccusage 두 갈래와 프로바이더 수집(네트워크+CodexBar CLI)은 서로 독립 —
  // 병렬로 돌려 전체 수집 시간을 max(ccusage, network)로 줄인다.
  // allSettled라 한 갈래가 실패해도 나머지는 살고, 실패분만 이전 값으로 채운다.
  const [dailyR, liveR, providersR] = await Promise.allSettled([
    collectDaily(),
    collectLive(),
    collectProviders(),
  ]);
  let daily, live, providers;
  if (dailyR.status === "fulfilled") {
    daily = dailyR.value;
  } else {
    console.error(`daily 수집 실패, 이전 값 유지: ${dailyR.reason?.message ?? dailyR.reason}`);
    daily = cache.daily ?? [];
  }
  if (liveR.status === "fulfilled") {
    live = liveR.value;
  } else {
    console.error(`live 수집 실패, 이전 값 유지: ${liveR.reason?.message ?? liveR.reason}`);
    live = cache.live ?? null;
  }
  let providerCollection;
  if (providersR.status === "fulfilled") {
    providerCollection = providersR.value;
  } else {
    console.error(`프로바이더 수집 실패, 이전 값 유지: ${providersR.reason?.message ?? providersR.reason}`);
    providerCollection = { providers: [], codexBarComplete: false };
  }
  providers = providerCollection.providers;
  // 일부 프로바이더만 실패해도 목록에서 사라지지 않게 이전 값으로 채운다 (앱 설정 토글 유지)
  for (const prev of cache.providers ?? []) {
    if (providers.some((p) => p.id === prev.id)) continue;
    // CodexBar가 정상 완료된 경우, 거기서 더 이상 반환하지 않는 항목은 사용자가 끈 것으로 본다.
    if (providerCollection.codexBarComplete && prev.collector_source === "codexbar") continue;
    const sanitized = sanitizeCachedProvider(prev);
    if (sanitized) providers.push(sanitized);
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
    console.error("페어링이 안 돼 있습니다. 앱에서 코드를 발급받아 `npx charge-connect <코드>`를 실행하세요.");
    process.exit(1);
  }

  const now = new Date().toISOString();
  await pairedUpload(mode, daily, live, providers);

  fs.writeFileSync(CACHE_FILE, JSON.stringify({ daily, live, providers }));
  console.log(`[${now}] daily ${daily.length}행 + live + providers ${providers.length}개 업로드 완료`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e.message ?? e);
    process.exit(1);
  });
}

module.exports = {
  accountHash,
  codexBarEntryToProvider,
  collectCodexBarProviders,
  dropExpired,
  durationLabel,
  normalizeRateWindow,
  normalizeResetAt,
  parseCodexBarJSON,
  resolveMode,
  sanitizeCachedProvider,
  titleCaseProvider,
  usefulPlan,
};
