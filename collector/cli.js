#!/usr/bin/env node
// charge-collector CLI — 앱에서 받은 페어링 코드로 연결하고 자동 수집을 등록한다.
//
// 사용법:
//   npx charge-collector <페어링코드>   # 페어링 + 첫 수집 + 스케줄 등록 (일반 사용자용 원라이너)
//   charge-collector run               # 수집 1회 (스케줄러가 호출)
//   charge-collector unpair            # 페어링 해제
//
// 설정 파일: ~/.charge/config.json (CHARGE_HOME으로 위치 변경 가능)

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const HOME = process.env.HOME ?? process.env.USERPROFILE;
const CONF_DIR = process.env.CHARGE_HOME ?? path.join(HOME, ".charge");
const CONF = path.join(CONF_DIR, "config.json");
const WIN = process.platform === "win32";

// 백엔드 주소 — collector/cloud.json (출시 시 charge 전용 프로젝트로 교체, npm 패키지에 포함)
const CLOUD = (() => {
  try {
    return JSON.parse(fs.readFileSync(path.join(__dirname, "cloud.json"), "utf8"));
  } catch {
    return {};
  }
})();

async function pair(code) {
  const url = process.env.CHARGE_URL ?? CLOUD.url;
  const anon = process.env.CHARGE_ANON ?? CLOUD.anon;
  if (!url || !anon) {
    console.error("백엔드 주소가 없습니다 (collector/cloud.json 또는 CHARGE_URL/CHARGE_ANON).");
    process.exit(1);
  }
  const res = await fetch(`${url}/rest/v1/rpc/charge_claim_pairing_code`, {
    method: "POST",
    headers: { apikey: anon, Authorization: `Bearer ${anon}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_code: code, p_label: require("node:os").hostname() }),
    signal: AbortSignal.timeout(15_000),
  });
  const token = res.ok ? await res.json() : null;
  if (!token || typeof token !== "string") {
    console.error(res.ok ? "잘못됐거나 만료된 페어링 코드입니다." : `페어링 실패 (${res.status}): ${await res.text()}`);
    console.error("앱에서 새 코드를 발급받아 다시 시도하세요 (코드는 10분간 유효).");
    process.exit(1);
  }
  // 디바이스 토큰은 본인만 읽을 수 있게 저장 (0700/0600)
  fs.mkdirSync(CONF_DIR, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(CONF_DIR, 0o700); } catch {}
  fs.writeFileSync(CONF, JSON.stringify({ url, anon, token }, null, 2), { mode: 0o600 });
  try { fs.chmodSync(CONF, 0o600); } catch {}
  console.log("✓ 페어링 완료");
}

// npx 캐시는 언제든 청소될 수 있으므로, 스케줄 등록 전에 런타임을 ~/.charge/app 으로 복사한다
function installRuntime() {
  const dest = path.join(CONF_DIR, "app");
  fs.mkdirSync(dest, { recursive: true, mode: 0o700 });
  for (const f of ["cli.js", "collect.js", "install.sh", "install.ps1", "cloud.json", "package.json"]) {
    const src = path.join(__dirname, f);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(dest, f));
  }
  if (!WIN) {
    try { fs.chmodSync(path.join(dest, "install.sh"), 0o755); } catch {}
  }
  return dest;
}

function collect(dir = __dirname) {
  execFileSync(process.execPath, [path.join(dir, "collect.js")], { stdio: "inherit" });
}

function installSchedule() {
  const dir = installRuntime();
  const p = path.join(dir, WIN ? "install.ps1" : "install.sh");
  if (WIN) {
    execFileSync("powershell.exe", ["-ExecutionPolicy", "Bypass", "-File", p], { stdio: "inherit" });
  } else {
    execFileSync("/bin/bash", [p], { stdio: "inherit" });
  }
}

(async () => {
  const arg = process.argv[2];
  if (!arg) {
    console.error("사용법: npx charge-collector <페어링코드>  (앱 온보딩에서 코드 발급)");
    process.exit(1);
  }
  if (arg === "run") {
    collect();
    return;
  }
  if (arg === "unpair") {
    fs.rmSync(CONF, { force: true });
    console.log("✓ 페어링 해제 (스케줄 해제는 install.sh/install.ps1 안내 참고)");
    return;
  }
  // 페어링 코드로 간주: 페어링 → 첫 수집 → 스케줄 등록
  await pair(arg);
  console.log("첫 수집을 실행합니다…");
  collect();
  console.log("5분 간격 자동 수집을 등록합니다…");
  installSchedule();
  console.log("✓ 설정 끝! 이제 앱에서 데이터가 보입니다.");
})().catch((e) => {
  console.error(e.message ?? e);
  process.exit(1);
});
