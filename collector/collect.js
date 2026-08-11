#!/usr/bin/env node
// Charge 수집기 — ccusage로 토큰 사용량을 뽑아 Charge 백엔드에 업로드한다.
// 사용법: node collect.js [--dry-run] [--days N] [--log 경로]
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

// 스케줄러가 부를 때는 볼 콘솔이 없으니 출력을 직접 파일로 받는다.
// 셸 리다이렉션(cmd `>`)에 맡기면 경로의 %VAR% 확장·로그 잠금 같은 문제를 떠안게 된다.
// 5분마다 도는 작업이라 그냥 이어 붙이면 끝없이 자라므로 5MB에서 .old로 민다.
const logArg = process.argv.indexOf("--log");
const LOG_FILE = logArg > -1 ? process.argv[logArg + 1] : null;
// 아래 로그 리다이렉션·핸들러 등록·process.exit은 스크립트로 직접 실행될 때만 해야 한다.
// cli.js가 버전 상수를 require할 때 이 부작용이 딸려오면 CLI 콘솔이 파일로 새거나 조기 종료된다.
if (require.main === module && logArg > -1 && (!LOG_FILE || LOG_FILE.startsWith("-"))) {
  // 값을 안 주면 조용히 로그가 꺼지고, 다음 옵션을 삼키면 "--dry-run"이라는 파일에 쓰게 된다
  console.error("--log 뒤에는 파일 경로가 필요합니다.");
  process.exit(1);
}
if (require.main === module && LOG_FILE) {
  try {
    if (fs.statSync(LOG_FILE).size > 5 * 1024 * 1024) fs.renameSync(LOG_FILE, `${LOG_FILE}.old`);
  } catch {}
  // 비동기 스트림은 process.exit에서 버퍼를 잃을 수 있어 동기로 쓴다 (줄 수가 적다)
  const write = (...args) => {
    try {
      fs.appendFileSync(LOG_FILE, `${args.map(String).join(" ")}\n`);
    } catch {}
  };
  console.log = write;
  console.error = write;
  // 스케줄러가 돌릴 때는 Node 기본 stderr가 어디에도 안 남는다. 잡지 않으면
  // 크래시했을 때 로그에 시작 줄만 덩그러니 남아 원인을 알 수 없다.
  const fatal = (label) => (err) => {
    write(`[${new Date().toISOString()}] ${label}: ${err?.stack ?? err}`);
    process.exit(1);
  };
  process.on("uncaughtException", fatal("치명적 오류"));
  process.on("unhandledRejection", fatal("처리되지 않은 거부"));
  // 시작 줄을 바로 남긴다 — '언제 마지막으로 돌았나'를 알 수 있고,
  // install.ps1이 스케줄 작업이 실제로 떴는지 판정하는 근거이기도 하다.
  write(`[${new Date().toISOString()}] 수집 시작`);
}
const WIN = process.platform === "win32";
// 스케줄러(작업 스케줄러/launchd)가 만드는 환경에는 셸 프로필에서 붙는 PATH가 없다.
// Windows에서 nvm-windows·fnm·volta로 Node를 깐 사용자는 그래서 npx/ccusage를 못 찾는다.
// node가 자기 위치는 알고 있으므로, 그 디렉터리와 npm 전역 bin을 직접 얹어준다.
const EXTRA_PATH = WIN
  ? [path.dirname(process.execPath), process.env.APPDATA && path.join(process.env.APPDATA, "npm")]
      .filter(Boolean)
      .map((p) => `;${p}`)
      .join("")
  : ":/opt/homebrew/bin:/usr/local/bin";
const DEFAULT_CODEXBAR_CLI = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI";

// ccusage는 정확한 버전으로 고정한다 — @latest로 5분마다 무인 실행하면 ccusage npm
// 계정/배포가 탈취됐을 때 별도 조작 없이 악성 코드가 모든 사용자 PC에서 돌게 된다.
// 이 프로세스는 Claude/Codex 자격증명이 있는 홈에서 사용자 권한으로 실행되므로 위험이 크다.
// 갱신은 릴리스마다 새 버전을 검토한 뒤 의도적으로만 올린다.
const CCUSAGE_VERSION = "20.0.19";
const CCUSAGE_PKG = `ccusage@${CCUSAGE_VERSION}`;

// 모든 외부 명령은 비동기로 실행한다 — 동기(execFileSync)는 이벤트 루프를 세워
// 진행 중인 fetch(AbortSignal 타이머 포함)를 전부 타임아웃시킨다.
const execOpts = (timeout) => ({
  encoding: "utf8",
  maxBuffer: 64 * 1024 * 1024,
  timeout,
  env: { ...process.env, PATH: `${process.env.PATH}${EXTRA_PATH}` },
});

async function runAsync(cmd, args, timeout = 120_000) {
  // Windows에서 npx/ccusage는 .cmd 셔틀이라 셸 없이는 실행되지 않는데, shell:true에
  // 인자 배열을 주면 Node 24부터 DEP0190 경고가 붙는다. 그래서 ComSpec /d /c 로 직접
  // 감싼다 — /d는 shell:true도 내부에서 쓰던 AutoRun 억제로, 사용자 레지스트리의
  // AutoRun 출력(chcp·clink 등)이 JSON 파싱을 깨는 것을 막는다. 경로로 주어진 명령
  // (CodexBar CLI 같은 .exe)은 셸이 필요 없고 cmd 인용 규칙이 공백·괄호 경로를
  // 깨뜨리므로 직접 실행한다. cmd로 넘기는 인자는 모두 고정 문자열이다.
  // 한계: .cmd/.bat 경로는 cmd 경유가 불가피해 특수문자(공백+괄호, &) 경로는 지원하지 않는다.
  const viaCmd = WIN && (!/[\\/]/.test(cmd) || /\.(cmd|bat)$/i.test(cmd));
  const [file, argv] = viaCmd
    ? [process.env.ComSpec ?? "cmd.exe", ["/d", "/c", cmd, ...args]]
    : [cmd, args];
  // promisify된 execFile은 실패 시에도 err.stdout/stderr를 붙여준다
  return (await execFileAsync(file, argv, execOpts(timeout))).stdout;
}

async function runCcusage(args) {
  // 전역 설치본이 있으면 사용(빠름), 없으면 npx로 대체
  try {
    return JSON.parse(await runAsync("ccusage", args));
  } catch (e) {
    console.error(`ccusage 직접 실행 실패(${e.code ?? e.message}), npx로 재시도 — 'npm i -g ${CCUSAGE_PKG}'를 해두면 빨라집니다`);
    // --prefer-offline: npx 캐시가 있으면 레지스트리 조회 없이 재사용 (5분마다 재다운로드 방지)
    // 버전은 CCUSAGE_PKG로 고정 — @latest 자동 추적은 공급망 탈취를 무인 실행 채널로 만든다.
    return JSON.parse(await runAsync("npx", ["-y", "--prefer-offline", CCUSAGE_PKG, ...args], 300_000));
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
// {...prev} 전개가 collected_at을 그대로 보존하는 것이 신선도 규칙의 핵심 —
// 서버는 collected_at이 더 신선한 행만 덮어쓰므로, 토큰이 만료된 기기의 캐시 폴백이
// 건강한 기기가 방금 올린 값을 덮어쓰지 못한다. collected_at을 여기서 갱신하면 안 된다.
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

// Claude Code 자격증명: macOS는 Keychain, Windows/Linux는 ~/.claude/.credentials.json.
// macOS라도 SSH 세션의 Claude Code는 Keychain에 못 쓰고 파일에 토큰을 갱신하므로
// 한 곳만 읽으면 낡은 토큰으로 401/429를 반복할 수 있다. 둘 다 읽어 최신 쪽을 쓴다.
function freshestCredentials(sources) {
  const expiresAt = (c) => Number((c?.claudeAiOauth ?? c)?.expiresAt) || 0;
  return sources.reduce((a, b) => (expiresAt(b) > expiresAt(a) ? b : a));
}

async function claudeCredentials() {
  const sources = [];
  try {
    sources.push(JSON.parse(await runAsync("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])));
  } catch {}
  try {
    sources.push(JSON.parse(fs.readFileSync(path.join(HOME, ".claude", ".credentials.json"), "utf8")));
  } catch {}
  if (!sources.length) throw new Error("Claude Code 자격증명 없음");
  return freshestCredentials(sources);
}

// Claude: Claude Code OAuth 세션을 재사용해 공식 usage API 조회.
// 반환: { provider, status } — status "ok" | "auth_expired" | "error",
// 자격증명 자체가 없으면(미설치) status null이라 collect_status에 항목이 안 생긴다.
// fetchFn/loadCredentials는 테스트 주입용 — 기본값이면 기존 동작 그대로.
async function claudeProvider({ fetchFn = fetch, loadCredentials = claudeCredentials } = {}) {
  let cred;
  try {
    cred = await loadCredentials();
  } catch {
    return { provider: null, status: null }; // 자격증명 없음 = Claude Code 미설치
  }
  try {
    const oauth = cred.claudeAiOauth ?? cred;
    const token = oauth.accessToken;
    // rateLimitTier "default_claude_max_20x" → "Max 20x", 없으면 subscriptionType "max" → "Max"
    const tier = /max_(\d+)x/.exec(oauth.rateLimitTier ?? "");
    const plan = tier
      ? `Max ${tier[1]}x`
      : oauth.subscriptionType
        ? oauth.subscriptionType[0].toUpperCase() + oauth.subscriptionType.slice(1)
        : null;
    const res = await fetchFn("https://api.anthropic.com/api/oauth/usage", {
      headers: { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) {
      // 401 = 토큰 만료 (Claude Code를 한 번 실행하면 갱신됨), 그 외는 일시 장애일 가능성.
      // 이 구분이 서버 collect_status로 올라가 앱이 "재로그인 필요"를 안내할 수 있다.
      console.error(`claude usage API ${res.status}${res.status === 401 ? " — 토큰 만료, Claude Code를 실행하면 갱신됩니다" : ""}`);
      return { provider: null, status: res.status === 401 ? "auth_expired" : "error" };
    }
    const d = await res.json();
    // 계정 UUID → 해시 (프로필 조회 실패 시 null — 캐시 폴백이 채워준다)
    let account = null;
    try {
      const pr = await fetchFn("https://api.anthropic.com/api/oauth/profile", {
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
      provider: {
        id: "claude",
        name: "Claude",
        plan,
        account,
        session: dropExpired(win(d.five_hour, 300)),
        weekly: dropExpired(win(d.seven_day, 10080)),
        extras: extras.length ? extras : null,
        collected_at: new Date().toISOString(), // usage API 성공 시각
      },
      status: "ok",
    };
  } catch (e) {
    console.error(`claude 프로바이더 수집 실패: ${e.message ?? e}`);
    return { provider: null, status: "error" };
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
  if (!fs.existsSync(dir)) return null; // Codex 미설치
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
  // collected_at = 로그 파일 mtime — 스냅샷은 "지금"이 아니라 마지막 사용 시점의 값이므로
  // 수집 시각을 넣으면 다른 기기의 진짜 최신 데이터를 신선도 규칙에서 이겨버린다.
  return { session: win(rl.primary), weekly: win(rl.secondary), collected_at: new Date(latest.m).toISOString() };
}

// 반환: { provider, status } — live 성공 "ok", 스냅샷 폴백 "stale",
// ~/.codex는 있는데 둘 다 실패면 "error", 미설치면 status null(항목 없음).
async function codexProvider() {
  if (!fs.existsSync(path.join(HOME, ".codex"))) return { provider: null, status: null }; // Codex 미설치
  try {
    const auth = codexAuth();
    const live = await codexLiveWindows(auth);
    const snapshot = live ? null : codexSnapshotWindows();
    const windows = live ?? snapshot;
    if (!windows) return { provider: null, status: "error" };
    return {
      provider: {
        id: "codex",
        name: "Codex",
        plan: windows.plan ?? auth?.plan ?? null,
        account: auth?.account ?? null,
        session: dropExpired(windows.session),
        weekly: dropExpired(windows.weekly),
        extras: null,
        // live면 지금이 관측 시각, 스냅샷 폴백이면 .jsonl mtime이 실제 관측 시각
        collected_at: live ? new Date().toISOString() : snapshot.collected_at,
      },
      status: live ? "ok" : "stale",
    };
  } catch (e) {
    console.error(`codex 프로바이더 수집 실패: ${e.message ?? e}`);
    return { provider: null, status: "error" };
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
  // 불투명 식별자(계정 ID·조직)를 이메일보다 먼저 쓴다 — account는 salt 없는 sha256의
  // 앞 12자(48비트)라, 이메일을 넣으면 DB 유출 시 사전 대입으로 원문이 역산된다.
  // 고엔트로피 ID는 그 대입이 통하지 않는다. 이메일은 다른 식별자가 전혀 없을 때만 폴백.
  const rawAccount = textValue(
    identity.accountId,
    usage.accountId,
    identity.accountOrganization,
    usage.accountOrganization,
    identity.accountEmail,
    identity.email,
    usage.accountEmail,
    entry.accountEmail
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
    collected_at: new Date().toISOString(), // CodexBar CLI 성공 시각
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
  if (process.env.CHARGE_DISABLE_CODEXBAR === "1") return { providers: [], complete: false, statuses: {} };
  // 따옴표로 감싼 경로(Windows에서 흔한 습관)는 벗겨서 execFile에 그대로 넘긴다
  const cli = process.env.CHARGE_CODEXBAR_CLI?.replace(/^"(.*)"$/s, "$1")
    ?? (!WIN && fs.existsSync(DEFAULT_CODEXBAR_CLI) ? DEFAULT_CODEXBAR_CLI : null);
  if (!cli) return { providers: [], complete: false, statuses: {} };

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
      return { providers: [], complete: false, statuses: {} };
    }
  }

  const entries = parseCodexBarJSON(raw);
  if (!entries) {
    console.error("CodexBar 프로바이더 수집 실패: JSON 출력을 해석할 수 없습니다.");
    return { providers: [], complete: false, statuses: {} };
  }
  const bridgeEntries = entries.filter((entry) => !["claude", "codex"].includes(entry?.provider));
  const providers = [];
  const statuses = {};
  for (const entry of bridgeEntries) {
    if (entry?.error) {
      console.error(`CodexBar ${entry.provider ?? "프로바이더"} 수집 실패: ${entry.error.message ?? "알 수 없는 오류"}`);
      // claude/codex 상태는 자체 수집기가 판정한다 — entry.id로 새어 들어와도 덮지 않는다
      const id = textValue(entry.provider, entry.id)?.toLowerCase();
      if (id && id !== "claude" && id !== "codex") statuses[id] = "error";
      continue;
    }
    const provider = codexBarEntryToProvider(entry);
    if (!provider) continue; // 창이 하나도 없는 엔트리 — 성공도 실패도 아니라 상태 미기록
    providers.push(provider);
    statuses[provider.id] = "ok";
  }
  const complete = commandSucceeded && !bridgeEntries.some((entry) => entry?.error);
  return { providers, complete, statuses };
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
  if (claude.provider) claude.provider.status = claudeStatus;
  if (codex.provider) codex.provider.status = codexStatus;
  // collect_status: 미설치(status null)는 항목을 만들지 않는다 — 설치된 소스만 정직하게 보고
  const statuses = { ...codexBar.statuses };
  if (claude.status) statuses.claude = claude.status;
  if (codex.status) statuses.codex = codex.status;
  return {
    providers: [claude.provider, codex.provider, ...codexBar.providers].filter(Boolean),
    codexBarComplete: codexBar.complete,
    statuses,
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
async function pairedUpload(mode, daily, live, providers, collectStatus = null) {
  const post = (body) =>
    fetch(`${mode.url}/rest/v1/rpc/charge_upload`, {
      method: "POST",
      headers: {
        apikey: mode.anon,
        Authorization: `Bearer ${mode.anon}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
  const body = { p_token: mode.token, p_daily: daily, p_live: live, p_providers: providers, p_collect_status: collectStatus };
  let res = await post(body);
  if (res.ok) return;
  const text = await res.text();
  // 서버에 5번째 파라미터(p_collect_status)가 아직 배포 전이면 PostgREST가 함수
  // 시그니처를 못 찾아 404/PGRST202를 낸다 — 수집기가 먼저 업데이트된 배포 순서
  // 역전 대비로, 구버전 시그니처(파라미터 제외)로 1회만 재시도한다.
  if (res.status === 404 || text.includes("PGRST202")) {
    console.error("charge_upload 구버전 서버 감지(404/PGRST202) — p_collect_status 없이 재시도합니다");
    const { p_collect_status: _omitted, ...legacyBody } = body;
    res = await post(legacyBody);
    if (res.ok) return;
    throw new Error(`업로드 실패 (${res.status}): ${await res.text()}`);
  }
  throw new Error(`업로드 실패 (${res.status}): ${text}`);
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
    // 수집이 통째로 죽으면 상태를 알 수 없다 — null로 보내 정직한 미상 처리 (서버도 null로 덮음)
    providerCollection = { providers: [], codexBarComplete: false, statuses: null };
  }
  providers = providerCollection.providers;
  // 일부 프로바이더만 실패해도 목록에서 사라지지 않게 이전 값으로 채운다 (앱 설정 토글 유지).
  // 이렇게 캐시로 채운 프로바이더의 상태는 statuses에 이미 실패(auth_expired/error 등)로
  // 기록돼 있다 — 캐시 복원이 성공처럼 보이면 안 되므로 여기서 덮지 않는다.
  for (const prev of cache.providers ?? []) {
    if (providers.some((p) => p.id === prev.id)) continue;
    // CodexBar가 정상 완료된 경우, 거기서 더 이상 반환하지 않는 항목은 사용자가 끈 것으로 본다.
    if (providerCollection.codexBarComplete && prev.collector_source === "codexbar") continue;
    const sanitized = sanitizeCachedProvider(prev);
    if (sanitized) {
      // 0.1.4 이전 캐시엔 collected_at이 없다. 그대로 보내면 서버가 now()로 취급해
      // 나이 미상의 캐시가 건강한 기기의 진짜 최신 데이터를 이겨버린다 — epoch로 스탬프해
      // "언제 것인지 모르는 데이터는 항상 진다"로 만든다 (행 유지에는 지장 없음).
      if (!sanitized.collected_at) sanitized.collected_at = new Date(0).toISOString();
      providers.push(sanitized);
    }
  }
  // 계정 식별 실패 시 마지막으로 알려진 계정 해시 유지 (계정 미상('')과 실제 계정 행이 갈라지는 것 방지)
  for (const p of providers) {
    if (!p.account) p.account = (cache.providers ?? []).find((c) => c.id === p.id)?.account ?? null;
  }

  if (DRY_RUN) {
    console.log(JSON.stringify({ daily: daily.slice(-1), live, providers, collect_status: providerCollection.statuses }, null, 2));
    console.log(`\n[dry-run] daily ${daily.length}행 + live + providers ${providers.length}개 업로드 예정`);
    return;
  }

  const mode = resolveMode();
  if (!mode) {
    console.error("페어링이 안 돼 있습니다. 앱에서 코드를 발급받아 `npx charge-connect <코드>`를 실행하세요.");
    process.exit(1);
  }

  const now = new Date().toISOString();
  await pairedUpload(mode, daily, live, providers, providerCollection.statuses);

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
  CCUSAGE_PKG,
  accountHash,
  claudeProvider,
  codexBarEntryToProvider,
  collectCodexBarProviders,
  dropExpired,
  durationLabel,
  freshestCredentials,
  normalizeRateWindow,
  normalizeResetAt,
  parseCodexBarJSON,
  resolveMode,
  runAsync,
  sanitizeCachedProvider,
  titleCaseProvider,
  usefulPlan,
};
