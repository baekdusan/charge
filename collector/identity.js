const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const INSTALLATION_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function parseInstallationID(raw) {
  try {
    const parsed = JSON.parse(String(raw));
    const id = typeof parsed === "string" ? parsed : parsed?.installation_id;
    return typeof id === "string" && INSTALLATION_ID_RE.test(id) ? id.toLowerCase() : null;
  } catch {
    const id = String(raw).trim();
    return INSTALLATION_ID_RE.test(id) ? id.toLowerCase() : null;
  }
}

// 페어링 토큰(config.json)과 분리해 보관한다. unpair/re-pair나 토큰 회전 뒤에도 같은
// 설치를 같은 기기로 알아봐야 하고, 호스트명은 표시 이름일 뿐 식별자가 아니기 때문이다.
function resolveInstallationID(file, { randomUUID = crypto.randomUUID } = {}) {
  try {
    const existing = parseInstallationID(fs.readFileSync(file, "utf8"));
    if (existing) return existing;
  } catch {}

  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  try { fs.chmodSync(path.dirname(file), 0o700); } catch {}

  const created = randomUUID().toLowerCase();
  const body = JSON.stringify({ installation_id: created }, null, 2);
  try {
    // 동시에 두 페어링이 시작돼도 먼저 쓴 id가 정본이다.
    fs.writeFileSync(file, body, { flag: "wx", mode: 0o600 });
  } catch (e) {
    if (e?.code !== "EEXIST") throw e;
    const winner = parseInstallationID(fs.readFileSync(file, "utf8"));
    if (winner) return winner;
    // 기존 파일이 깨졌다면 새 정상값으로 복구한다. 이 파일에는 자격증명이 없다.
    fs.writeFileSync(file, body, { mode: 0o600 });
  }
  try { fs.chmodSync(file, 0o600); } catch {}
  return created;
}

// 계정 UUID를 못 얻은 관측끼리 전역 account='' 행에서 경쟁하지 않도록 기기별로 격리한다.
// 접두사는 앱/백엔드가 "확인된 동일 계정"과 구분할 수 있게 의도적으로 남긴다.
function unknownAccountKey(installationID, providerID) {
  if (!installationID || !providerID) return null;
  const digest = crypto
    .createHash("sha256")
    .update(`${installationID}\0${providerID}`)
    .digest("hex")
    .slice(0, 16);
  return `unknown:${digest}`;
}

module.exports = { parseInstallationID, resolveInstallationID, unknownAccountKey };
