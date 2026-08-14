#!/usr/bin/env node
// charge-connect CLI — 앱에서 받은 페어링 코드로 연결하고 자동 수집을 등록한다.
//
// 사용법:
//   npx charge-connect <페어링코드> [--label 이름]  # 페어링 + 첫 수집 + 스케줄 등록 (원라이너)
//                                    # --label(또는 CHARGE_LABEL)로 앱에 표시될 기기명 지정, 기본은 호스트명
//   charge-connect run               # 수집 1회 (스케줄러가 호출)
//   charge-connect unpair            # 페어링 해제 (서버 디바이스 토큰도 폐기)
//
// 설정 파일: ~/.charge/config.json (CHARGE_HOME으로 위치 변경 가능)

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { CCUSAGE_PKG } = require("./collect.js"); // 버전 고정을 한 곳에서 관리
const { resolveInstallationID } = require("./identity.js");

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
  fs.writeFileSync(CONF, JSON.stringify({ url, anon, token, install_id: installationID }, null, 2), { mode: 0o600 });
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

// npx 캐시는 언제든 청소될 수 있으므로, 스케줄 등록 전에 런타임을 ~/.charge/app 으로 복사한다
function installRuntime() {
  const dest = path.join(CONF_DIR, "app");
  fs.mkdirSync(dest, { recursive: true, mode: 0o700 });
  const files = ["cli.js", "collect.js", "identity.js", "install.sh", "install.linux.sh", "install.ps1", "cloud.json", "package.json"];
  for (const f of files) {
    const src = path.join(__dirname, f);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(dest, f));
  }
  if (!WIN) {
    for (const f of ["install.sh", "install.linux.sh"]) {
      try { fs.chmodSync(path.join(dest, f), 0o755); } catch {}
    }
  }
  return dest;
}

function collect(dir = __dirname) {
  execFileSync(process.execPath, [path.join(dir, "collect.js")], { stdio: "inherit" });
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

async function main() {
  const arg = process.argv[2];
  if (!arg) {
    console.error("사용법: npx charge-connect <페어링코드>  (앱 온보딩에서 코드 발급)");
    process.exit(1);
  }
  if (arg === "run") {
    collect();
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
  const dir = installRuntime();

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
  isNewerVersion,
  main,
  maybeUpdateBeforePairing,
  pair,
  resolveLabel,
  resolveNpmCLI,
};
