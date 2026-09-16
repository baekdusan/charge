#!/usr/bin/env node
// charge-connect CLI — 앱에서 받은 페어링 코드로 연결하고 자동 수집을 등록한다.
//
// 사용법:
//   npx charge-connect <페어링코드> [--label 이름]  # 페어링 + 첫 수집 + 스케줄 등록 (원라이너)
//                                    # --label(또는 CHARGE_LABEL)로 앱에 표시될 기기명 지정, 기본은 호스트명
//   charge-connect run               # 수집 1회 (설치된 ~/.charge/app의 collect.js로, 스케줄 실행과 상태와 잠금을 같이 쓴다)
//   charge-connect update            # 기존 설치 갱신: npx charge-connect@latest update
//   charge-connect unpair            # 페어링 해제 (서버 디바이스 토큰도 폐기)
//
// 설정 파일: ~/.charge/config.json (CHARGE_HOME으로 위치 변경 가능)

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { CCUSAGE_PKG } = require("./collect.js"); // 버전 고정을 한 곳에서 관리
const { resolveInstallationID } = require("./identity.js");
const {
  UPDATE_MARKER, acquireUpdateLock, checkSyntax, installStaged, nodeSelfTest, recoverInterruptedUpdate, releaseUpdateLock,
  sweepUpdateLeftovers,
} = require("./updater.js");

const PACKAGE_NAME = "charge-connect";
const CURRENT_VERSION = (() => {
  try { return require("./package.json").version; } catch { return null; }
})();

const HOME = process.env.HOME ?? process.env.USERPROFILE;
const CONF_DIR = process.env.CHARGE_HOME ?? path.join(HOME, ".charge");
const CONF = path.join(CONF_DIR, "config.json");
const DEVICE = path.join(CONF_DIR, "device.json");
const WIN = process.platform === "win32";
const LINUX = process.platform === "linux";
const INSTALLER = WIN ? "install.ps1" : LINUX ? "install.linux.sh" : "install.sh";

function parseVersion(value) {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(String(value ?? ""));
  return match ? { numbers: match.slice(1, 4).map(Number), prerelease: match[4] ?? null } : null;
}

function isNewerVersion(current, candidate) {
  const a = parseVersion(current);
  const b = parseVersion(candidate);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i += 1) {
    if (a.numbers[i] !== b.numbers[i]) return b.numbers[i] > a.numbers[i];
  }
  return a.prerelease !== null && b.prerelease === null;
}

function resolveNpmCLI() {
  const candidates = [
    process.env.npm_execpath,
    path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js"),
    path.resolve(path.dirname(process.execPath), "..", "lib", "node_modules", "npm", "bin", "npm-cli.js"),
  ].filter(Boolean);
  return candidates.find((candidate) => fs.existsSync(candidate)) ?? null;
}

function launchUpdatedVersion(version) {
  const npmCLI = resolveNpmCLI();
  if (!npmCLI) throw new Error("npm 실행 파일을 찾을 수 없어 자동 업데이트할 수 없습니다.");
  const npmArgs = path.basename(npmCLI) === "npx-cli.js"
    ? [npmCLI, "--yes", `${PACKAGE_NAME}@${version}`, ...process.argv.slice(2)]
    : [
        npmCLI,
        "exec",
        "--yes",
        `--package=${PACKAGE_NAME}@${version}`,
        "--",
        PACKAGE_NAME,
        ...process.argv.slice(2),
      ];
  execFileSync(process.execPath, npmArgs, {
    stdio: "inherit",
    env: { ...process.env, CHARGE_UPDATE_CHECKED: "1" },
  });
}

async function maybeUpdateBeforePairing({
  currentVersion = CURRENT_VERSION,
  fetchFn = globalThis.fetch,
  interactive = Boolean(process.stdin.isTTY && process.stdout.isTTY),
  ask = null,
  launch = launchUpdatedVersion,
  env = process.env,
  log = console.log,
} = {}) {
  if (!currentVersion || env.CHARGE_UPDATE_CHECKED === "1" || env.CHARGE_SKIP_UPDATE === "1") return false;

  let latest;
  try {
    const response = await fetchFn(`https://registry.npmjs.org/${PACKAGE_NAME}/latest`, {
      headers: { Accept: "application/json", "User-Agent": `${PACKAGE_NAME}/${currentVersion}` },
      signal: AbortSignal.timeout(8_000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    latest = (await response.json())?.version;
  } catch (error) {
    log(`업데이트 확인을 건너뜁니다 (${error?.message ?? error}). 현재 ${currentVersion}로 계속합니다.`);
    return false;
  }

  if (!isNewerVersion(currentVersion, latest)) return false;
  log(`charge-connect 새 버전 ${latest}이 있습니다 (현재 ${currentVersion}).`);
  if (!interactive) {
    log(`자동 업데이트하려면 'npx ${PACKAGE_NAME}@${latest} <페어링코드>'로 다시 실행하세요.`);
    return false;
  }

  let answer;
  if (ask) {
    answer = await ask(`먼저 ${latest}(으)로 업데이트한 뒤 연동할까요? (Y/n) `);
  } else {
    const rl = require("node:readline/promises").createInterface({ input: process.stdin, output: process.stdout });
    try {
      answer = await rl.question(`먼저 ${latest}(으)로 업데이트한 뒤 연동할까요? (Y/n) `);
    } finally {
      rl.close();
    }
  }
  const normalized = String(answer ?? "").trim().toLowerCase();
  if (["n", "no", "아니오"].includes(normalized)) {
    log(`업데이트를 건너뛰고 ${currentVersion}로 연동합니다.`);
    return false;
  }
  if (!["", "y", "yes", "ok", "네"].includes(normalized)) {
    log(`응답을 확인하지 못해 업데이트를 건너뛰고 ${currentVersion}로 연동합니다.`);
    return false;
  }

  log(`charge-connect ${latest}(으)로 업데이트한 뒤 연동을 계속합니다…`);
  launch(latest);
  return true;
}

// 백엔드 주소 — collector/cloud.json (출시 시 charge 전용 프로젝트로 교체, npm 패키지에 포함)
const CLOUD = (() => {
  try {
    return JSON.parse(fs.readFileSync(path.join(__dirname, "cloud.json"), "utf8"));
  } catch {
    return {};
  }
})();

// 앱 기기 목록에 표시될 이름 — 기본은 호스트명이지만 실명이 든 경우가 흔하므로
// 최초 페어링 때 --label 또는 CHARGE_LABEL로 덮어쓸 수 있게 하고, 무엇으로 등록되는지 알려준다.
// 기기 식별은 별도 installation id가 담당하므로 라벨이 같거나 나중에 바뀌어도 충돌하지 않는다.
function resolveLabel() {
  const i = process.argv.indexOf("--label");
  const flag = i > -1 && process.argv[i + 1] && !process.argv[i + 1].startsWith("-") ? process.argv[i + 1] : null;
  const raw = flag ?? process.env.CHARGE_LABEL ?? require("node:os").hostname();
  return String(raw).trim().slice(0, 64) || require("node:os").hostname();
}

async function pair(code) {
  const url = process.env.CHARGE_URL ?? CLOUD.url;
  const anon = process.env.CHARGE_ANON ?? CLOUD.anon;
  if (!url || !anon) {
    console.error("백엔드 주소가 없습니다 (collector/cloud.json 또는 CHARGE_URL/CHARGE_ANON).");
    process.exit(1);
  }
  const label = resolveLabel();
  const installationID = resolveInstallationID(DEVICE);
  const claim = (includeInstallationID) => fetch(`${url}/rest/v1/rpc/charge_claim_pairing_code`, {
      method: "POST",
      headers: { apikey: anon, Authorization: `Bearer ${anon}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        p_code: code,
        p_label: label,
        ...(includeInstallationID ? { p_install_id: installationID } : {}),
      }),
      signal: AbortSignal.timeout(15_000),
    });
  let res = await claim(true);
  if (!res.ok) {
    const body = await res.text();
    // 수집기부터 배포된 경우 구버전 DB에는 세 번째 인자가 없다. 함수가 실행되지 않은
    // PGRST202/404에만 두 인자 호출로 재시도하므로 일회용 코드를 두 번 소비하지 않는다.
    if (res.status === 404 || body.includes("PGRST202")) {
      res = await claim(false);
    } else {
      console.error(`페어링 실패 (${res.status}): ${body}`);
      console.error("앱에서 새 코드를 발급받아 다시 시도하세요 (코드는 10분간 유효).");
      process.exit(1);
    }
  }
  const token = res.ok ? await res.json() : null;
  if (!token || typeof token !== "string") {
    console.error(res.ok ? "잘못됐거나 만료된 페어링 코드입니다." : `페어링 실패 (${res.status}): ${await res.text()}`);
    console.error("앱에서 새 코드를 발급받아 다시 시도하세요 (코드는 10분간 유효).");
    process.exit(1);
  }
  // 디바이스 토큰은 본인만 읽을 수 있게 저장 (0700/0600)
  fs.mkdirSync(CONF_DIR, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(CONF_DIR, 0o700); } catch {}
  const claude_environment = Object.fromEntries(
    ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"]
      .filter((key) => process.env[key] !== undefined)
      .map((key) => [key, process.env[key]])
  );
  fs.writeFileSync(CONF, JSON.stringify({ url, anon, token, install_id: installationID, claude_environment }, null, 2), { mode: 0o600 });
  try { fs.chmodSync(CONF, 0o600); } catch {}
  console.log(`✓ 페어링 완료 — 이 컴퓨터가 '${label}'(으)로 등록되었습니다.`);
}

// 페어링 해제: 서버의 디바이스 토큰까지 폐기한다.
// 로컬 config만 지우면 그 토큰은 서버에서 계속 유효해, 유출됐을 경우 남이 업로드에 쓸 수 있다.
async function unpair() {
  let conf = null;
  try { conf = JSON.parse(fs.readFileSync(CONF, "utf8")); } catch {}
  if (conf?.url && conf?.anon && conf?.token) {
    try {
      const res = await fetch(`${conf.url}/rest/v1/rpc/charge_revoke_device`, {
        method: "POST",
        headers: { apikey: conf.anon, Authorization: `Bearer ${conf.anon}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p_token: conf.token }),
        signal: AbortSignal.timeout(15_000),
      });
      if (!res.ok) console.error(`서버 디바이스 폐기 실패 (${res.status}) — 앱 설정의 기기 목록에서 직접 제거하세요.`);
    } catch {
      console.error("서버 디바이스 폐기 요청에 실패했습니다 — 앱 설정의 기기 목록에서 직접 제거하세요.");
    }
  }
  fs.rmSync(CONF, { force: true });
  console.log("✓ 페어링 해제 (스케줄 해제는 install.sh/install.ps1 안내 참고)");
}

// 런타임 파일 목록은 package.json의 files를 따른다, 새 파일(updater.js 등)을 여기서 따로 챙기지 않게.
// package.json을 못 읽는 경우에만 아래 고정 목록으로 대신한다.
function runtimeFiles(dir = __dirname) {
  const fallback = ["cli.js", "collect.js", "identity.js", "updater.js", "install.sh", "install.linux.sh", "install.ps1", "cloud.json"];
  let listed = null;
  try {
    const files = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")).files;
    if (Array.isArray(files)) listed = files.filter((f) => typeof f === "string" && /^[A-Za-z0-9._-]+$/.test(f));
  } catch {}
  return [...new Set([...(listed ?? fallback), "package.json"])];
}

// 페어링 직후 자동 업데이트가 마침 앱 폴더를 바꾸는 중이면 이만큼 기다렸다가 한 번 더 잠금을 잡아 본다
const PAIRING_LOCK_WAIT_MS = 5_000;
const LOCKED_MESSAGE = "자동 업데이트가 수집기 파일을 교체하는 중이라 지금은 설치하지 않습니다. 잠시 뒤 `npx charge-connect@latest update`로 다시 시도하세요.";

function packageVersion(dir) {
  try {
    const version = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")).version;
    return typeof version === "string" && version ? version : null;
  } catch {
    return null;
  }
}

// npx 캐시는 언제든 청소될 수 있으므로, 스케줄 등록 전에 런타임을 ~/.charge/app으로 복사한다.
// 자동 업데이트와 같은 순서로 바꾼다 (updater.js의 installStaged): ~/.charge/update.lock을 잡아 스케줄 실행의 자동 업데이트와
// 겹치지 않게 하고, 모든 .js를 node --check로 검사한 뒤, 지금 파일을 app.prev에 백업하고 진행 표시(UPDATE_MARKER)를 남긴 채
// 파일마다 <파일>.new로 쓰고 이름을 바꿔 덮는다. collect.js는 그다음이 package.json인 맨 뒤에 바꾼다: 도중에 끊기면 옛 collect.js가
// 그대로 돌고, 표시를 본 다음 수집이 app.prev로 되돌린다 (전원 차단, Ctrl+C로 반쪽짜리 collect.js가 남아 수집이 매번 죽고 자동
// 업데이트에도 닿지 못하는 일이 없게). 설치 뒤 자체 점검에 실패하면 app.prev로 되돌리고 던진다. 원본 폴더(npx 캐시, 저장소)는
// 옮기거나 지우지 않는다. 앱 폴더가 아직 없는 첫 설치는 백업할 것이 없으니 app.prev를 남기지 않는다. 잠금을 살아 있는 다른
// 프로세스가 잡고 있으면 waitMs만큼 기다렸다가 한 번 더 시도하고, 그래도 잡혀 있으면 code "LOCKED" 오류를 던진다 (아무것도
// 바꾸지 않는다). source는 테스트 주입용이다.
async function installRuntime(confDir = CONF_DIR, { waitMs = 0, log = console.log, source = __dirname } = {}) {
  const dest = path.join(confDir, "app");
  const backupDir = path.join(confDir, "app.prev");
  const lockFile = path.join(confDir, "update.lock");
  fs.mkdirSync(confDir, { recursive: true, mode: 0o700 });
  let locked = acquireUpdateLock(lockFile);
  if (!locked && waitMs > 0) {
    log(`자동 업데이트가 수집기 파일을 교체하는 중입니다. ${Math.round(waitMs / 1000)}초 뒤 다시 시도합니다…`);
    await new Promise((resolve) => setTimeout(resolve, waitMs));
    locked = acquireUpdateLock(lockFile);
  }
  if (!locked) throw Object.assign(new Error(LOCKED_MESSAGE), { code: "LOCKED" });
  try {
    // 잠금을 잡았으니 남아 있는 점검, 스테이징 폴더는 도중에 죽은 설치의 것이다
    sweepUpdateLeftovers(confDir);
    const names = runtimeFiles(source);
    // 교체 전에 검사한다: 빠진 파일이나 문법이 깨진 파일이 하나라도 있으면 아무것도 바꾸지 않는다. 자동 업데이트(extractRelease)처럼
    // .json은 모두 해석돼야 하고, package.json이 나열한 파일은 모두 있어야 한다. 없는 파일을 건너뛰고 설치하면 옛 파일 하나가
    // 새 파일들 사이에 남는데, 설치 후 자체 점검은 package.json의 버전만 보므로 그런 설치를 걸러 주지 않는다.
    const missing = names.filter((name) => !fs.existsSync(path.join(source, name)));
    if (missing.length) throw new Error(`설치할 패키지에 없는 파일: ${missing.join(", ")} (${source})`);
    for (const name of names.filter((name) => name.endsWith(".json"))) {
      try {
        JSON.parse(fs.readFileSync(path.join(source, name), "utf8"));
      } catch {
        throw new Error(`설치할 패키지의 ${name} 파일을 해석할 수 없습니다 (${source})`);
      }
    }
    await checkSyntax(source, names);
    const fresh = !fs.existsSync(dest);
    fs.mkdirSync(dest, { recursive: true, mode: 0o700 });
    // 교체 도중 끊긴 뒤 되돌리기까지 실패한 업데이트의 진행 표시가 남아 있으면 installStaged는 백업을 덮지 않으려고 거부한다.
    // 잠금을 잡았으니 그 업데이트는 살아 있지 않다. 먼저 app.prev로 되돌려 보고(백업이 섞인 폴더가 아니라 온전한 옛 런타임이 되게),
    // 되돌리지 못하면 표시만 지우고 계속한다 (어차피 런타임 전체를 이 패키지의 파일로 바꾼다).
    if (fs.existsSync(path.join(dest, UPDATE_MARKER))) {
      try {
        recoverInterruptedUpdate({ appDir: dest });
        log("교체 도중 끊긴 업데이트를 app.prev 백업으로 되돌린 뒤 설치합니다.");
      } catch (e) {
        log(`교체 도중 끊긴 업데이트를 되돌리지 못했습니다 (${e?.message ?? e}). 런타임 전체를 새로 설치합니다.`);
        fs.rmSync(path.join(dest, UPDATE_MARKER), { force: true });
      }
    }
    const last = ["collect.js", "package.json"];
    const ordered = [...names.filter((name) => !last.includes(name)), ...last.filter((name) => names.includes(name))];
    const toVersion = packageVersion(source);
    await installStaged({
      stagingDir: source,
      names: ordered,
      appDir: dest,
      backupDir,
      fromVersion: packageVersion(dest),
      toVersion,
      // 자동 업데이트와 같은 설치 후 자체 점검 (버전을 모르는 패키지는 결과 줄을 맞출 수 없어 건너뛴다)
      verify: toVersion ? () => nodeSelfTest(dest, toVersion) : null,
    });
    // 첫 설치의 빈 백업은 지운다 (교체가 끝나 진행 표시도 지워졌으니 되돌릴 일이 없다)
    if (fresh) fs.rmSync(backupDir, { recursive: true, force: true });
    if (!WIN) {
      for (const f of ["install.sh", "install.linux.sh"]) {
        try { fs.chmodSync(path.join(dest, f), 0o755); } catch {}
      }
    }
  } finally {
    releaseUpdateLock(lockFile);
  }
  return dest;
}

function collect(dir = __dirname) {
  execFileSync(process.execPath, [path.join(dir, "collect.js")], { stdio: "inherit" });
}

// `charge-connect run`이 돌릴 수집기 폴더. 상태 파일(429 게이트, 요청 간격과 그 잠금, 수집 건강)은 collect.js 옆에 있으므로,
// 설치된 런타임(~/.charge/app, 스케줄이 돌리는 것)이 있으면 그것을 돌려야 수동 실행이 스케줄 실행과 같은 기록을 보고 같은 잠금에
// 걸린다. npx 캐시의 이 패키지를 돌리면 기록이 따로라 둘이 같은 순간에 usage를 두 번 묻는다. 설치 전(페어링 전)에는 이 패키지다.
function installedRuntimeDir(confDir = CONF_DIR) {
  const dir = path.join(confDir, "app");
  return fs.existsSync(path.join(dir, "collect.js")) ? dir : __dirname;
}

function installSchedule(dir) {
  const p = path.join(dir, INSTALLER);
  if (WIN) {
    execFileSync("powershell.exe", ["-ExecutionPolicy", "Bypass", "-File", p], { stdio: "inherit" });
  } else {
    execFileSync("/bin/bash", [p], { stdio: "inherit" });
  }
}

// ccusage가 전역에 없어도 수집은 npx 폴백으로 동작하지만, 5분마다 npx 해석을 거쳐
// 느려진다. 사용자가 터미널 앞에 있는 페어링 시점에 한 번 물어보고 깔아준다.
async function offerCcusageInstall() {
  // Windows에서 ccusage/npm은 .cmd 셔틀이라 cmd.exe /d /c 로 감싼다 — shell:true의
  // DEP0190 경고를 피하면서 AutoRun도 억제하는, collect.js의 runAsync와 같은 방식.
  const run = (cmd, args, opts) =>
    execFileSync(WIN ? process.env.ComSpec ?? "cmd.exe" : cmd, WIN ? ["/d", "/c", cmd, ...args] : args, opts);
  try {
    run("ccusage", ["--version"], { stdio: "ignore", timeout: 15_000 });
    return; // 이미 설치돼 있다
  } catch {}
  const hint = `'npm i -g ${CCUSAGE_PKG}'를 해두면 수집이 빨라집니다`;
  // 파이프/CI처럼 물어볼 콘솔이 없으면 안내만 하고 넘어간다
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    console.log(`참고: ${hint} (지금은 npx 대체 실행으로 동작).`);
    return;
  }
  const rl = require("node:readline/promises").createInterface({ input: process.stdin, output: process.stdout });
  const answer = (await rl.question("수집 도구 ccusage를 전역 설치할까요? 수집이 빨라집니다 (Y/n) ")).trim().toLowerCase();
  rl.close();
  if (answer === "n" || answer === "no") {
    console.log(`건너뜁니다 — 나중에 ${hint}.`);
    return;
  }
  try {
    // 전역 설치도 버전을 고정한다 — @latest면 설치 시점 최신본의 라이프사이클 스크립트를 그대로 실행한다
    run("npm", ["install", "-g", CCUSAGE_PKG], { stdio: "inherit", timeout: 300_000 });
    console.log("✓ ccusage 설치 완료");
  } catch {
    console.error(
      "설치에 실패했지만 수집은 npx 대체 실행으로 계속 동작합니다." +
        (WIN ? ` 나중에 ${hint}.` : ` 나중에 ${hint} (권한 오류라면 'sudo npm i -g ccusage').`)
    );
  }
}

function launchAgentRegistered(dir, home = HOME) {
  try {
    const plist = fs.readFileSync(path.join(home, "Library", "LaunchAgents", "com.charge.connect.plist"), "utf8");
    return plist.includes(path.join(dir, "collect.js"));
  } catch {
    return false;
  }
}

// 기존 설치 갱신: npx charge-connect@latest update
// 0.1.x 수집기는 스스로 업데이트하지 못한다. 새 런타임을 ~/.charge/app에 복사하고, 설치 스크립트가
// 조용히 다시 돌려도 되는 플랫폼에서만 스케줄을 다시 등록한 뒤, 한 번 수집해 확인한다.
// 반환: { installed, collected, version }. 설정 파일은 건드리지 않는다.
async function update({
  confDir = CONF_DIR,
  platform = process.platform,
  home = HOME,
  currentVersion = CURRENT_VERSION,
  install = installRuntime,
  schedule = installSchedule,
  runCollect = collect,
  log = console.log,
  logError = console.error,
} = {}) {
  if (!fs.existsSync(path.join(confDir, "config.json"))) {
    logError("이 컴퓨터는 아직 연동되지 않았습니다. 앱에서 코드를 발급받아 `npx charge-connect <페어링코드>`를 먼저 실행하세요.");
    return { installed: false, collected: false, version: null };
  }
  const installedVersion = (dir) => {
    try {
      return JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")).version ?? null;
    } catch {
      return null;
    }
  };
  // 자동 업데이트로 이미 더 새 버전이 깔려 있으면 덮지 않는다. `@latest` 없이 부른 npx 캐시나
  // 전역 설치의 옛 패키지가 새 런타임을 되돌리면, 다음 확인 창(최대 13시간)까지 옛 버전으로 돈다.
  // 교체 도중 끊긴 업데이트의 진행 표시가 남아 있으면 package.json의 버전을 믿지 않는다 (맨 마지막에 바꾸는 파일이라 새 버전이
  // 적혀 있어도 다음 수집이 app.prev로 되돌린다). 그때는 installRuntime이 잠금 아래에서 되돌린 뒤 이 패키지를 설치한다.
  const appDir = path.join(confDir, "app");
  let dir;
  if (!fs.existsSync(path.join(appDir, UPDATE_MARKER)) && isNewerVersion(currentVersion, installedVersion(appDir))) {
    dir = appDir;
    log(`${dir}에 더 새 버전(${installedVersion(dir)})이 이미 설치돼 있어 파일은 그대로 둡니다 (실행한 패키지는 ${currentVersion}).`);
  } else {
    try {
      dir = await install(confDir);
    } catch (e) {
      // 잠금(자동 업데이트가 교체 중)이면 아무것도 바꾸지 않았고, 그 밖의 실패는 installStaged가 app.prev로 되돌렸다
      logError(e?.code === "LOCKED" ? e.message : `수집기 파일 설치 실패: ${e?.message ?? e}`);
      return { installed: false, collected: false, version: null };
    }
    log(`수집기 파일을 ${dir}에 설치했습니다.`);
  }
  const version = installedVersion(dir);

  if (platform === "win32") {
    // install.ps1은 비관리자 창에서 돌면 숨김(S4U) 작업을 콘솔 창이 뜨는 작업으로 되돌리고, 작업을 직접
    // 실행해 보기도 한다. 관리자 창에서 만든 등록을 망칠 수 있어 자동으로 부르지 않는다.
    // 작업은 이미 같은 경로의 collect.js를 가리키므로 다음 실행부터 새 파일이 쓰인다.
    log("작업 스케줄러 등록은 그대로 둡니다 (다음 5분 수집부터 새 버전이 실행됩니다).");
    log(`등록을 다시 하려면: powershell -ExecutionPolicy Bypass -File "${path.join(dir, "install.ps1")}"`);
  } else if (platform === "darwin" && launchAgentRegistered(dir, home)) {
    // install.sh를 다시 돌리면 launchd가 RunAtLoad로 수집을 한 번 더 띄워 Claude 요청이 겹친다.
    // 등록이 이미 이 경로를 가리키면 그대로 둔다 (사용자가 unload해 둔 상태도 존중한다).
    log("launchd 자동 수집 등록은 그대로 유지합니다.");
  } else {
    log("5분 간격 자동 수집을 다시 등록합니다…");
    try {
      schedule(dir);
    } catch (e) {
      // 종료 코드 3 = 설치 스크립트가 수동 등록 방법(cron 등)을 이미 출력했다
      if (e?.status === 3) log("이미 위 방법으로 등록해 두었다면 그대로 두면 됩니다.");
      else logError(`자동 수집 등록 실패: ${e?.message ?? e}`);
    }
  }

  log("수집을 한 번 실행합니다…");
  let collected = true;
  try {
    runCollect(dir);
  } catch {
    collected = false;
    logError("수집에 실패했습니다 (네트워크 문제일 수 있습니다). 5분 뒤 자동 수집이 다시 시도합니다.");
  }
  log(`✓ charge-connect ${version ?? "(버전 미상)"} 설치 완료`);
  return { installed: true, collected, version };
}

async function main() {
  const arg = process.argv[2];
  if (!arg) {
    console.error("사용법: npx charge-connect <페어링코드>  (앱 온보딩에서 코드 발급)");
    process.exit(1);
  }
  if (arg === "run") {
    collect(installedRuntimeDir());
    return;
  }
  if (arg === "update") {
    // 페어링 코드가 아니므로 maybeUpdateBeforePairing을 거치지 않는다 (@latest로 부르는 명령이다)
    const result = await update();
    if (!result.installed) process.exit(1);
    return;
  }
  if (arg === "unpair") {
    await unpair();
    return;
  }
  // 페어링 코드를 소비하기 전에 최신 버전으로 넘긴다. 새 프로세스에는 표시를 남겨
  // 재귀 업데이트 확인 없이 곧바로 같은 코드와 옵션으로 페어링하게 한다.
  if (await maybeUpdateBeforePairing()) return;
  // 페어링 코드로 간주: 페어링 → 스케줄 등록 → 첫 수집.
  // 스케줄을 먼저 등록한다 — 첫 수집이 실패해도(네트워크가 잠깐 끊기는 등) 자동 수집은
  // 살아 있어야 한다. 페어링 코드는 이미 소모돼서 같은 코드로 재시도할 수 없기 때문이다.
  await pair(arg);
  let dir;
  try {
    // 자동 업데이트가 마침 교체 중이면 잠깐 기다렸다가 한 번 더 시도한다 (페어링 코드는 이미 소모돼 다시 페어링할 수 없다)
    dir = await installRuntime(CONF_DIR, { waitMs: PAIRING_LOCK_WAIT_MS });
  } catch (e) {
    console.error(e?.code === "LOCKED" ? e.message : `수집기 파일 설치 실패: ${e?.message ?? e}`);
    console.error("페어링은 끝났습니다. 잠시 뒤 `npx charge-connect@latest update`로 설치와 자동 수집 등록을 마무리하세요.");
    process.exit(1);
  }

  console.log("5분 간격 자동 수집을 등록합니다…");
  let scheduled = true;
  let guided = false; // 설치 스크립트가 수동 등록 방법을 이미 출력했다 (종료 코드 3)
  try {
    installSchedule(dir);
  } catch (e) {
    scheduled = false;
    if (e.status === 3) guided = true;
    else console.error(`자동 수집 등록 실패: ${e.message ?? e}`);
  }

  // 스케줄 등록 뒤에 물어본다 — 프롬프트에서 사용자가 자리를 비워도 자동 수집은 이미 살아 있다
  await offerCcusageInstall();

  console.log("첫 수집을 실행합니다…");
  let collected = true;
  try {
    collect(dir);
  } catch {
    collected = false;
    console.error("첫 수집에 실패했습니다 (네트워크 문제일 수 있습니다).");
  }

  if (!scheduled) {
    if (guided) {
      console.error("페어링은 끝났습니다. 위 안내대로 자동 수집을 등록하면 완료됩니다.");
    } else {
      const p = path.join(dir, INSTALLER);
      console.error("페어링은 끝났습니다. 자동 수집 등록만 직접 마무리해주세요.");
      console.error(`  다시 시도: ${WIN ? `powershell -ExecutionPolicy Bypass -File "${p}"` : `bash "${p}"`}`);
    }
    process.exit(1);
  }
  // 첫 수집이 실패했으면 앱에 아직 데이터가 없다 — 됐다고 말하지 않는다
  if (!collected) {
    console.log("✓ 페어링과 자동 수집 등록은 끝났습니다. 5분 뒤 수집을 다시 시도합니다.");
    return;
  }
  console.log("✓ 설정 끝! 이제 앱에서 데이터가 보입니다.");
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e.message ?? e);
    process.exit(1);
  });
}

module.exports = {
  installRuntime,
  installedRuntimeDir,
  isNewerVersion,
  main,
  maybeUpdateBeforePairing,
  pair,
  resolveLabel,
  resolveNpmCLI,
  runtimeFiles,
  update,
};
