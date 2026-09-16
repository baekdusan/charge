#!/usr/bin/env node
// 수집기 릴리스 매니페스트 발행 도구 (npm 패키지 files에 넣지 않는다, 관리자 전용).
//
// 사용법: node scripts/publish-manifest.js <version> [--key-id <id>] [--sql | --apply]
//   1. npm publish 로 charge-connect@<version>을 먼저 올린다 (이 스크립트를 돌릴 같은 collector/ 체크아웃에서).
//   2. 이 스크립트가 `npm view charge-connect@<version> dist --json`에서 integrity, tarball을 읽고
//      tarball 주소 형식을 확인한 뒤, 그 tarball을 직접 받아(리다이렉트는 따라가지 않는다) integrity를 다시 계산하고
//      자동 업데이트가 설치할 파일이 로컬 collector/ 파일과 같은지 비교한다. 하나라도 다르면 서명 키를 읽기 전에 멈춘다.
//   3. 개인키로 서명하고, 수집기와 같은 형식 검사를 거친 뒤 수집기에 내장된 그 key id의 공개키로 다시 검증한다.
//      서명 대상: "charge-connect-release/v1\n" + key_id + "\n" + version + "\n" + integrity + "\n" + tarball
//   4. --sql(기본): charge_collector_releases 업서트 SQL을 출력한다 (여러 번 실행해도 결과가 같다).
//      --apply: 같은 SQL을 운영 DB에 psql로 적용한다 (~/.charge/supabase-db-password.txt).
//
// --key-id: 서명 키 id (기본 k1). updater.js의 RELEASE_KEYS에 있는 id여야 하고, npm에 올라간 직전 릴리스의
//   updater.js에도 있어야 한다 (설치된 수집기는 지금 돌고 있는 릴리스에 내장된 키만 안다).
// 서명 키: ~/.charge/release-signing-key.pem (PKCS8 PEM), 또는 CHARGE_SIGNING_KEY
// (PEM 본문 자체이거나 PEM 파일 경로). 키 내용은 어디에도 출력하지 않는다.

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const zlib = require("node:zlib");
const { execFile } = require("node:child_process");
const { promisify, isDeepStrictEqual } = require("node:util");
const {
  MANIFEST_FORMATS,
  MAX_TARBALL_BYTES,
  PACKAGE_NAME,
  RELEASE_KEYS,
  extractRelease,
  isNewerRelease,
  manifestFormatError,
  parseReleaseVersion,
  parseTar,
  readCapped,
  releaseMessage,
  releaseTarballURL,
  sha512Integrity,
  verifyReleaseSignature,
} = require("../updater.js");

const execFileAsync = promisify(execFile);
const gunzipAsync = promisify(zlib.gunzip);

const COLLECTOR_DIR = path.join(__dirname, "..");
const DOWNLOAD_TIMEOUT_MS = 60_000;

const DATABASE = {
  host: "aws-1-ap-northeast-2.pooler.supabase.com",
  port: "5432",
  user: "postgres.kfzdukmoprvmqiyrptqt",
  dbname: "postgres",
  sslmode: "require",
};

const USAGE = "사용법: node scripts/publish-manifest.js <version> [--key-id <id>] [--sql | --apply]";
const DEFAULT_KEY_ID = "k1";

function parseArgs(argv) {
  const positional = [];
  const outputs = new Set();
  let keyId = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--sql" || arg === "--apply") {
      outputs.add(arg);
    } else if (arg === "--key-id" || arg.startsWith("--key-id=")) {
      if (keyId !== null) throw new Error(`--key-id는 한 번만 줄 수 있습니다\n${USAGE}`);
      keyId = arg === "--key-id" ? argv[++i] ?? "" : arg.slice("--key-id=".length);
      if (!MANIFEST_FORMATS.key_id.test(keyId)) throw new Error(`--key-id는 소문자와 숫자 1~16자여야 합니다\n${USAGE}`);
    } else if (arg.startsWith("--")) {
      throw new Error(`알 수 없는 옵션: ${arg}\n${USAGE}`);
    } else {
      positional.push(arg);
    }
  }
  if (outputs.size > 1) throw new Error(`--sql과 --apply는 함께 쓸 수 없습니다\n${USAGE}`);
  if (positional.length !== 1) throw new Error(USAGE);
  const [version] = positional;
  if (!parseReleaseVersion(version)) throw new Error(`릴리스 버전은 x.y.z 숫자만 받습니다: ${version}`);
  return { version, apply: outputs.has("--apply"), keyId: keyId ?? DEFAULT_KEY_ID };
}

async function npmView(args) {
  const [file, argv] = process.platform === "win32"
    ? [process.env.ComSpec ?? "cmd.exe", ["/d", "/c", "npm", ...args]]
    : ["npm", args];
  const { stdout } = await execFileAsync(file, argv, { encoding: "utf8", timeout: 60_000, maxBuffer: 4 * 1024 * 1024 });
  return stdout;
}

async function npmViewDist(version) {
  const stdout = await npmView(["view", `${PACKAGE_NAME}@${version}`, "dist", "--json"]);
  if (!stdout.trim()) throw new Error(`npm에 ${PACKAGE_NAME}@${version}이 없습니다 (먼저 npm publish)`);
  return JSON.parse(stdout);
}

// npm에 올라간 모든 버전. 버전이 하나뿐이면 npm은 배열 대신 문자열을 준다.
async function npmViewVersions() {
  const stdout = await npmView(["view", PACKAGE_NAME, "versions", "--json"]);
  const parsed = stdout.trim() ? JSON.parse(stdout) : [];
  return Array.isArray(parsed) ? parsed : [parsed];
}

// updater.js 원문의 RELEASE_KEYS에 적힌 key id. 옛 릴리스 코드를 실행하지 않고 글자로만 읽는다. 목록이 없으면 null.
function embeddedKeyIds(source) {
  const block = /RELEASE_KEYS\s*=\s*Object\.freeze\(\{([\s\S]*?)\}\)/.exec(String(source ?? ""));
  if (!block) return null;
  return new Set([...block[1].matchAll(/^\s*["']?([a-z0-9]{1,16})["']?\s*:/gm)].map((match) => match[1]));
}

// 서명하려는 버전 바로 앞의 npm 릴리스와 그 updater.js에 내장된 key id. 앞 릴리스가 없으면 null,
// 앞 릴리스에 RELEASE_KEYS가 없으면(0.1.x, 자동 업데이트가 없다) ids null. 받은 tarball은 npm integrity로 확인한다.
async function previousReleaseKeyIds(version, { viewVersions = npmViewVersions, viewDist = npmViewDist, fetchFn = globalThis.fetch } = {}) {
  const older = (await viewVersions()).filter((v) => parseReleaseVersion(v) && isNewerRelease(v, version));
  if (!older.length) return null;
  const previous = older.reduce((a, b) => (isNewerRelease(a, b) ? b : a));
  const { integrity, tarball } = validateDist(previous, await viewDist(previous));
  const res = await fetchFn(tarball, { redirect: "error", signal: AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS) });
  if (!res.ok) throw new Error(`직전 릴리스 ${previous} tarball 다운로드 실패 (${res.status})`);
  const tgz = await readCapped(res, MAX_TARBALL_BYTES);
  if (sha512Integrity(tgz) !== integrity) throw new Error(`직전 릴리스 ${previous} tarball이 npm view의 integrity와 다릅니다`);
  const tar = await gunzipAsync(tgz, { maxOutputLength: 16 * 1024 * 1024 });
  const updater = parseTar(tar).find((entry) => entry.name === "package/updater.js" && entry.type === "0");
  return { version: previous, ids: updater ? embeddedKeyIds(updater.data.toString("utf8")) : null };
}

function loadSigningKey({ env = process.env, home = process.env.HOME ?? process.env.USERPROFILE, readFile = fs.readFileSync } = {}) {
  const configured = env.CHARGE_SIGNING_KEY;
  let pem;
  if (configured && configured.trimStart().startsWith("-----BEGIN")) pem = configured;
  else pem = readFile(configured || path.join(home, ".charge", "release-signing-key.pem"), "utf8");
  const key = crypto.createPrivateKey(pem);
  if (key.asymmetricKeyType !== "ed25519") throw new Error("서명 키가 Ed25519가 아닙니다");
  return key;
}

function validateDist(version, dist) {
  const integrity = dist?.integrity;
  const tarball = dist?.tarball;
  if (typeof tarball !== "string" || tarball !== releaseTarballURL(version)) {
    throw new Error(`tarball 주소가 예상 형식이 아닙니다: ${tarball}`);
  }
  if (typeof integrity !== "string" || !/^sha512-[A-Za-z0-9+/]{86}==$/.test(integrity)) {
    throw new Error(`integrity가 sha512 형식이 아닙니다: ${integrity}`);
  }
  return { integrity, tarball };
}

// 서명은 "이 tarball이 관리자 로컬의 collector/와 같다"는 확인이어야 한다. npm이 알려준 integrity만 믿고
// 서명하면 npm 계정 탈취나 엉뚱한 폴더에서 올린 빌드에도 유효한 서명이 붙고, 모든 수집기가 그것을 설치한다.
// 그래서 레지스트리 tarball을 직접 받아 integrity를 다시 계산하고, 자동 업데이트가 설치할 파일(tarball의
// package.json files)과 로컬 package.json의 files가 양쪽에 모두 있고 내용이 같을 때만 통과시킨다.
// package.json은 npm이 다시 써서(끝 줄바꿈 등) 바이트가 달라지므로 JSON 값으로 비교한다.
async function verifyRegistryTarball({ version, dist, localDir = COLLECTOR_DIR, fetchFn = globalThis.fetch }) {
  const { integrity, tarball } = validateDist(version, dist);
  // 수집기와 같이 리다이렉트를 따라가지 않는다, 서명할 주소 그대로에서 받은 바이트만 비교한다
  const res = await fetchFn(tarball, { redirect: "error", signal: AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS) });
  if (!res.ok) throw new Error(`레지스트리 tarball 다운로드 실패 (${res.status})`);
  const tgz = await readCapped(res, MAX_TARBALL_BYTES);
  if (sha512Integrity(tgz) !== integrity) throw new Error("레지스트리 tarball이 npm view의 integrity와 다릅니다, 서명하지 않습니다");
  const { files, pkg } = await extractRelease(tgz, version);

  const readLocal = (name) => {
    try {
      return fs.readFileSync(path.join(localDir, name));
    } catch {
      return null;
    }
  };
  const listed = (manifest) => (Array.isArray(manifest?.files) ? manifest.files.filter((f) => typeof f === "string") : []);
  let localPkg = null;
  try {
    localPkg = JSON.parse(String(readLocal("package.json") ?? ""));
  } catch {}
  const names = [...new Set(["package.json", ...files.keys(), ...listed(pkg), ...listed(localPkg)])];

  const mismatched = [];
  for (const name of names) {
    const packed = files.get(name);
    const local = readLocal(name);
    if (!packed || !local) {
      mismatched.push(`${name} (${packed ? "로컬에 없음" : "tarball에 없음"})`);
      continue;
    }
    let same = false;
    if (name === "package.json") {
      try {
        same = isDeepStrictEqual(JSON.parse(local.toString("utf8")), JSON.parse(packed.toString("utf8")));
      } catch {}
    } else {
      same = local.equals(packed);
    }
    if (!same) mismatched.push(name);
  }
  if (mismatched.length) {
    throw new Error(
      `레지스트리 tarball이 로컬 collector/와 다릅니다: ${mismatched.join(", ")}. ` +
        "잘못된 빌드이거나 다른 사람이 올린 패키지일 수 있어 서명하지 않습니다"
    );
  }
  return names;
}

function buildManifest({ version, dist, privateKey, keyId = DEFAULT_KEY_ID, releaseKeys = RELEASE_KEYS }) {
  const unsigned = { key_id: keyId, version, ...validateDist(version, dist) };
  const signature = crypto.sign(null, Buffer.from(releaseMessage(unsigned), "utf8"), privateKey).toString("base64");
  const manifest = { ...unsigned, signature };
  // 수집기가 서명 확인 전에 거는 형식 검사를 그대로 거친다 (서버 CHECK 제약도 같은 규칙이다)
  const formatError = manifestFormatError(manifest);
  if (formatError) throw new Error(`매니페스트가 수집기의 형식 검사를 통과하지 못합니다: ${formatError}`);
  // 수집기가 실제로 쓰는 검증 함수로 다시 확인한다, 다른 키로 서명했다면 여기서 멈춘다
  if (!verifyReleaseSignature(manifest, releaseKeys)) {
    throw new Error(`서명이 수집기에 내장된 공개키(key id ${keyId})로 검증되지 않습니다 (다른 서명 키인가요?)`);
  }
  return manifest;
}

function sqlLiteral(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

// 같은 버전을 다시 발행해도 값이 같으면 아무 행도 바뀌지 않는다 (Ed25519 서명은 결정적이다).
// published_at은 처음 발행 시각을 유지해 "최신 릴리스" 순서가 재실행으로 뒤바뀌지 않게 한다.
function upsertSQL(manifest) {
  const values = [manifest.version, manifest.key_id, manifest.integrity, manifest.tarball, manifest.signature];
  return [
    "insert into public.charge_collector_releases as r (version, key_id, integrity, tarball, signature)",
    `values (${values.map(sqlLiteral).join(", ")})`,
    "on conflict (version) do update",
    "  set key_id = excluded.key_id, integrity = excluded.integrity, tarball = excluded.tarball, signature = excluded.signature",
    "  where (r.key_id, r.integrity, r.tarball, r.signature)",
    "    is distinct from (excluded.key_id, excluded.integrity, excluded.tarball, excluded.signature);",
  ].join("\n");
}

async function runPsql(sql, { password }) {
  const conninfo = Object.entries(DATABASE).map(([key, value]) => `${key}=${value}`).join(" ");
  const { stdout } = await execFileAsync("psql", [
    "-X", "-v", "ON_ERROR_STOP=1",
    "-c", sql,
    "-c", "select version, key_id, tarball from public.charge_latest_collector();",
    conninfo,
  ], { encoding: "utf8", timeout: 60_000, env: { ...process.env, PGPASSWORD: password } });
  return stdout;
}

async function main(argv = process.argv.slice(2), {
  env = process.env,
  home = process.env.HOME ?? process.env.USERPROFILE,
  readFile = fs.readFileSync,
  viewDist = npmViewDist,
  viewVersions = npmViewVersions,
  fetchFn = globalThis.fetch,
  localDir = COLLECTOR_DIR,
  psql = runPsql,
  releaseKeys = RELEASE_KEYS,
  out = (text) => process.stdout.write(`${text}\n`),
  // 진행 안내는 stderr로 보내 --sql 출력(stdout)은 SQL만 남긴다
  log = (text) => process.stderr.write(`${text}\n`),
} = {}) {
  const { version, apply, keyId } = parseArgs(argv);
  // 수집기에 내장되지 않은 키 id로 서명하면 모든 수집기가 거부한다, 레지스트리에 닿기 전에 멈춘다
  if (!Object.hasOwn(releaseKeys, keyId)) {
    throw new Error(`key id ${keyId}는 수집기에 내장된 공개키 목록(updater.js RELEASE_KEYS)에 없습니다`);
  }
  // 로컬 목록만 보면 새 key id를 처음 넣은 바로 그 릴리스를 새 키로 서명하는 실수를 막지 못한다. 설치된 수집기는 아직 옛 목록만
  // 알아 모두 거부하고, 키 교체 릴리스가 어느 PC에도 닿지 않는다. 그래서 직전 릴리스에도 그 id가 내장돼 있어야 한다.
  const previous = await previousReleaseKeyIds(version, { viewVersions, viewDist, fetchFn });
  if (previous?.ids && !previous.ids.has(keyId)) {
    throw new Error(
      `key id ${keyId}는 직전 릴리스 ${previous.version}의 updater.js에 없어 설치된 수집기가 이 매니페스트를 거부합니다. ` +
        `직전 릴리스에 내장된 키(${[...previous.ids].join(", ") || "없음"})로 서명하세요`
    );
  }
  if (previous) log(`직전 릴리스 ${previous.version}: ${previous.ids ? `내장 key id ${[...previous.ids].join(", ")}` : "RELEASE_KEYS 없음 (자동 업데이트 이전 버전)"}`);
  const dist = await viewDist(version);
  const compared = await verifyRegistryTarball({ version, dist, localDir, fetchFn });
  log(`레지스트리 tarball이 로컬 collector/와 같습니다: ${compared.join(", ")}`);
  const privateKey = loadSigningKey({ env, home, readFile });
  const manifest = buildManifest({ version, dist, privateKey, keyId, releaseKeys });
  const sql = upsertSQL(manifest);
  if (!apply) {
    out(sql);
    return { manifest, sql, applied: false };
  }
  const password = String(readFile(path.join(home, ".charge", "supabase-db-password.txt"), "utf8")).trim();
  if (!password) throw new Error("DB 비밀번호 파일이 비어 있습니다");
  const result = await psql(sql, { password });
  out(String(result ?? "").trim());
  out(`적용 완료: ${PACKAGE_NAME}@${version}`);
  return { manifest, sql, applied: true };
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e?.message ?? e);
    process.exit(1);
  });
}

module.exports = { buildManifest, embeddedKeyIds, loadSigningKey, main, parseArgs, previousReleaseKeyIds, upsertSQL, verifyRegistryTarball };
