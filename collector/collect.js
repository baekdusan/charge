#!/usr/bin/env node
// Charge 수집기 — ccusage로 토큰 사용량을 뽑아 Charge 백엔드에 업로드한다.
// 사용법: node collect.js [--dry-run] [--days N] [--log 경로] | node collect.js --self-test (자동 업데이트용 자체 점검)
// 인증: `npx charge-connect <페어링코드>`가 저장한 ~/.charge/config.json의 디바이스 토큰

const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const fs = require("node:fs");
const path = require("node:path");

const execFileAsync = promisify(execFile);

const DRY_RUN = process.argv.includes("--dry-run");
// 자동 업데이트가 교체 전후에 부르는 자체 점검: 런타임 모듈을 모두 불러오기만 하고 끝낸다 (파일 맨 아래)
const SELF_TEST = process.argv.includes("--self-test");
const daysArg = process.argv.indexOf("--days");
const parsedDays = daysArg > -1 ? parseInt(process.argv[daysArg + 1], 10) : NaN;
const DAYS = Number.isFinite(parsedDays) && parsedDays > 0 ? parsedDays : 60;
const CACHE_FILE = path.join(__dirname, ".last-payload.json");
const HEALTH_FILE = path.join(__dirname, ".collection-health.json");
// Claude usage API 429 게이트와 마지막 usage 요청 시각, 결과 (C1, D12, D13). 프로필 조회로 얻은 계정 해시 (D3)
const RATE_LIMIT_FILE = path.join(__dirname, ".claude-rate-limit.json");
const CLAUDE_ACCOUNT_FILE = path.join(__dirname, ".claude-account.json");
const HOME = process.env.HOME ?? process.env.USERPROFILE;

// 스케줄러가 부를 때는 볼 콘솔이 없으니 출력을 직접 파일로 받는다.
// 셸 리다이렉션(cmd `>`)에 맡기면 경로의 %VAR% 확장·로그 잠금 같은 문제를 떠안게 된다.
// 5분마다 도는 작업이라 그냥 이어 붙이면 끝없이 자라므로 5MB에서 .old로 민다.
const logArg = process.argv.indexOf("--log");
const LOG_FILE = logArg > -1 ? process.argv[logArg + 1] : null;
// main의 프라미스 밖에서 터진 예외(타이머, 이벤트, 기다리지 않은 거부)로 끝낼 때도 업데이트 확인을 기다리는 최대 시간.
// 확인은 매니페스트, 다운로드, 검사, 자체 점검까지 합쳐도 이보다 짧다. 5분 주기 안에서 끝낸다.
const CRASH_UPDATE_CHECK_LIMIT_MS = 180_000;
let crashExitStarted = false;
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
    exitAfterUpdateCheck();
  };
  process.on("uncaughtException", fatal("치명적 오류"));
  process.on("unhandledRejection", fatal("처리되지 않은 거부"));
  // 시작 줄을 바로 남긴다 — '언제 마지막으로 돌았나'를 알 수 있고,
  // install.ps1이 스케줄 작업이 실제로 떴는지 판정하는 근거이기도 하다.
  write(`[${new Date().toISOString()}] 수집 시작`);
}

// 자동 업데이트가 파일 교체 도중 끊겼으면(전원 차단, 작업 강제 종료) 다른 로컬 모듈을 불러오기 전에 app.prev로
// 되돌린다. 옛 파일과 새 파일이 섞인 채 require하면 바로 아래에서 죽어 다음 업데이트 확인까지 닿지 못한다.
// 평소에는 표시 파일(updater.js의 UPDATE_MARKER)이 있는지만 본다. 자체 점검은 상태를 건드리지 않으므로 되돌리지
// 않는다 (설치 직후 점검 중에는 표시가 있는 게 정상이다). updater.js는 node: 내장 모듈만 불러와서 섞인 폴더에서도 뜬다.
if (require.main === module && !SELF_TEST && fs.existsSync(path.join(__dirname, ".update-in-progress.json"))) {
  let running = null;
  try {
    running = fs.readFileSync(__filename);
  } catch {}
  try {
    const updater = require("./updater.js");
    // 표시를 쓴 업데이트가 아직 살아서 파일을 바꾸는 중이면(겹친 스케줄 실행, 수동 실행, 설치 후 자체 점검 중) 되돌리지 않고
    // 이번 수집만 건너뛴다. 여기서 되돌리면 그 업데이트 밑에서 폴더가 섞이거나, 멀쩡한 릴리스가 자체 점검 실패로 기록된다.
    if (typeof updater.updateInProgress === "function" && updater.updateInProgress({ appDir: __dirname })) {
      console.log("자동 업데이트가 수집기 파일을 교체하는 중이라 이번 수집은 건너뜁니다");
      process.exit(0);
    }
    updater.recoverInterruptedUpdate({ appDir: __dirname });
    console.error("교체 도중 끊긴 자동 업데이트를 app.prev 백업으로 되돌렸습니다");
    // 지금 도는 collect.js가 새 버전이었다면 되돌린 파일과 내용이 다르다. 이 코드로 계속 돌면 옛 모듈과 섞이므로
    // 되돌린 collect.js를 같은 인자로 다시 실행하고 그 종료 코드로 끝낸다 (드문 복구 경로라 동기 실행을 쓴다).
    if (!running || !running.equals(fs.readFileSync(__filename))) {
      const rerun = require("node:child_process").spawnSync(
        process.execPath,
        [...process.execArgv, __filename, ...process.argv.slice(2)],
        { stdio: "inherit", windowsHide: true }
      );
      process.exit(rerun.status ?? 1);
    }
  } catch (e) {
    console.error(`교체 도중 끊긴 자동 업데이트를 되돌리지 못했습니다: ${e?.message ?? e}`);
  }
}
const { unknownAccountKey } = require("./identity.js");

// collect_status의 "_collector"와 User-Agent에 싣는 버전. 읽지 못하면 싣지 않는다.
// 끊긴 업데이트를 되돌린 뒤에 읽어야 이번 실행이 실제로 쓰는 파일의 버전이 된다.
const PACKAGE_VERSION = (() => {
  try {
    const version = JSON.parse(fs.readFileSync(path.join(__dirname, "package.json"), "utf8")).version;
    return typeof version === "string" && /^[0-9A-Za-z.+-]{1,32}$/.test(version) ? version : null;
  } catch {
    return null;
  }
})();
const USER_AGENT = PACKAGE_VERSION ? `charge-connect/${PACKAGE_VERSION}` : "charge-connect";

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

// 퍼센트 수치 파싱, 값이 있을 때만 숫자를 돌려주고, 비었으면 null.
// Number()에 맡기면 안 된다: Number(null), Number(""), Number(false), Number([])는 전부 0이고
// finite라, "수치가 비었다"와 "진짜 0%(정상 사용 0)"가 구분되지 않는다. 빈 값이 0%로 올라가면
// 서버 입장에선 멀쩡한 값이라(빈 창 가드는 JSON null만 보존한다) 다른 기기가 올린 게이지를 0으로 덮는다.
// 숫자이거나 공백 아닌 숫자 문자열일 때만 값으로 인정한다.
function percentValue(v) {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v !== "string" || !v.trim()) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
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
// 리셋 시각을 모르는 창은 dropExpired로 절대 만료되지 않아, 수집이 깨진 기기가 몇 주 전 값을
// 계속 재생한다(앱엔 "0% 사용"처럼 보인다). 관측 후 창 길이(세션 300분, 주간 10080분)가 지났으면
// 그 창은 이미 한 번 이상 리셋됐다고 보고 버린다. 관측 시각을 모르면 나이를 증명할 수 없어 버린다.
function dropUnknownResetIfOld(w, collectedAt, fallbackMinutes, now = Date.now()) {
  if (!w || w.resets_at) return w;
  const minutes = Number(w.window_minutes) > 0 ? Number(w.window_minutes) : fallbackMinutes;
  const observed = Date.parse(collectedAt ?? "");
  if (!Number.isFinite(observed)) return null;
  return now - observed > minutes * 60_000 ? null : w;
}

function sanitizeCachedProvider(prev, now = Date.now()) {
  if (!prev || typeof prev !== "object") return null;
  const replay = (w, fallbackMinutes) => dropUnknownResetIfOld(dropExpired(w), prev.collected_at, fallbackMinutes, now);
  const extras = (prev.extras ?? [])
    .map((extra) => ({ ...extra, window: replay(extra.window, 10_080) }))
    .filter((extra) => extra.window);
  const session = replay(prev.session, 300);
  const weekly = replay(prev.weekly, 10_080);
  // 만료를 걷어내고 표시할 창이 하나도 안 남으면 복원 대상에서 뺀다(null).
  // 전부 null인 껍데기를 며칠 묵은 collected_at과 함께 올리면 앱엔 빈 카드가 뜨고,
  // 서버 행의 나이가 그 옛 시각으로 되감겨 다른 기기의 묵은 업로드까지 신선도 가드를 통과한다.
  // 결과적으로 그 프로바이더는 이번 페이로드에서 통째로 빠진다, 서버의 은퇴 delete에는
  // 20분 유예가 있어, 한두 사이클 빠졌다가 다시 관측되면 카드가 사라지지 않는다.
  if (!session && !weekly && !extras.length) return null;
  return {
    ...prev,
    session,
    weekly,
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
  // 후보마다 percentValue를 적용해 '유효한' 첫 값을 고른다. ?? 체인은 null/undefined만
  // 건너뛰므로 "", false, []가 앞자리에 있으면 Number()에서 0으로 둔갑해 그대로 굳었다 , 
  // 즉 이 폴백의 의미가 "null/undefined 건너뛰기"에서 "유효하지 않은 값 건너뛰기"로 바뀐다.
  // 빈 수치를 0%로 올리면 서버의 빈 창 가드를 통과해 다른 기기의 멀쩡한 게이지를 덮는다.
  const percent = [window.usedPercent, window.percent, window.utilization]
    .map(percentValue)
    .find((value) => value !== null);
  if (percent === undefined) return null;
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

// run은 테스트 주입용, 기본값이면 기존 동작 그대로.
async function collectLive({ run = runCcusage } = {}) {
  const data = await run(["blocks", "--active", "--json"]);
  const block = (data.blocks ?? []).find((b) => b.isActive) ?? null;
  // collected_at = 이 블록을 실제로 관측한 시각. 서버가 charge_live 신선도 판정에 쓴다 , 
  // 수집이 깨진 기기가 캐시된 옛 블록을 5분마다 재업로드해도 최신 블록을 덮지 못한다.
  // 캐시 폴백은 cache.live를 통째로 재사용하므로 이 값이 갱신되지 않고 나이가 보존된다.
  return block ? { ...block, collected_at: new Date().toISOString() } : null;
}

// 잠에서 깬 직후에는 스케줄러가 Wi-Fi보다 먼저 돌아 fetch가 즉시 "fetch failed"로 죽는다.
// 그 사이클을 통째로 버리면 다음 5분까지 묵은 캐시가 올라가므로, 네트워크 계층 실패(HTTP
// 응답을 못 받은 경우)만 짧게 한 번 더 시도한다. 상태 코드가 온 요청은 재시도하지 않는다
// (401을 두 번 물어봐야 답이 같고, 5분마다 도는 작업이라 재시도는 최소로).
// 타임아웃 시그널은 반드시 시도마다 새로 만든다, 호출자가 만든 signal을 두 시도가 나눠 쓰면
// 1차가 예산 후반에 죽었을 때 2차는 대기 시간만큼 이미 지난 예산을 물려받아 즉시 abort된다.
// 재시도가 무의미해지는 것도 문제지만, 로그에 남는 원인이 "fetch failed"에서
// "This operation was aborted"로 바뀌어 진짜 원인(네트워크 미연결)을 가린다.
async function fetchOnceRetried(fetchFn, url, options, { timeoutMs = 10_000, delayMs = 4000 } = {}) {
  const attempt = () => fetchFn(url, { ...options, signal: AbortSignal.timeout(timeoutMs) });
  try {
    return await attempt();
  } catch (e) {
    if (e?.name === "AbortError" || e?.name === "TimeoutError") throw e;
    await new Promise((r) => setTimeout(r, delayMs));
    return attempt();
  }
}

// 이 시각 안에 만료되는 토큰은 이미 만료된 것으로 본다 (요청이 도착할 즈음엔 401이다)
const EXPIRY_MARGIN_MS = 30_000;

// Claude Code의 expiresAt은 epoch 밀리초 숫자다. 1e11보다 작으면 초로 보고 바꾼다.
// 숫자가 아닌 값(문자열 포함), 0 이하, 무한대는 만료 시각을 모르는 것으로 둔다.
function epochMs(value) {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return null;
  return value < 1e11 ? value * 1000 : value;
}

// Claude Code 자격증명: macOS는 Keychain, Windows/Linux는 ~/.claude/.credentials.json.
// macOS라도 SSH 세션의 Claude Code는 Keychain에 못 쓰고 파일에 토큰을 갱신하므로
// 한 곳만 읽으면 낡은 토큰으로 401/429를 반복할 수 있다. 둘 다 읽어 쓸 수 있는 쪽을 고른다 (D2):
// 만료 시각이 미래인 소스 중 가장 늦은 것, 없으면 만료 미상 소스 중 앞선 것(Keychain 우선),
// 모두 만료됐으면 가장 늦게 만료된 것(로컬 만료 확인이 요청 없이 auth_expired로 보고한다).
function freshestCredentials(sources, now = Date.now()) {
  const expiry = (c) => epochMs((c?.claudeAiOauth ?? c)?.expiresAt);
  const latest = (list) => list.reduce((a, b) => (expiry(b) > expiry(a) ? b : a));
  const live = sources.filter((c) => expiry(c) !== null && expiry(c) > now + EXPIRY_MARGIN_MS);
  if (live.length) return latest(live);
  return sources.find((c) => expiry(c) === null) ?? latest(sources);
}

function claudeCredentialLocation(env = process.env, home = HOME) {
  const configDir = (env.CLAUDE_CONFIG_DIR || path.join(home, ".claude")).normalize("NFC");
  // Claude Code supports a separate credential store; an explicit empty override
  // selects the default store even when CLAUDE_CONFIG_DIR points elsewhere.
  const override = env.CLAUDE_SECURESTORAGE_CONFIG_DIR;
  const storageDir = (override !== undefined ? override || path.join(home, ".claude") : configDir).normalize("NFC");
  const scoped = override !== undefined ? !!override : !!env.CLAUDE_CONFIG_DIR;
  const suffix = scoped
    ? `-${require("node:crypto").createHash("sha256").update(storageDir).digest("hex").slice(0, 8)}` : "";
  // Claude Code 전역 설정 파일: CLAUDE_CONFIG_DIR가 있으면 그 안, 없으면 홈 바로 아래 .claude.json
  const globalConfig = env.CLAUDE_CONFIG_DIR ? path.join(configDir, ".claude.json") : path.join(home, ".claude.json");
  // 자격증명 저장소가 설정 폴더와 같을 때만 .claude.json의 계정이 그 자격증명의 계정이라고 볼 수 있다
  const sharedStore = path.resolve(storageDir) === path.resolve(configDir);
  return { configDir, file: path.join(storageDir, ".credentials.json"), service: `Claude Code-credentials${suffix}`, globalConfig, sharedStore };
}

// 반환하는 자격증명에는 고른 소스("keychain" 또는 "file")를 credentialSource로 붙인다 (진단 로그용)
async function claudeCredentials({ env = process.env, home = HOME, run = runAsync, read = fs.readFileSync, now = Date.now() } = {}) {
  const location = claudeCredentialLocation(env, home);
  const sources = [];
  try {
    sources.push({ source: "keychain", data: JSON.parse(await run("security", ["find-generic-password", "-s", location.service, "-w"], 10_000)) });
  } catch {}
  try {
    sources.push({ source: "file", data: JSON.parse(read(location.file, "utf8")) });
  } catch {}
  const usable = sources.filter(({ data }) => typeof (data?.claudeAiOauth ?? data)?.accessToken === "string"
    && (data.claudeAiOauth ?? data).accessToken.trim());
  if (!usable.length) throw new Error("Claude Code 구독 로그인 정보를 읽을 수 없음");
  const chosen = freshestCredentials(usable.map(({ data }) => data), now);
  return { ...chosen, credentialSource: usable.find(({ data }) => data === chosen).source };
}

const CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
const CLAUDE_PROFILE_URL = "https://api.anthropic.com/api/oauth/profile";
// 같은 Charge 사용자의 기기 중 누가 이번 주기에 Claude usage를 물을지 서버 임대(charge_claim_poll)로 정한다.
// 임대 확인이 이 시간 안에 끝나지 않으면 기다리지 않고 평소처럼 수집한다 (막는 쪽으로 실패하지 않는다).
const LEASE_TIMEOUT_MS = 5_000;
// 이 기기의 Claude usage 요청 사이 최소 간격 (D13). 잠에서 깬 launchd가 몰아서 띄운 실행이 정규 실행 몇 초 전에
// 떨어지면 한 주기에 두 번 묻게 된다. 5분 주기보다 짧아야 정규 실행은 막히지 않는다.
const MIN_REQUEST_SPACING_MS = 240_000;
// 최소 간격 판단(상태 읽기, 판단, 요청 시각 예약)을 프로세스 사이에서 직렬화하는 잠금(상태 파일 옆 .lock)이 이보다 오래됐으면
// 만든 실행이 죽은 것으로 보고 넘겨받는다. 잠금은 몇 밀리초만 잡으므로 그보다 오래 남은 잠금은 죽은 실행의 흔적이다.
const REQUEST_LOCK_STALE_MS = 60_000;
// 요청이 계속 실패하는 기기는 마지막으로 임대를 잡은 뒤 이 시간 안에는 임대를 다시 잡지 않는다 (한 주기 거른다).
// 서버 임대(270초)가 그 사이에 끝나 같은 사용자의 다른 기기가 넘겨받을 수 있다. 5분 주기 한 번보다 길고 두 번보다 짧다.
const FAILING_LEASE_INTERVAL_MS = 540_000;
const RATE_LIMIT_MIN_BACKOFF_S = 300;
const RATE_LIMIT_MAX_BACKOFF_S = 1800;
const RATE_LIMIT_MARGIN_S = 60;
// Retry-After가 비정상적으로 크면(서버 오류, 시계 문제) 기기가 며칠씩 침묵한다, 하루로 자른다
const RETRY_AFTER_CAP_S = 86_400;
const ERROR_BODY_CAP_BYTES = 2048;
// 프로필 조회가 일시적으로 실패하면(429, 5xx, 네트워크) 같은 토큰이라도 이 시간 뒤 다시 묻는다
const PROFILE_RETRY_MS = 3600_000;
// 서버가 401로 거절한 액세스 토큰은 바뀔 때까지 다시 쓰지 않는다. 일시적인 401일 수도 있어 이 시간이 지나면 한 번 확인한다
const REJECTED_TOKEN_RETRY_MS = 3600_000;

// 토큰 원문 대신 저장하는 짧은 식별자 (같은 토큰인지 비교만 한다)
function credentialKey(secret) {
  if (typeof secret !== "string" || !secret) return null;
  return require("node:crypto").createHash("sha256").update(secret).digest("hex").slice(0, 16);
}

function readStateFile(file) {
  if (!file) return null;
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

// 상태 파일은 임시 파일에 쓰고 이름을 바꿔 교체한다, 도중에 죽어도 반쪽 JSON이 남지 않는다
function writeStateFile(file, data) {
  if (!file) return false;
  const temporary = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(temporary, JSON.stringify(data), { mode: 0o600 });
    fs.renameSync(temporary, file);
    return true;
  } catch {
    return false;
  } finally {
    try { fs.rmSync(temporary, { force: true }); } catch {}
  }
}

function processAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    // EPERM은 프로세스가 살아 있지만 신호를 보낼 권한이 없다는 뜻이다
    return e?.code === "EPERM";
  }
}

// D13: 이 기기의 겹친 실행(스케줄 실행과 수동 `charge-connect run`, 깨어난 뒤 몰아서 뜬 실행)이 둘 다 옛 요청 기록을 읽고 둘 다
// usage를 묻지 않게, 상태 파일 옆의 <상태 파일>.lock으로 "상태 다시 읽기, 게이트와 간격 판단, 요청 시각 예약"을 프로세스 사이에서
// 직렬화한다. 'wx'로 만들며 내용은 { pid, at }이다. 만든 프로세스가 죽었거나 REQUEST_LOCK_STALE_MS가 지난 잠금은 낡은 것으로
// 보고 넘겨받는다. 지우고 다시 만드는 것은 원자적이지 않아(같은 잠금을 낡았다고 본 두 실행이 서로의 새 잠금을 지워 둘 다 잡는다)
// updater.js의 takeOverStaleLock으로 넘겨받기를 직렬화하고, 잠금이 그사이 바뀌지 않았을 때만 지운다. 내용을 읽을 수 없는
// 잠금(막 만들어져 아직 비어 있을 수 있다)은 파일 시각으로만 낡았는지 본다.
// 반환: 잡았으면 { acquired: true, release }, 살아 있는 다른 실행이 잡고 있거나 넘겨받는 중이면 { acquired: false, held: true },
// 예상 밖의 파일 오류(권한, 폴더 없음, 지울 수 없는 낡은 잠금)면 { acquired: false, held: false, error }. 던지지 않는다.
function acquireClaudeRequestLock(stateFile, now = Date.now(), { isAlive = processAlive } = {}) {
  const noop = () => {};
  if (!stateFile) return { acquired: false, held: false, error: null, release: noop };
  const file = `${stateFile}.lock`;
  const body = JSON.stringify({ pid: process.pid, at: now });
  // 반환: 만들었으면 true, 이미 있으면 false, 그 밖의 오류면 그 오류
  const create = () => {
    try {
      fs.writeFileSync(file, body, { flag: "wx", mode: 0o600 });
      return true;
    } catch (e) {
      return e?.code === "EEXIST" ? false : e ?? new Error("lock");
    }
  };
  // 이 실행이 만든 잠금만 지운다 (그사이 낡았다고 판정한 다른 실행이 새로 만든 잠금을 지우지 않게)
  const release = () => {
    try {
      if (fs.readFileSync(file, "utf8") === body) fs.rmSync(file, { force: true });
    } catch {}
  };
  let created = create();
  if (created === false) {
    try {
      // 넘겨받기 도구는 updater.js에 있다 (섞인 폴더에서 못 불러오면 잠금 없이 판단하는 쪽으로 떨어진다, 수집은 멈추지 않는다)
      const { lockFingerprint, takeOverStaleLock } = require("./updater.js");
      const seen = lockFingerprint(file);
      if (!seen) {
        // 그사이 풀렸으면 다시 만들어 본다
        created = create();
      } else {
        let info = null;
        try {
          info = JSON.parse(seen.content);
        } catch {}
        const at = Number(info?.at);
        const pid = info?.pid;
        const age = Number.isFinite(at) ? Math.abs(now - at) : Math.abs(Date.now() - seen.mtimeMs);
        if (age > REQUEST_LOCK_STALE_MS || (Number.isSafeInteger(pid) && pid > 0 && !isAlive(pid))) {
          created = takeOverStaleLock(file, seen.key, create, REQUEST_LOCK_STALE_MS);
        }
      }
    } catch (e) {
      created = e ?? new Error("lock");
    }
  }
  if (created === true) return { acquired: true, held: false, error: null, release };
  if (created === false) return { acquired: false, held: true, error: null, release: noop };
  return { acquired: false, held: false, error: created, release: noop };
}

// Retry-After: 초(정수) 또는 HTTP 날짜. 반환은 지금부터 기다릴 초(0 이상), 해석할 수 없으면 null.
function parseRetryAfter(value, now = Date.now()) {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (/^\d+$/.test(text)) return Math.min(Number(text), RETRY_AFTER_CAP_S);
  // Date.parse는 "1.5" 같은 문자열도 날짜로 받아준다, HTTP 날짜 모양(영문 요일/월, 시:분:초)일 때만 믿는다
  if (!/[A-Za-z]{3}/.test(text) || !/\d{1,2}:\d{2}:\d{2}/.test(text)) return null;
  // RFC 9110의 HTTP 날짜는 세 형식 모두 GMT다. asctime 형식("Sun Nov  6 08:49:37 1994")에는 시간대 표기가 없어
  // Date.parse가 이 PC의 현지 시각으로 읽으므로(KST면 9시간 어긋난다), 표기가 없으면 GMT를 붙여 읽는다
  const at = Date.parse(/\b(?:GMT|UTC)\b|\s[+-]\d{4}\b/i.test(text) ? text : `${text} GMT`);
  if (!Number.isFinite(at)) return null;
  return Math.min(Math.max(0, Math.ceil((at - now) / 1000)), RETRY_AFTER_CAP_S);
}

// 저장된 429 게이트: { account, credential, retryAt(ms), backoff(초), cause }. 깨졌거나 말이 안 되면 게이트 없음.
// account는 게이트를 건 요청 때 알던 계정 해시(모르면 null), credential은 그때의 자격증명 키,
// cause는 기한의 출처다 ("retry-after" = 서버가 준 N초, "backoff" = Retry-After 0/없음/깨짐에서 계산한 값).
function parseRateLimitGate(gate, now = Date.now()) {
  if (!gate || typeof gate !== "object") return null;
  if (typeof gate.credential !== "string" || !/^[0-9a-f]{16}$/.test(gate.credential)) return null;
  const account = gate.account ?? null;
  if (account !== null && !(typeof account === "string" && /^[0-9a-f]{12}$/.test(account))) return null;
  if (gate.cause !== "retry-after" && gate.cause !== "backoff") return null;
  const retryAt = Number(gate.retryAt);
  const backoff = Number(gate.backoff);
  if (!Number.isFinite(retryAt) || !Number.isFinite(backoff) || backoff < 0 || backoff > RATE_LIMIT_MAX_BACKOFF_S) return null;
  // 시계가 크게 뒤로 가면 가능한 최대 대기보다 먼 미래가 된다, 그런 기록은 믿지 않는다
  if (retryAt - now > (RETRY_AFTER_CAP_S + RATE_LIMIT_MARGIN_S) * 1000) return null;
  return { account, credential: gate.credential, retryAt, backoff, cause: gate.cause };
}

// Claude 요청 상태 파일: { gate, lastRequestAt, lastStatus, lastToken, leaseAt? }. 부분마다 따로 검증해 한쪽이 깨져도 다른 쪽은 쓴다.
// lastRequestAt/lastStatus는 마지막 usage 요청 시도(응답이 무엇이든, 네트워크 실패 포함)의 시각과 결과,
// lastToken은 그 요청에 쓴 액세스 토큰의 키(credentialKey)다. 모르면 token null.
// 요청은 보내기 직전에 시각을 먼저 적고 결과는 그 전 요청의 것을 둔다. 그 전 결과가 없으면 lastStatus null(응답 대기 중)이다.
// leaseAt은 이 기기가 마지막으로 조회 임대를 잡은 시각이다.
function readClaudeRequestState(file, now = Date.now()) {
  const saved = readStateFile(file);
  const at = Number(saved?.lastRequestAt);
  const status = saved?.lastStatus;
  const token = typeof saved?.lastToken === "string" && /^[0-9a-f]{16}$/.test(saved.lastToken) ? saved.lastToken : null;
  const lastRequest = saved?.lastRequestAt != null && Number.isFinite(at)
    && (status === null || (typeof status === "string" && /^[a-z_:]{1,40}(;[a-z_]{1,20}=[0-9A-Za-z._-]{0,40}){0,8}$/.test(status)))
    ? { at, status, token }
    : null;
  const leaseAt = typeof saved?.leaseAt === "number" && Number.isFinite(saved.leaseAt) ? saved.leaseAt : null;
  return { gate: parseRateLimitGate(saved?.gate, now), lastRequest, leaseAt };
}

function sameRateLimitGate(a, b) {
  if (!a || !b) return a === b;
  return a.account === b.account && a.credential === b.credential && a.retryAt === b.retryAt && a.backoff === b.backoff && a.cause === b.cause;
}

// D12: 게이트는 계정을 알면 계정 단위, 모르면 자격증명 단위로 적용한다. 서버가 Retry-After N초로 준 기한은
// 토큰이 바뀌어도 지나기 전까지 지킨다. Retry-After 0/없음/깨짐에서 나온 백오프만 자격증명이 바뀐 직후 한 번
// 확인해 볼 수 있다 (그 요청이 또 429면 백오프는 이어서 늘어난다). 확실히 다른 계정이면 그 계정의 한도가 아니다.
function blockingRateLimitGate(gate, { account = null, credential = null } = {}, now = Date.now()) {
  if (!gate || now >= gate.retryAt) return null;
  if (gate.account && account && gate.account !== account) return null;
  if (gate.cause === "backoff" && gate.credential !== credential) return null;
  return gate;
}

// 429를 받은 뒤의 게이트. 자격증명이 바뀌어 곧바로 보낸 첫 요청이 또 429여도 백오프는 5분으로
// 되돌리지 않고 이전 값에서 이어서 늘린다 (토큰 갱신이 한도 창을 비워주지는 않는다). 다른 계정의 백오프는 잇지 않는다.
function nextRateLimitGate(previous, { account = null, credential = null } = {}, retryAfter = null, now = Date.now()) {
  const seconds = parseRetryAfter(retryAfter, now);
  const otherAccount = Boolean(previous?.account && account && previous.account !== account);
  const previousBackoff = previous && !otherAccount ? previous.backoff : 0;
  if (seconds !== null && seconds > 0) {
    return { account, credential, retryAt: now + (seconds + RATE_LIMIT_MARGIN_S) * 1000, backoff: previousBackoff, cause: "retry-after" };
  }
  // Retry-After가 0, 없음, 깨짐 = 창이 가득 찼다는 뜻, 최소 5분에서 1.5배씩 30분까지
  const backoff = Math.min(RATE_LIMIT_MAX_BACKOFF_S, Math.max(RATE_LIMIT_MIN_BACKOFF_S, Math.round(previousBackoff * 1.5)));
  return { account, credential, retryAt: now + backoff * 1000, backoff, cause: "backoff" };
}

// 로그 조각에서 제어 문자(줄바꿈, 터미널 이스케이프, 글자 방향 전환)를 공백으로 바꾼다. 로그 줄 위조를 막는다.
function stripControlCharacters(text) {
  return String(text ?? "").replace(/[\p{Cc}\p{Bidi_Control}\p{Zl}\p{Zp}]/gu, " ");
}

// 오류 응답 본문은 로그에 조금만 남기고, 토큰처럼 보이는 값(긴 base64/hex, sk-, Bearer)은 지운다.
// 제어 문자는 자르기 전에 먼저 지운다 (잘린 경계에 이스케이프 조각이 남지 않게).
function sanitizeLogSnippet(text, max = 200) {
  return stripControlCharacters(text)
    .replace(/Bearer\s+[^\s"',;]+/gi, "Bearer [redacted]")
    .replace(/sk-[A-Za-z0-9_-]+/g, "[redacted]")
    .replace(/[A-Za-z0-9+/_=-]{32,}/g, "[redacted]")
    .replace(/\b[0-9a-fA-F]{24,}\b/g, "[redacted]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, max);
}

async function readBodySnippet(res, cap = ERROR_BODY_CAP_BYTES) {
  try {
    if (res?.body && typeof res.body.getReader === "function") {
      const reader = res.body.getReader();
      const chunks = [];
      let total = 0;
      while (total < cap) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(Buffer.from(value));
        total += value.byteLength;
      }
      reader.cancel().catch(() => {});
      return Buffer.concat(chunks).subarray(0, cap).toString("utf8");
    }
    if (typeof res?.text === "function") return String(await res.text()).slice(0, cap);
  } catch {}
  return "";
}

// 401 본문으로 사용자 조치를 가른다 (D8). 해지나 무효 자격증명이 분명할 때만 다시 로그인하라고 하고,
// 그 밖의 401은 만료로 본다 (Claude Code를 한 번 열면 풀린다). "invalid"만으로는 무효로 보지 않는다.
const REVOKED_BODY_PATTERN = /revoked|invalid[_ ]grant|invalid (authentication|bearer|access) (credentials|token)/i;
function unauthorizedStatus(body) {
  return REVOKED_BODY_PATTERN.test(String(body ?? "")) ? "auth_expired:revoked" : "auth_expired";
}

async function logHttpFailure(label, res, body = null, hint = "") {
  const retryAfter = res.headers?.get?.("retry-after") ?? null;
  const snippet = sanitizeLogSnippet(body ?? await readBodySnippet(res));
  console.error(`${label} ${res.status} (Retry-After: ${retryAfter === null ? "없음" : sanitizeLogSnippet(retryAfter, 64)})${snippet ? ` ${snippet}` : ""}${hint}`);
}

// 이번 사이클에 Claude usage 요청을 보내지 않았으면 이유와 함께 정확히 한 줄 남긴다 (D7).
// reason: expired, rejected(서버가 401로 거절한 토큰), gated, shared, spacing, no-credentials. 자격증명 세대(토큰 해시 앞 8자)와 계정 해시는
// 비밀이 아니라 함께 적는다. 토큰, uuid, 이메일은 넣지 않는다. 값은 제어 문자를 지운 뒤 자른다.
// spacing에 reason=lock이 붙으면 이 기기의 다른 실행이 마침 간격 잠금을 잡고 판단하는 중이라 물러난 것이다.
function logClaudeNoRequest(reason, fields = {}, hint = "") {
  const detail = Object.entries(fields)
    .filter(([, value]) => value !== null && value !== undefined && value !== "")
    .map(([key, value]) => `${key}=${sanitizeLogSnippet(value, 64)}`)
    .join(" ");
  const line = `claude usage 요청 안 함 (${reason})${detail ? ` ${detail}` : ""}${hint ? `, ${hint}` : ""}`;
  if (reason === "shared" || reason === "spacing") console.log(line);
  else console.error(line);
}

// 요청을 보내지 않은 rate_limited 사이클에는 ";deferred=1"을 붙인다 (앱이 시도 횟수 대신 기간으로 안내할 수 있게).
// 다른 접두사는 그대로 둔다.
function deferredStatus(status) {
  const [prefix, ...params] = String(status).split(";");
  if (prefix !== "error:rate_limited") return status;
  return [prefix, ...params.filter((param) => param && !param.startsWith("deferred=")), "deferred=1"].join(";");
}

// Claude Code 전역 설정(.claude.json)의 oauthAccount.accountUuid, 요청 없이 계정을 알아낸다.
// 프로필 API의 account.uuid와 같은 값이라 accountHash 결과도 같다. 다만 자격증명 저장소가 설정 폴더와 다르면
// (CLAUDE_SECURESTORAGE_CONFIG_DIR가 다른 곳) 이 계정이 지금 자격증명의 계정이라는 보장이 없어 읽지 않는다.
// uuid는 로그에 남기지 않는다.
async function readClaudeAccountUuid({ env = process.env, home = HOME, readFile = fs.promises.readFile } = {}) {
  const location = claudeCredentialLocation(env, home);
  if (!location.sharedStore) return null;
  try {
    const config = JSON.parse(await readFile(location.globalConfig, "utf8"));
    const uuid = config?.oauthAccount?.accountUuid;
    return typeof uuid === "string" && uuid ? uuid : null;
  } catch {
    return null;
  }
}

// 이 자격증명 키로 프로필을 이미 물어봤으면 { account } (실패였으면 account null), 아니면 null
// 일시적 실패 기록(retryAt)은 그 시각까지만 쓰고, 지나면 null을 줘 다시 묻게 한다.
function readAccountCache(file, credential, now = Date.now()) {
  const saved = readStateFile(file);
  if (!saved || !credential || saved.credential !== credential) return null;
  if (saved.retryAt !== undefined) {
    const retryAt = Number(saved.retryAt);
    // 시계가 크게 뒤로 가 재시도 시각이 대기 시간보다 먼 미래가 된 기록은 믿지 않는다
    if (!Number.isFinite(retryAt) || now >= retryAt || retryAt - now > PROFILE_RETRY_MS) return null;
  }
  return { account: typeof saved.account === "string" && /^[0-9a-f]{12}$/.test(saved.account) ? saved.account : null };
}

// D1: 같은 Charge 사용자의 기기 중 한 대만 이번 주기에 이 계정의 usage를 묻도록 서버 임대를 잡는다.
// 서버가 JSON false를 줄 때만 거절(다른 기기가 임대 중)이다. RPC 오류, 구버전 서버의 404/PGRST202,
// 5초 타임아웃, 이상한 응답, 계정 미상은 모두 허락으로 본다 (임대 때문에 수집이 멈추면 안 된다).
async function claimPollLease(mode, providerId, account, { fetchFn = fetch } = {}) {
  if (!mode?.url || !mode?.anon || !mode?.token || !account) return true;
  try {
    const res = await fetchFn(`${mode.url}/rest/v1/rpc/charge_claim_poll`, {
      method: "POST",
      headers: { apikey: mode.anon, Authorization: `Bearer ${mode.anon}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_token: mode.token, p_provider: providerId, p_account: account }),
      signal: AbortSignal.timeout(LEASE_TIMEOUT_MS),
    });
    if (!res.ok) return true;
    return (await res.json()) !== false;
  } catch {
    return true;
  }
}

// D3: 지금 자격증명에 묶인 계정 해시. 순서: 이 자격증명 키로 기억해 둔 결과, 프로필 API 한 번(성공과 확정된 거절은
// 키가 바뀔 때까지, 429, 5xx, 네트워크 오류는 PROFILE_RETRY_MS 동안 기억), .claude.json(저장소 규칙은
// readClaudeAccountUuid가 지킨다), 그래도 모르면 null. 프로필 요청도 429 게이트를 따른다: 게이트가 막고 있으면
// 묻지 않고, 429를 받으면 usage와 같은 방식으로 게이트를 건다. 반환하는 gate는 요청 뒤의 게이트다.
// probed는 살아 있는 게이트(다른 자격증명의 백오프)를 지나 프로필을 물었다는 뜻이다. 그 요청이 이번 사이클의 확인 요청이다 (D12).
async function resolveClaudeAccount({ credential, headers, fetchFn, accountFile, readAccountUuid, gate, now }) {
  let account = null;
  let nextGate = gate;
  let probed = false;
  // .claude.json은 한 사이클에 한 번만 읽는다
  let configRead = false;
  const configAccount = async () => {
    configRead = true;
    return readAccountUuid ? accountHash(await Promise.resolve().then(readAccountUuid).catch(() => null)) : null;
  };
  const cached = readAccountCache(accountFile, credential, now());
  if (cached) {
    account = cached.account;
  } else if (!blockingRateLimitGate(gate, { credential }, now())) {
    probed = Boolean(gate && now() < gate.retryAt);
    const retryLater = () => ({ credential, account: null, retryAt: now() + PROFILE_RETRY_MS });
    let remember;
    try {
      const res = await fetchFn(CLAUDE_PROFILE_URL, { headers, signal: AbortSignal.timeout(10_000) });
      if (res.ok) {
        account = accountHash((await res.json())?.account?.uuid);
        remember = { credential, account };
      } else {
        let hint = "";
        if (res.status === 429) {
          // 게이트는 계정을 알면 계정 단위로 건다 (D12). 프로필이 막혔으니 D3 순서대로 .claude.json의 계정을 먼저 본다.
          // 계정 없이 걸면 Retry-After 기한이 다음 사이클에 확실히 다른 계정의 요청까지 막는다.
          account = await configAccount();
          nextGate = nextRateLimitGate(gate, { account, credential }, res.headers?.get?.("retry-after") ?? null, now());
          hint = `, ${new Date(nextGate.retryAt).toISOString()}까지 Claude 요청을 보내지 않습니다`;
        }
        await logHttpFailure("claude profile API", res, null, hint);
        const definitive = res.status >= 400 && res.status < 500 && res.status !== 408 && res.status !== 429;
        remember = definitive ? { credential, account: null } : retryLater();
      }
    } catch {
      remember = retryLater();
    }
    if (accountFile && credential) writeStateFile(accountFile, remember);
  }
  if (!account && !configRead) account = await configAccount();
  return { account, gate: nextGate, probed };
}

// usage API 200 응답을 프로바이더로 바꾼다. 올릴 창이 하나도 없으면 provider null, status "stale".
function claudeUsageResult(d, { plan, account }) {
  // 200인데 수치가 비어 있으면 창을 버린다. 0%로 대신 채우면 그건 서버의 빈 창 가드를
  // 통과하는 "정상 값"이라, 다른 기기가 올린 멀쩡한 게이지를 0으로 덮어버린다.
  const win = (w, mins) => {
    const percent = percentValue(w?.utilization);
    return percent === null ? null : { percent, resets_at: w.resets_at ?? null, window_minutes: mins };
  };
  // limits 배열의 weekly_scoped 항목 = 모델별 주간 한도 (예: "Fable only")
  const extras = (d?.limits ?? []).flatMap((l) => {
    const name = l?.kind === "weekly_scoped" ? l.scope?.model?.display_name : null;
    const percent = percentValue(l?.percent);
    if (!name || percent === null) return [];
    return [{
      name,
      window: {
        percent,
        resets_at: l.resets_at ?? null,
        window_minutes: 10080,
        label: `${name} weekly`,
      },
    }];
  });
  const session = dropExpired(win(d?.five_hour, 300));
  const weekly = dropExpired(win(d?.seven_day, 10080));
  // codexProvider와 같은 규칙: 올릴 창이 하나도 없으면 프로바이더 자체를 올리지 않는다.
  // percentValue 도입 후 이 경로가 실제로 생긴다 (200 응답인데 utilization이 비어 있는 경우).
  // 전부 null인 행을 신선한 스탬프로 올리면 서버에서 빈 카드가 이긴다.
  if (!session && !weekly && !extras.length) return { provider: null, status: "stale" };
  return {
    provider: {
      id: "claude",
      name: "Claude",
      plan,
      account,
      session,
      weekly,
      extras: extras.length ? extras : null,
      collected_at: new Date().toISOString(), // usage API 성공 시각
    },
    status: "ok",
  };
}

// Claude: Claude Code OAuth 세션을 재사용해 공식 usage API 조회.
// 반환: { provider, status, held? }. status는 "ok", "stale", "shared", "auth_expired[:revoked]",
// "error[:reason][;key=value]". held는 최소 간격(D13) 때문에 요청을 미룬 사이클이다: 상태는 지난 요청의 결과를
// 그대로 싣고, 연속 실패 기록은 늘리지 않는다 (recordCollectionHealth의 held).
// 설치 흔적이 없으면 status null; 설치 흔적은 있지만 로그인 정보를 못 읽으면 설정 안내.
// 순서 (D1): 자격증명, 로컬 만료 확인, 401로 거절된 토큰 확인, 계정 해시, 임대, 간격 잠금, 429 게이트, 최소 간격, 요청.
// 게이트와 최소 간격은 잠금 안에서 상태 파일을 다시 읽고 판단한다 (같은 기기의 겹친 실행이 둘 다 묻지 않게, D13).
// 요청을 보내지 않으면 한 줄 로그 (D7).
// fetchFn/loadCredentials는 테스트 주입용. 계정 읽기, 임대, 상태 파일은 collectProviders가 넘기며
// 기본값(null)이면 임대 없이, 상태를 저장하지 않고, 계정은 프로필 API로만 알아낸다.
async function claudeProvider({
  fetchFn = fetch, loadCredentials = claudeCredentials,
  hasClaude = () => fs.existsSync(claudeCredentialLocation().configDir),
  readAccountUuid = null,
  claimLease = null,
  stateFile = null,
  accountFile = null,
  now = Date.now,
} = {}) {
  let cred;
  try {
    cred = await loadCredentials();
  } catch {
    // A config directory without readable subscription credentials is a setup
    // issue, not proof that Claude Code is absent. Surface it even on first use.
    const detected = hasClaude();
    logClaudeNoRequest("no-credentials", {}, detected
      ? "Claude Code 구독 로그인 정보를 읽을 수 없습니다. 이 PC의 Claude Code에서 /status와 /login을 확인하세요 (API 키 계정은 구독 한도 조회 미지원)"
      : "이 PC에서 Claude Code 설치 흔적을 찾지 못했습니다");
    return { provider: null, status: detected ? "error:credentials_missing" : null };
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
    // 자격증명 키: 리프레시 토큰(없으면 액세스 토큰)의 해시. 계정 캐시와 429 게이트가 쓰고, 앞 8자는 로그의 세대 표시다.
    const credential = credentialKey(typeof oauth.refreshToken === "string" && oauth.refreshToken ? oauth.refreshToken : token);
    const generation = credential ? credential.slice(0, 8) : null;

    // 이미 만료된 토큰으로 물어보면 401만 돌아오고 한도 창만 깎인다. 요청 없이 만료로 보고하고 임대도 잡지 않는다
    // (임대를 잡으면 토큰이 살아 있는 같은 사용자의 다른 기기가 이어받지 못한다).
    const expiresAt = epochMs(oauth.expiresAt);
    if (expiresAt !== null && expiresAt <= now() + EXPIRY_MARGIN_MS) {
      logClaudeNoRequest("expired", {
        expires_at: new Date(expiresAt).toISOString(),
        source: cred.credentialSource,
        generation,
        account: readAccountCache(accountFile, credential, now())?.account,
      }, "이 PC에서 Claude Code를 한 번 열면 갱신됩니다");
      return { provider: null, status: "auth_expired" };
    }

    const headers = { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20", "User-Agent": USER_AGENT };
    const tokenKey = credentialKey(token);
    const state = readClaudeRequestState(stateFile, now());
    const persist = () => {
      const saved = writeStateFile(stateFile, {
        gate: state.gate,
        lastRequestAt: state.lastRequest?.at ?? null,
        lastStatus: state.lastRequest?.status ?? null,
        lastToken: state.lastRequest?.token ?? null,
        ...(state.leaseAt !== null ? { leaseAt: state.leaseAt } : {}),
      });
      if (stateFile && !saved) console.error("Claude 요청 상태(429 게이트, 마지막 요청 시각)를 저장하지 못했습니다");
    };
    // 겹친 실행(페어링 직후 스케줄러의 첫 실행과 CLI의 첫 수집 등)이 그사이 상태 파일에 쓴 것을 받아들인다: 더 늦은 요청 기록,
    // 그리고 base(이 실행이 알던 게이트) 뒤에 새로 걸린 게이트가 이 실행의 것보다 늦으면 그 게이트. 한 실행의 200이 다른 실행이
    // 방금 건 429 게이트를 지우지 않게 한다. 사이클 첫머리에 읽은 state는 낡았을 수 있으므로 요청 전 판단은 간격 잠금 안에서
    // 이 함수로 다시 읽은 뒤 한다. 응답 뒤의 마지막 쓰기는 잠금 없이 하되(잠금 안에서 쓴 예약이 240초 동안 뒤이은 실행을 쉬게
    // 하고, 요청은 그보다 훨씬 먼저 끝난다) 같은 프로세스 안의 이 확인과 뒤이은 쓰기 사이에 기다리는 작업은 두지 않는다.
    const adoptConcurrentState = (base) => {
      if (!stateFile) return;
      const disk = readClaudeRequestState(stateFile, now());
      if (disk.lastRequest && (!state.lastRequest || disk.lastRequest.at > state.lastRequest.at)) state.lastRequest = disk.lastRequest;
      if (disk.gate && !sameRateLimitGate(disk.gate, base) && (!state.gate || disk.gate.retryAt > state.gate.retryAt)) state.gate = disk.gate;
    };

    // 지금 액세스 토큰으로 보낸 마지막 usage 요청이 실패했는가. 429는 계정 한도라 여기서 실패로 치지 않는다
    // (게이트에 막힌 임대 보유 기기는 임대를 계속 잡는다, D1). 결과가 아직 없는 요청 기록은 실패가 아니다.
    const last = state.lastRequest;
    const lastKind = last?.status ? last.status.split(";")[0] : null;
    const lastFailed = Boolean(lastKind && tokenKey && last.token === tokenKey && !["ok", "stale", "error:rate_limited"].includes(lastKind));
    // 서버가 401로 거절한 토큰은 로컬 만료처럼 다룬다: 요청도 임대도 없이 그 결과를 되풀이한다. 거절될 요청으로 한도 창을
    // 깎지 않고, 임대를 놓아 토큰이 살아 있는 같은 사용자의 다른 기기가 이어받게 한다. 토큰이 바뀌면(Claude Code를 열거나
    // /login) 바로, 그대로면 REJECTED_TOKEN_RETRY_MS 뒤에 한 번 다시 묻는다 (일시적인 401일 수 있다).
    const sinceRejected = last ? now() - last.at : Number.NaN;
    if (lastFailed && lastKind.startsWith("auth_expired") && sinceRejected >= 0 && sinceRejected < REJECTED_TOKEN_RETRY_MS) {
      logClaudeNoRequest("rejected", {
        status: lastKind,
        last_request: new Date(last.at).toISOString(),
        source: cred.credentialSource,
        generation,
        account: readAccountCache(accountFile, credential, now())?.account,
      }, lastKind === "auth_expired:revoked"
        ? "로그인이 무효입니다. 이 PC의 Claude Code에서 /login으로 다시 로그인하세요"
        : "이 PC에서 Claude Code를 한 번 열면 갱신됩니다");
      return { provider: null, status: lastKind };
    }

    const resolved = await resolveClaudeAccount({ credential, headers, fetchFn, accountFile, readAccountUuid, gate: state.gate, now });
    const { account } = resolved;
    if (resolved.gate !== state.gate) {
      state.gate = resolved.gate;
      persist();
    }

    // 같은 Charge 사용자의 다른 기기가 이번 주기에 이 계정을 조회한다 (임대 거절). 게이트와 상태는 그대로 둔다.
    // 게이트에 막힌 기기도 임대는 매 사이클 잡아, 계정 단위 차단 동안 같은 사용자의 다른 기기까지 조용해진다.
    // 한 시간 뒤 다시 확인하는 401 토큰은 임대를 잡지 않는다. 지금 토큰으로 보낸 마지막 요청이 그 밖의 이유로 실패했으면(네트워크,
    // 5xx, 403) 요청은 매 사이클 보내 복구를 바로 알아채되, 임대는 한 사이클 걸러 잡는다. 매번 갱신하면 같은 사용자의 멀쩡한 기기가
    // 끝내 조회하지 못하고, 아예 안 잡으면 그 기기가 넘겨받은 뒤에도 둘이 매 사이클 같이 묻는다. 거른 사이클에 임대가 끝나 다른
    // 기기가 넘겨받으면, 다음에 잡을 때 거절되어 이 기기는 shared로 물러난다.
    const sinceLease = state.leaseAt === null ? Number.NaN : now() - state.leaseAt;
    const skipClaim = lastFailed
      && (lastKind.startsWith("auth_expired") || (sinceLease >= 0 && sinceLease < FAILING_LEASE_INTERVAL_MS));
    if (account && claimLease && !skipClaim) {
      const granted = await Promise.resolve().then(() => claimLease(account)).catch(() => true);
      if (granted === false) {
        logClaudeNoRequest("shared", { generation, account }, "같은 계정을 다른 기기가 이번 주기에 조회합니다");
        return { provider: null, status: "shared" };
      }
      state.leaseAt = now();
    }

    // 여기서부터 요청 시각을 예약할 때까지는 이 기기의 다른 프로세스와 직렬화한다 (D13). 같은 프로세스 안에서는 기다리는 작업이
    // 없지만, 겹친 두 프로세스(스케줄 실행과 수동 `charge-connect run`, 깨어난 뒤 몰아서 뜬 실행)는 둘 다 옛 기록을 읽고 둘 다
    // 임대를 받아(같은 기기다) 둘 다 간격을 통과할 수 있다. 그래서 잠금을 잡은 뒤 상태 파일을 다시 읽고 판단한 다음 예약을 쓰고,
    // HTTP 요청 전에 잠금을 푼다 (응답을 기다리는 동안은 예약이 뒤이은 실행을 쉬게 한다).
    // 임대 뒤에 잡는다: 잠금이나 간격 때문에 쉬는 임대 보유 기기도 임대는 이미 갱신했다.
    const lock = acquireClaudeRequestLock(stateFile, now());
    if (lock.held) {
      // 살아 있는 다른 실행이 지금 판단하는 중이다: 최소 간격에 걸린 것과 같이 물러난다. 그 실행이 이번 주기의 요청을 보내거나 이미 보냈다.
      adoptConcurrentState(state.gate);
      logClaudeNoRequest("spacing", {
        reason: "lock",
        last_request: state.lastRequest ? new Date(state.lastRequest.at).toISOString() : null,
        generation,
        account,
      });
      const status = state.lastRequest?.status == null ? "shared" : deferredStatus(state.lastRequest.status);
      return { provider: null, status, held: true };
    }
    if (lock.error) {
      // 잠금 파일을 만들 수 없는 폴더(권한, 폴더 없음)면 잠금 없이 한 번 판단한다 (잠금 때문에 수집이 멈추면 안 된다)
      console.error(`Claude 요청 간격 잠금을 만들지 못해 이번에는 잠금 없이 판단합니다: ${lock.error?.code ?? lock.error?.message ?? lock.error}`);
    }
    let requestedAt;
    let gateBeforeRequest;
    try {
      adoptConcurrentState(state.gate);
      // 계산한 백오프 중에 자격증명이 바뀌어 이번 사이클에 프로필을 이미 확인 요청으로 보냈으면 usage 확인은 다음 사이클로 미룬다.
      // D12가 허락하는 확인은 한 번이다. 프로필이 확실히 다른 계정을 알려줬으면 그 계정의 한도가 아니므로 막지 않는다.
      const gate = blockingRateLimitGate(state.gate, { account, credential }, now())
        ?? (resolved.probed ? blockingRateLimitGate(state.gate, { account, credential: state.gate?.credential }, now()) : null);
      if (gate) {
        logClaudeNoRequest("gated", { retry_at: new Date(gate.retryAt).toISOString(), cause: gate.cause, generation, account });
        return { provider: null, status: `error:rate_limited;retry_at=${Math.floor(gate.retryAt / 1000)};deferred=1` };
      }

      const sinceLast = state.lastRequest ? now() - state.lastRequest.at : Number.NaN;
      if (sinceLast >= 0 && sinceLast < MIN_REQUEST_SPACING_MS) {
        logClaudeNoRequest("spacing", { last_request: new Date(state.lastRequest.at).toISOString(), generation, account });
        // 결과가 아직 없는 요청은 겹친 실행이 지금 이 계정을 묻고 있다는 뜻이다 (되풀이할 지난 결과도 없다). 그 실행이 결과를 올린다.
        const status = state.lastRequest.status === null ? "shared" : deferredStatus(state.lastRequest.status);
        return { provider: null, status, held: true };
      }

      // 응답이 무엇이든(네트워크 실패 포함) 요청 시각과 결과를 남긴다, 다음 사이클의 최소 간격 판단에 쓴다.
      // 시각은 요청 전에 먼저 적는다 (결과는 지난 요청의 것을 그대로 둔다). 응답을 기다리는 동안 겹친 실행은 이 기록을 보고 쉰다.
      requestedAt = now();
      gateBeforeRequest = state.gate;
      state.lastRequest = { at: requestedAt, status: state.lastRequest?.status ?? null, token: state.lastRequest?.token ?? null };
      persist();
    } finally {
      lock.release();
    }
    let result;
    try {
      // signal은 넘기지 않는다, fetchOnceRetried가 시도마다 새 10초 예산을 만들어 붙인다
      const res = await fetchOnceRetried(fetchFn, CLAUDE_USAGE_URL, { headers }, { timeoutMs: 10_000 });
      if (res.ok) {
        state.gate = null;
        result = claudeUsageResult(await res.json(), { plan, account });
      } else {
        // 이 구분이 서버 collect_status로 올라가 앱이 상황별 조치를 안내한다.
        const body = await readBodySnippet(res);
        let status = res.status === 403 ? "error:access_denied" : "error";
        let hint = "";
        if (res.status === 401) {
          status = unauthorizedStatus(body);
          hint = status === "auth_expired:revoked"
            ? ", 로그인이 무효입니다. 이 PC의 Claude Code에서 /login으로 다시 로그인하세요"
            : ", 토큰 만료. 이 PC에서 Claude Code를 한 번 열면 갱신됩니다";
        } else if (res.status === 429) {
          state.gate = nextRateLimitGate(state.gate, { account, credential }, res.headers?.get?.("retry-after") ?? null, now());
          status = `error:rate_limited;retry_at=${Math.floor(state.gate.retryAt / 1000)}`;
          hint = `, ${new Date(state.gate.retryAt).toISOString()}까지 요청하지 않습니다`;
        }
        await logHttpFailure("claude usage API", res, body, hint);
        result = { provider: null, status };
      }
    } catch (e) {
      console.error(`claude 프로바이더 수집 실패: ${e.message ?? e}`);
      result = { provider: null, status: "error" };
    }
    state.lastRequest = { at: requestedAt, status: result.status, token: tokenKey };
    adoptConcurrentState(gateBeforeRequest);
    persist();
    return result;
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
// fetchFn은 테스트 주입용, 기본값이면 기존 동작 그대로.
async function codexLiveWindows(auth, { fetchFn = fetch } = {}) {
  if (!auth?.accessToken || !auth?.accountId) return null;
  try {
    // signal은 넘기지 않는다, fetchOnceRetried가 시도마다 새 10초 예산을 만들어 붙인다
    const res = await fetchOnceRetried(fetchFn, "https://chatgpt.com/backend-api/wham/usage", {
      headers: {
        Authorization: `Bearer ${auth.accessToken}`,
        "chatgpt-account-id": auth.accountId,
        "User-Agent": "charge-connect",
      },
    }, { timeoutMs: 10_000 });
    if (!res.ok) return null;
    const d = await res.json();
    // 수치가 비면 0%가 아니라 창 없음, 0%는 서버의 빈 창 가드를 통과해 게이지를 덮는다
    const win = (w) => {
      const percent = percentValue(w?.used_percent);
      return percent === null
        ? null
        : {
            percent,
            resets_at: w.reset_at ? new Date(w.reset_at * 1000).toISOString() : null,
            window_minutes: Number.isFinite(Number(w.limit_window_seconds))
              ? Math.round(Number(w.limit_window_seconds) / 60)
              : null,
          };
    };
    const session = win(d.rate_limit?.primary_window);
    const weekly = win(d.rate_limit?.secondary_window);
    if (!session && !weekly) return null;
    const plan = usefulPlan(d.plan_type);
    return { session, weekly, plan: plan ? plan[0].toUpperCase() + plan.slice(1) : null };
  } catch {
    return null;
  }
}

// 최신 .jsonl에 rate_limits가 없는 경우가 흔하다(막 연 세션, 한도 응답 전에 끝난 세션).
// 그렇다고 전부 훑으면 세션 로그가 수천 개인 사용자에서 5분 주기를 넘기므로 최근 몇 개만 본다.
// 5개는 너무 빡빡했다, 짧은 세션이 연달아 다섯 번이면 여섯 번째의 멀쩡한 스냅샷을 놓치고
// "관측 실패(error)"로 보고해 앱에 경고가 뜬다. 파일당 읽기는 개별 try로 감싸져 있다.
const SNAPSHOT_SCAN_FILES = 20;
// 파일당 읽는 꼬리 크기, 마지막 rate_limits는 파일 끝에 있다 (전체를 읽으면 수십 MB를 파싱하게 된다)
const SNAPSHOT_TAIL_BYTES = 2 * 1024 * 1024;

// Codex 스냅샷 폴백: 최근 세션 로그(.jsonl)에 기록된 마지막 rate_limits , 
// 마지막으로 Codex를 실제 사용한 시점의 값이라 실시간 조회가 실패했을 때만 쓴다.
// 반환: null = 볼 스냅샷이 아예 없음(미설치, 최근 로그에 rate_limits 없음),
// { session, weekly, collected_at } = 스냅샷은 있었음. 만료 창은 여기서 이미 걸러지므로
// 둘 다 null일 수 있고, 그건 "관측은 했는데 리셋이 다 지났다"는 뜻이다(호출자가 stale로 판정).
// dir은 테스트 주입용, 기본값이면 기존 동작 그대로.
async function codexSnapshotWindows(dir = path.join(HOME, ".codex", "sessions")) {
  if (!fs.existsSync(dir)) return null; // Codex 미설치
  const files = [];
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".jsonl")) {
        try {
          files.push({ p, m: fs.statSync(p).mtimeMs });
        } catch {}
      }
    }
  })(dir);
  if (!files.length) return null;
  files.sort((a, b) => b.m - a.m);

  const findRL = (o) => {
    if (!o || typeof o !== "object") return null;
    if (o.rate_limits) return o.rate_limits;
    for (const v of Object.values(o)) {
      const r = findRL(v);
      if (r) return r;
    }
    return null;
  };
  // 세션 로그는 수십 MB까지 자란다(실측 최대 43MB). 통째로 동기 읽기를 하면 그동안 이벤트 루프가
  // 멈춰 진행 중인 fetch의 AbortSignal 타이머가 전부 터진다, 이 파일 맨 위에서 금지한 바로 그 패턴이다.
  // 그래서 비동기로, 그것도 꼬리 SNAPSHOT_TAIL_BYTES만 읽는다. 우리가 찾는 건 "마지막" rate_limits라
  // 꼬리에 없으면 그 파일의 값은 어차피 낡은 것이고, 더 최근 파일이 우선순위를 갖는다.
  const lastRateLimits = async (file) => {
    let handle = null;
    try {
      handle = await fs.promises.open(file, "r");
      const { size } = await handle.stat();
      const start = Math.max(0, size - SNAPSHOT_TAIL_BYTES);
      const buf = Buffer.alloc(Math.min(size, SNAPSHOT_TAIL_BYTES));
      await handle.read(buf, 0, buf.length, start);
      let rl = null;
      for (const line of buf.toString("utf8").split("\n")) {
        if (!line.includes('"rate_limits"')) continue;
        try {
          // 꼬리를 자른 지점의 첫 줄은 조각날 수 있다, 파싱 실패는 그냥 건너뛴다
          rl = findRL(JSON.parse(line)) ?? rl;
        } catch {}
      }
      return rl;
    } catch {
      return null;
    } finally {
      await handle?.close().catch(() => {});
    }
  };
  let found = null;
  for (const f of files.slice(0, SNAPSHOT_SCAN_FILES)) {
    const rl = await lastRateLimits(f.p);
    if (rl) {
      found = { rl, m: f.m };
      break;
    }
  }
  if (!found) return null;
  // 수치가 비면 0%가 아니라 창 없음, 0%는 서버의 빈 창 가드를 통과해 게이지를 덮는다
  const win = (w) => {
    const percent = percentValue(w?.used_percent);
    return percent === null
      ? null
      : {
          percent,
          resets_at: w.resets_at ? new Date(w.resets_at * 1000).toISOString() : null,
          window_minutes: w.window_minutes ?? null,
        };
  };
  // 만료 판정을 여기서 끝낸다, 예전엔 dropExpired가 codexProvider에서야 돌아, 리셋이 다 지난
  // 3일 묵은 스냅샷도 "창이 있다"고 통과한 뒤 그 창이 뒤늦게 전부 null이 됐다.
  const session = dropExpired(win(found.rl.primary));
  const weekly = dropExpired(win(found.rl.secondary));
  // collected_at = 그 스냅샷이 들어 있던 파일의 mtime, 스냅샷은 "지금"이 아니라 마지막
  // 사용 시점의 값이므로, 수집 시각을 넣으면 다른 기기의 진짜 최신 값을 신선도 규칙에서 이긴다.
  return { session, weekly, collected_at: new Date(found.m).toISOString() };
}

// 반환: { provider, status } — live 성공 "ok", 스냅샷 폴백 "stale",
// ~/.codex는 있는데 아무것도 관측 못 하면 "error", 미설치면 status null(항목 없음).
// loadAuth/liveWindows/snapshotWindows/hasCodex는 테스트 주입용, 기본값이면 기존 동작 그대로.
async function codexProvider({
  loadAuth = codexAuth,
  liveWindows = codexLiveWindows,
  snapshotWindows = codexSnapshotWindows,
  hasCodex = () => fs.existsSync(path.join(HOME, ".codex")),
} = {}) {
  if (!hasCodex()) return { provider: null, status: null }; // Codex 미설치
  try {
    const auth = loadAuth();
    const live = await liveWindows(auth);
    const snapshot = live ? null : await snapshotWindows();
    const windows = live ?? snapshot;
    if (!windows) return { provider: null, status: "error" }; // 실시간, 스냅샷 둘 다 관측 실패
    // 스냅샷은 과거 관측의 재생이다, 리셋 시각을 모르는 창은 캐시 복원과 같은 나이 규칙을 적용한다
    const replay = (w, fallbackMinutes) => (live ? w : dropUnknownResetIfOld(w, snapshot.collected_at, fallbackMinutes));
    const session = replay(dropExpired(windows.session), 300);
    const weekly = replay(dropExpired(windows.weekly), 10_080);
    // 리셋이 다 지나 남는 창이 하나도 없으면 프로바이더 자체를 올리지 않는다. 전부 null인 행을
    // 올리면 앱엔 빈 카드가 뜨고, 서버 행의 collected_at이 스냅샷 mtime(며칠 전)으로 되감겨
    // 다른 기기의 묵은 업로드까지 신선도 가드를 통과한다. 대신 캐시 폴백이 마지막 값을 유지한다.
    // 상태는 "error"가 아니다, 수집은 정상이고 데이터가 낡았을 뿐인데 error로 보고하면
    // 앱이 "재로그인/수집 실패" 경고를 띄운다(앱은 error, auth_expired만 경고로 친다).
    // live 조회에 성공했더라도 여기까지 왔다면 올릴 창이 없으니 "ok"가 아니라 "stale"이다 , 
    // "ok"는 이번 사이클에 쓸 수 있는 값을 올렸다는 뜻인데, 실제로 올라가는 건 캐시 폴백뿐이다.
    if (!session && !weekly) return { provider: null, status: "stale" };
    return {
      provider: {
        id: "codex",
        name: "Codex",
        plan: windows.plan ?? auth?.plan ?? null,
        account: auth?.account ?? null,
        session,
        weekly,
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

// mode는 페어링 설정 (없으면 Claude 조회 임대를 잡지 않는다)
async function collectProviders(mode = null) {
  const [claude, codex, claudeStatus, codexStatus, codexBar] = await Promise.all([
    claudeProvider({
      readAccountUuid: () => readClaudeAccountUuid(),
      claimLease: mode ? (account) => claimPollLease(mode, "claude", account) : null,
      stateFile: RATE_LIMIT_FILE,
      accountFile: CLAUDE_ACCOUNT_FILE,
    }),
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
    // 최소 간격으로 요청을 미룬 프로바이더: 지난 결과를 싣되 연속 실패는 늘리지 않는다 (D13)
    held: claude.held && claude.status ? ["claude"] : [],
  };
}

// 서버는 (user_id, id, account) 한 행을 업서트하므로, 같은 키를 한 페이로드에 두 번 실으면
// 한 문장 안에서 같은 행을 두 번 건드려 어느 쪽이 남을지가 배열 순서에 달린다.
// 더 신선한 쪽만 남긴다, collected_at이 없으면 나이 미상이라 스탬프가 있는 쪽에 진다.
function dedupeProviders(providers) {
  const stamp = (p) => {
    const t = Date.parse(p?.collected_at ?? "");
    return Number.isFinite(t) ? t : -Infinity;
  };
  const byKey = new Map();
  for (const p of providers) {
    // 구분자는 NUL 이스케이프, id, account 어디에도 못 들어가는 문자여야 키가 안 겹친다
    const key = `${p.id}\u0000${p.account ?? ""}`;
    const prev = byKey.get(key);
    // 동률(둘 다 미상 포함)이면 뒤엣것, 이번 사이클 수집분이 캐시 복원분보다 뒤에 온다
    if (!prev || stamp(p) >= stamp(prev)) byKey.set(key, p);
  }
  return [...byKey.values()];
}

// 이번 사이클 수집 결과에 캐시 복원분을 얹고 업로드 계약(키 유일성)에 맞춰 정리한다.
// 반환: { providers(업로드할 목록), statuses, cache(다음 사이클을 위해 캐시 파일에 남길 목록) }.
function mergeCachedProviders({ providers, cached = [], codexBarComplete = false, statuses = null }) {
  const merged = [...providers];
  // 업로드에서는 빼지만 캐시 파일에는 남기는 항목 (shared 사이클의 마지막 정상 값)
  const retained = [];
  // statuses가 null이면 수집이 통째로 죽어 아무것도 판정할 수 없는 경우, 미상 그대로 둔다
  const nextStatuses = statuses ? { ...statuses } : statuses;
  for (const prev of cached) {
    if (merged.some((p) => p.id === prev.id)) continue;
    // CodexBar가 정상 완료된 경우, 거기서 더 이상 반환하지 않는 항목은 사용자가 끈 것으로 본다.
    if (codexBarComplete && prev.collector_source === "codexbar") continue;
    const sanitized = sanitizeCachedProvider(prev);
    if (!sanitized) continue;
    // 같은 계정을 다른 기기가 이번 주기에 조회한 사이클(shared)에 이 기기의 묵은 캐시를 다시 올리면
    // 서버에 이 기기 행이 계속 살아남는다. 업로드에서는 빼되, 캐시 파일에서는 지우지 않는다 (D4):
    // 나중에 이 기기가 임대를 넘겨받았는데 요청이 실패하면 그 마지막 정상 값으로 폴백해야 한다.
    if (typeof nextStatuses?.[prev.id] === "string" && nextStatuses[prev.id].split(";")[0] === "shared") {
      retained.push(sanitized);
      continue;
    }
    // 0.1.4 이전 캐시엔 collected_at이 없다, 없는 채로 보낸다. 서버는 스탬프 없는 업로드를
    // "최신"이 아니라 "나이 미상"으로 보고 기존 행이 충분히 묵었을 때만 받아준다.
    // (예전엔 epoch로 찍어 지게 만들었는데, 그 값이 앱까지 새어 "56년 전"으로 보였다.)
    merged.push(sanitized);
    // CodexBar CLI가 통째로 실패/미검출/타임아웃이면 statuses가 비어 있어 아무도 실패로
    // 기록되지 않는다, 판정이 없는 복원 항목만 'stale'로 채운다.
    // 정상 수집이 남긴 판정(auth_expired/error 등)은 덮지 않는다.
    if (nextStatuses && !nextStatuses[sanitized.id]) nextStatuses[sanitized.id] = "stale";
  }
  const upload = dedupeProviders(merged);
  return { providers: upload, statuses: nextStatuses, cache: retained.length ? dedupeProviders([...merged, ...retained]) : upload };
}

function namespaceUnknownAccounts(providers, installationID) {
  if (!installationID) return providers;
  // 프로필 조회 실패 직전에 사용자가 계정을 바꿨을 수 있으므로 캐시의 예전 account를
  // 추정해 붙이지 않는다. 확인되지 않은 값은 이 기기 전용 키로 보낸 뒤 서버에서 격리한다.
  return dedupeProviders(providers.map((p) => p.account
    ? p
    : { ...p, account: unknownAccountKey(installationID, p.id) }));
}

// Count actual collection cycles, not app refreshes or retries within one request.
// A long gap (sleep/offline), recovery, or missing observation breaks the streak.
// Keep the status a string with its original prefix so existing apps/servers can read it.
// Other ";key=value" parameters (for example retry_at) are preserved ahead of failures and since.
// Different error kinds keep one streak (a persistent failure is real); the latest kind is stored.
// Ids in `held` sent no request this cycle because of the local request spacing (D13): their streak is
// repeated as it was (not advanced, not reset), and a streak that already lapsed is not annotated.
function advanceCollectionHealth(statuses, previous = {}, now = Date.now(), held = []) {
  if (statuses === null) return { statuses: null, failures: {} };
  const failures = {};
  const annotated = {};
  for (const [id, value] of Object.entries(statuses)) {
    if (id.startsWith("_") || typeof value !== "string") {
      annotated[id] = value;
      continue;
    }
    const [status, ...params] = value.split(";");
    const kept = params.filter((param) => param && !/^(failures|since)=/.test(param));
    const base = [status, ...kept].join(";");
    if (!status.startsWith("error") && !status.startsWith("auth_expired")) {
      annotated[id] = base;
      continue;
    }
    const prev = previous?.[id];
    const continues = Number.isSafeInteger(prev?.count) && prev.count > 0
      && Number.isFinite(prev.since) && prev.since <= prev.lastAttempt
      && Number.isFinite(prev.lastAttempt) && now >= prev.lastAttempt
      && now - prev.lastAttempt <= 12 * 60_000;
    if (held.includes(id)) {
      if (continues) {
        failures[id] = { count: prev.count, since: prev.since, lastAttempt: prev.lastAttempt, kind: typeof prev.kind === "string" ? prev.kind : status };
        annotated[id] = `${base};failures=${prev.count};since=${Math.floor(prev.since / 1000)}`;
      } else {
        annotated[id] = base;
      }
      continue;
    }
    const count = continues ? Math.min(prev.count + 1, 9999) : 1;
    const since = continues ? prev.since : now;
    failures[id] = { count, since, lastAttempt: now, kind: status };
    annotated[id] = `${base};failures=${count};since=${Math.floor(since / 1000)}`;
  }
  return { statuses: annotated, failures };
}

function recordCollectionHealth(statuses, {
  file = HEALTH_FILE, scope = null, now = Date.now(), persist = true, held = [],
} = {}) {
  let previous = {};
  try {
    const saved = JSON.parse(fs.readFileSync(file, "utf8"));
    if (saved.scope === scope) previous = saved.failures;
  } catch {}
  const next = advanceCollectionHealth(statuses, previous, now, held);
  if (persist) {
    // Save independently of the payload: an upload failure must not erase attempts.
    const temporary = `${file}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(temporary, JSON.stringify({ scope, failures: next.failures }), { mode: 0o600 });
      fs.renameSync(temporary, file);
    } catch {
      console.error("수집 실패 횟수를 저장하지 못했습니다");
    } finally {
      try { fs.rmSync(temporary, { force: true }); } catch {}
    }
  }
  return next.statuses;
}

// collect_status에 수집기 버전을 싣는다 (서버가 charge_devices.collector_version으로 옮기고 키는 지운다).
// 상태가 null(수집이 통째로 실패)이면 미상 그대로 둔다.
function withCollectorVersion(statuses, version = PACKAGE_VERSION) {
  if (!statuses || typeof statuses !== "object" || !version) return statuses;
  return { ...statuses, _collector: version };
}

// 설치된 런타임(~/.charge/app)이면 서명된 새 릴리스로 스스로 교체한다. 실패는 로그 한 줄로 끝낸다.
// 한 실행에서 한 번만 확인한다: 업로드 뒤, main이 예외로 끝났을 때, 처리되지 않은 예외로 끝낼 때 모두 같은 확인을 기다린다.
let autoUpdateRun = null;
function runAutoUpdate(mode) {
  autoUpdateRun ??= (async () => {
    let updater;
    try {
      updater = require("./updater.js");
    } catch (e) {
      console.error(`자동 업데이트 모듈을 불러오지 못했습니다: ${e?.message ?? e}`);
      return;
    }
    try {
      await updater.maybeAutoUpdate({
        mode,
        dryRun: DRY_RUN,
        appDir: __dirname,
        chargeHome: process.env.CHARGE_HOME ?? path.join(HOME, ".charge"),
        currentVersion: PACKAGE_VERSION,
      });
    } catch (e) {
      console.error(`자동 업데이트 실패: ${e?.message ?? e}`);
    }
  })();
  return autoUpdateRun;
}

// 처리되지 않은 예외나 거부로 끝낼 때(오류 기록은 처리기가 먼저 한다). 이 버전의 결함으로 매 실행이 그렇게 죽더라도
// 업데이트 확인까지는 닿아야 고친 릴리스로 스스로 복구한다. 확인하는 동안 또 터진 예외는 기록만 되고, 확인이 멈추면
// CRASH_UPDATE_CHECK_LIMIT_MS 뒤에 끝낸다. 자체 점검 중이거나 이 파일을 다 불러오기 전(업데이트 함수를 아직 못 쓴다)이면 바로 끝낸다.
function exitAfterUpdateCheck() {
  if (crashExitStarted) return;
  crashExitStarted = true;
  let check;
  try {
    if (SELF_TEST) process.exit(1);
    check = runAutoUpdate(resolveMode());
  } catch {
    process.exit(1);
  }
  setTimeout(() => process.exit(1), CRASH_UPDATE_CHECK_LIMIT_MS);
  check.finally(() => process.exit(1));
}

// 업로드 설정 — 우선순위: CHARGE_* 환경변수(테스트용) → ~/.charge/config.json(페어링)
function resolveMode() {
  if (process.env.CHARGE_TOKEN && process.env.CHARGE_URL && process.env.CHARGE_ANON) {
    return {
      url: process.env.CHARGE_URL,
      anon: process.env.CHARGE_ANON,
      token: process.env.CHARGE_TOKEN,
      install_id: process.env.CHARGE_INSTALL_ID ?? null,
    };
  }
  const conf = path.join(process.env.CHARGE_HOME ?? path.join(HOME, ".charge"), "config.json");
  try {
    return JSON.parse(fs.readFileSync(conf, "utf8"));
  } catch {
    return null;
  }
}

// 디바이스 토큰으로 charge_upload RPC 호출 (서버가 본인 행에만 기록)
// fetchFn은 테스트 주입용, 기본값이면 기존 동작 그대로.
async function pairedUpload(mode, daily, live, providers, collectStatus = null, { fetchFn = fetch } = {}) {
  const post = (body) =>
    fetchFn(`${mode.url}/rest/v1/rpc/charge_upload`, {
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
    if (res.ok) {
      // 이 경로로 올라간 사이클은 collect_status가 서버에 반영되지 않는다(파라미터 자체가 없다).
      // 상태는 매 사이클 통째로 다시 보내므로 서버가 갱신되면 다음 5분에 저절로 복구된다 , 
      // 다만 "왜 상태가 비었나"를 로그 없이는 알 수 없어 흔적을 남긴다.
      console.error("구버전 시그니처로 업로드 성공, collect_status는 이번 사이클 미반영(다음 사이클에 복구)");
      return;
    }
    throw new Error(`업로드 실패 (${res.status}): ${await res.text()}`);
  }
  throw new Error(`업로드 실패 (${res.status}): ${text}`);
}

async function main() {
  const mode = resolveMode();
  // Scheduler environments do not inherit the shell used for pairing. Restore
  // only the two non-secret location settings, never login tokens or API keys.
  for (const key of ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"]) {
    if (process.env[key] === undefined && typeof mode?.claude_environment?.[key] === "string") {
      process.env[key] = mode.claude_environment[key];
    }
  }
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
    collectProviders(mode),
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
    // 캐시 블록은 collected_at을 갱신하지 않고 통째로 재사용한다, 갱신하면 수집이 깨진
    // 기기의 옛 블록이 다른 기기의 진짜 활성 블록을 서버 신선도 규칙에서 이겨버린다.
    live = cache.live ?? null;
  }
  let providerCollection;
  if (providersR.status === "fulfilled") {
    providerCollection = providersR.value;
  } else {
    console.error(`프로바이더 수집 실패, 이전 값 유지: ${providersR.reason?.message ?? providersR.reason}`);
    // 수집이 통째로 죽으면 상태를 알 수 없다 — null로 보내 정직한 미상 처리 (서버도 null로 덮음)
    providerCollection = { providers: [], codexBarComplete: false, statuses: null, held: [] };
  }
  // 일부 프로바이더만 실패해도 목록에서 사라지지 않게 이전 값으로 채운다 (앱 설정 토글 유지)
  let statuses;
  let cacheProviders;
  ({ providers, statuses, cache: cacheProviders } = mergeCachedProviders({
    providers: providerCollection.providers,
    cached: cache.providers ?? [],
    codexBarComplete: providerCollection.codexBarComplete,
    statuses: providerCollection.statuses,
  }));

  providers = namespaceUnknownAccounts(providers, mode?.install_id);
  cacheProviders = namespaceUnknownAccounts(cacheProviders, mode?.install_id);
  statuses = withCollectorVersion(recordCollectionHealth(statuses, {
    scope: accountHash(mode?.token),
    persist: !DRY_RUN && !!mode,
    held: providerCollection.held ?? [],
  }));

  if (DRY_RUN) {
    console.log(JSON.stringify({ daily: daily.slice(-1), live, providers, collect_status: statuses }, null, 2));
    console.log(`\n[dry-run] daily ${daily.length}행 + live + providers ${providers.length}개 업로드 예정`);
    return;
  }

  if (!mode) {
    console.error("페어링이 안 돼 있습니다. 앱에서 코드를 발급받아 `npx charge-connect <코드>`를 실행하세요.");
    process.exit(1);
  }

  const now = new Date().toISOString();
  let uploadError = null;
  try {
    await pairedUpload(mode, daily, live, providers, statuses);
    // 캐시에는 업로드 목록이 아니라 캐시 목록을 쓴다 (shared 사이클에도 마지막 정상 Claude 값을 지우지 않는다)
    fs.writeFileSync(CACHE_FILE, JSON.stringify({ daily, live, providers: cacheProviders }));
    console.log(`[${now}] daily ${daily.length}행 + live + providers ${providers.length}개 업로드 완료`);
  } catch (e) {
    uploadError = e;
  }
  // 업로드가 끝난 뒤(실패했더라도) 업데이트를 확인한다. 서버 계약이 바뀌어 업로드가 계속 실패하는
  // 구버전 수집기도 새 버전을 받아 스스로 복구할 수 있어야 한다.
  await runAutoUpdate(mode);
  if (uploadError) throw uploadError;
}

module.exports = {
  CCUSAGE_PKG,
  MIN_REQUEST_SPACING_MS,
  PACKAGE_VERSION,
  REQUEST_LOCK_STALE_MS,
  USER_AGENT,
  acquireClaudeRequestLock,
  advanceCollectionHealth,
  accountHash,
  blockingRateLimitGate,
  claimPollLease,
  claudeCredentialLocation,
  claudeCredentials,
  claudeProvider,
  codexBarEntryToProvider,
  codexLiveWindows,
  codexProvider,
  codexSnapshotWindows,
  collectCodexBarProviders,
  collectLive,
  collectProviders,
  credentialKey,
  dedupeProviders,
  deferredStatus,
  dropExpired,
  dropUnknownResetIfOld,
  durationLabel,
  epochMs,
  fetchOnceRetried,
  freshestCredentials,
  mergeCachedProviders,
  namespaceUnknownAccounts,
  nextRateLimitGate,
  normalizeRateWindow,
  normalizeResetAt,
  pairedUpload,
  parseCodexBarJSON,
  parseRateLimitGate,
  parseRetryAfter,
  percentValue,
  readClaudeAccountUuid,
  readClaudeRequestState,
  recordCollectionHealth,
  resolveMode,
  runAsync,
  sanitizeCachedProvider,
  sanitizeLogSnippet,
  titleCaseProvider,
  unauthorizedStatus,
  usefulPlan,
  withCollectorVersion,
};

// 진입점은 module.exports 뒤에 둔다. 자체 점검이 불러오는 cli.js가 이 파일을 다시 require하면
// 완성된 exports를 받아야 한다.
if (require.main === module && SELF_TEST) {
  // 자동 업데이트가 교체 전(스테이징 폴더)과 교체 후(앱 폴더)에 부른다 (D9). 런타임 모듈을 모두 불러와
  // 빠진 파일이나 불러오는 순간의 예외를 잡고, 네트워크, 키체인, 상태 파일에는 닿지 않은 채 끝낸다.
  // 마지막 줄의 버전은 updater.js가 설치하려는 버전과 같은지 확인한다.
  require("./identity.js");
  require("./updater.js");
  require("./cli.js");
  console.log(`charge-connect self-test ok ${PACKAGE_VERSION ?? "unknown"}`);
} else if (require.main === module) {
  // --log 없이 돌 때(launchd, CLI의 첫 수집)도 main 밖에서 터진 예외가 업데이트 확인을 건너뛰지 않게 한다.
  // --log가 있으면 맨 위의 처리기가 로그 파일에 쓰고 같은 확인을 거친다.
  if (!LOG_FILE) {
    const crashed = (err) => {
      console.error(err?.stack ?? err);
      exitAfterUpdateCheck();
    };
    process.on("uncaughtException", crashed);
    process.on("unhandledRejection", crashed);
  }
  main().catch(async (e) => {
    console.error(e.message ?? e);
    // 업로드 전에 예외로 끝나도 업데이트 확인까지는 닿게 한다. 이 버전의 결함으로 매 실행이 죽더라도
    // 고친 릴리스를 받아 스스로 복구해야 한다 (dry-run, 미페어링, 12시간 창은 maybeAutoUpdate가 거른다).
    // 이미 시작한 확인이 있으면 그 확인을 기다린다.
    await runAutoUpdate(resolveMode());
    process.exit(1);
  });
}
