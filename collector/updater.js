// Charge 수집기 자동 업데이트, 서명된 릴리스 매니페스트를 확인하고 ~/.charge/app 파일을 교체한다.
// collect.js가 업로드를 마친 뒤 부른다. 설치 스크립트나 스케줄 정의는 다시 돌리지 않는다.
//
// 신뢰 사슬: 서버(charge_latest_collector)는 배포 채널일 뿐 신뢰 근거가 아니다.
// 매니페스트는 아래 공개키로 서명돼 있어야 하고, tarball 주소는 npm 레지스트리의 정해진 형식,
// 내용물은 서명에 들어간 sha512 무결성과 일치해야 한다. 셋 중 하나라도 어긋나면 아무것도 쓰지 않는다.
//
// 이 파일은 node: 내장 모듈만 불러온다. 교체가 끊겨 옛 파일과 새 파일이 섞인 앱 폴더에서도 collect.js가
// 이 파일을 불러 recoverInterruptedUpdate로 복구할 수 있어야 한다 (로컬 모듈을 require하면 그 전제가 깨진다).

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const zlib = require("node:zlib");
const { execFile } = require("node:child_process");
const { promisify } = require("node:util");

const execFileAsync = promisify(execFile);
const gunzipAsync = promisify(zlib.gunzip);

const PACKAGE_NAME = "charge-connect";
// 릴리스 서명 공개키 목록 (Ed25519, SPKI DER, base64). 매니페스트의 key_id로 고르고, 목록에 없는 id는 거부한다.
// 키를 바꿀 때는 새 id를 더한 수집기를 먼저 내보낸 뒤 새 키로 서명한다. 개인키는 저장소 밖에만 있다
// (~/.charge/release-signing-key.pem).
const RELEASE_KEYS = Object.freeze({
  k1: "MCowBQYDK2VwAyEAPUtk9Ynk8VdZNrEns+J9TsNmO5lUMRt7U0uslbeOp6U=",
});
// 서명 대상 문자열의 첫 줄. 형식을 바꾸면 v2로 올린다 (옛 수집기가 새 형식의 서명을 다른 뜻으로 읽지 않게).
const RELEASE_MESSAGE_PREFIX = "charge-connect-release/v1";

const CHECK_INTERVAL_MS = 12 * 3600_000;
// 같은 시각에 설치된 기기들이 한꺼번에 몰리지 않게 다음 확인 시각을 최대 60분 흩뜨린다
const CHECK_JITTER_MS = 60 * 60_000;
const MANIFEST_TIMEOUT_MS = 10_000;
const DOWNLOAD_TIMEOUT_MS = 30_000;
const MAX_TARBALL_BYTES = 2 * 1024 * 1024;
// 압축 해제 폭탄 방지, 정상 패키지는 수백 KB다
const MAX_UNPACKED_BYTES = 16 * 1024 * 1024;
const SYNTAX_CHECK_TIMEOUT_MS = 20_000;
const SELF_TEST_TIMEOUT_MS = 20_000;
// Windows에서 백신이나 검색 인덱서가 파일을 잠깐 잡고 있으면 rename이 실패한다, 되돌리기 전에 다시 시도한다
const RENAME_RETRIES = 5;
const RENAME_RETRY_DELAY_MS = 200;
// 설치 후 자체 점검에 실패해 다시 설치하지 않을 릴리스를 몇 개까지 기억할지
const MAX_FAILED_RELEASES = 20;
// 업데이트가 도중에 죽어 잠금 파일이 남아도 영원히 막히지 않게 한다
const LOCK_STALE_MS = 10 * 60_000;
// 파일 교체가 진행 중이라는 표시 (앱 폴더 안). collect.js가 맨 앞에서 같은 이름으로 확인한다.
const UPDATE_MARKER = ".update-in-progress.json";
const WIN = process.platform === "win32";

// 릴리스 버전은 x.y.z 숫자만 받는다. 프리릴리스나 빌드 메타데이터는 자동 업데이트 대상이 아니다.
function parseReleaseVersion(value) {
  const match = /^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})$/.exec(typeof value === "string" ? value : "");
  return match ? match.slice(1, 4).map(Number) : null;
}

function isNewerRelease(current, candidate) {
  const a = parseReleaseVersion(current);
  const b = parseReleaseVersion(candidate);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i += 1) {
    if (a[i] !== b[i]) return b[i] > a[i];
  }
  return false;
}

function releaseTarballURL(version) {
  return `https://registry.npmjs.org/${PACKAGE_NAME}/-/${PACKAGE_NAME}-${version}.tgz`;
}

// 서명 대상 문자열, 서버 테이블(charge_collector_releases)과 발행 스크립트가 같은 형식을 쓴다.
// key_id가 들어가 있어 한 키의 서명을 다른 키 id의 매니페스트로 옮겨 쓸 수 없다.
function releaseMessage({ key_id, version, integrity, tarball }) {
  return `${RELEASE_MESSAGE_PREFIX}\n${key_id}\n${version}\n${integrity}\n${tarball}`;
}

// 매니페스트 필드 형식 (D14). 서명을 확인하기 전에 모든 필드를 거른다. 서버 CHECK 제약, 발행 스크립트도 같은 규칙이다.
const MANIFEST_FORMATS = Object.freeze({
  key_id: /^[a-z0-9]{1,16}$/,
  version: /^\d{1,6}\.\d{1,6}\.\d{1,6}$/,
  integrity: /^sha512-[A-Za-z0-9+/]{86}==$/,
  // Ed25519 서명 64바이트의 base64
  signature: /^[A-Za-z0-9+/]{86}==$/,
});

// 반환: 형식이 맞으면 null, 아니면 이유. 이유에는 서버가 준 값을 넣지 않는다 (로그 줄 위조 방지).
function manifestFormatError(manifest) {
  if (!manifest || typeof manifest !== "object") return "매니페스트 형식이 올바르지 않습니다";
  for (const [field, pattern] of Object.entries(MANIFEST_FORMATS)) {
    if (typeof manifest[field] !== "string" || !pattern.test(manifest[field])) return `매니페스트 ${field} 형식 불일치`;
  }
  // 조각마다 0 또는 앞자리 0이 없는 숫자만 (npm 버전 규칙, 서버 제약과 같다)
  if (!parseReleaseVersion(manifest.version)) return "매니페스트 version 형식 불일치";
  if (manifest.tarball !== releaseTarballURL(manifest.version)) return "tarball 주소 형식 불일치";
  return null;
}

function publicKeyObject(publicKey) {
  if (publicKey instanceof crypto.KeyObject) return publicKey;
  return crypto.createPublicKey({ key: Buffer.from(publicKey, "base64"), format: "der", type: "spki" });
}

// releaseKeys는 { key_id: 공개키 } 목록이다 (테스트는 임시 키 목록을 넘긴다)
function verifyReleaseSignature(manifest, releaseKeys = RELEASE_KEYS) {
  try {
    if (manifestFormatError(manifest)) return false;
    if (!releaseKeys || !Object.hasOwn(releaseKeys, manifest.key_id)) return false;
    const key = publicKeyObject(releaseKeys[manifest.key_id]);
    if (key.asymmetricKeyType !== "ed25519") return false;
    const signature = Buffer.from(manifest.signature, "base64");
    if (signature.length !== 64) return false;
    return crypto.verify(null, Buffer.from(releaseMessage(manifest), "utf8"), key, signature);
  } catch {
    return false;
  }
}

function sha512Integrity(buffer) {
  return `sha512-${crypto.createHash("sha512").update(buffer).digest("base64")}`;
}

// 반환: { ok: true } 또는 { ok: false, reason, quiet }. quiet은 평상시 결과(이미 최신)라 로그를 남기지 않는다.
// 순서: 필드 형식, 알려진 키 id, 서명, 버전 비교.
function checkManifest(manifest, { currentVersion, releaseKeys = RELEASE_KEYS } = {}) {
  const formatError = manifestFormatError(manifest);
  if (formatError) return { ok: false, reason: formatError };
  // key_id는 위에서 [a-z0-9]{1,16}로 걸렀으므로 로그에 넣어도 된다
  if (!releaseKeys || !Object.hasOwn(releaseKeys, manifest.key_id)) {
    return { ok: false, reason: `알 수 없는 서명 키 id (${manifest.key_id})` };
  }
  if (!verifyReleaseSignature(manifest, releaseKeys)) return { ok: false, reason: "서명 검증 실패" };
  if (!parseReleaseVersion(currentVersion)) return { ok: false, reason: "현재 버전을 알 수 없습니다", quiet: true };
  if (!isNewerRelease(currentVersion, manifest.version)) return { ok: false, reason: "이미 최신입니다", quiet: true };
  return { ok: true };
}

// 로그로 내보내는 문자열에서 제어 문자(줄바꿈, 터미널 이스케이프, 글자 방향 전환)를 지우고 길이를 자른다
function cleanLogText(text, max = 500) {
  return String(text ?? "").replace(/[\p{Cc}\p{Bidi_Control}\p{Zl}\p{Zp}]/gu, " ").slice(0, max);
}

// 응답 본문을 상한까지만 읽는다. 상한을 넘으면 그 자리에서 끊고 실패한다.
async function readCapped(response, cap) {
  const declared = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(declared) && declared > cap) throw new Error(`다운로드 크기 상한 초과 (${declared} bytes)`);
  if (response.body && typeof response.body.getReader === "function") {
    const reader = response.body.getReader();
    const chunks = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > cap) {
        await reader.cancel().catch(() => {});
        throw new Error("다운로드 크기 상한 초과");
      }
      chunks.push(Buffer.from(value));
    }
    return Buffer.concat(chunks);
  }
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length > cap) throw new Error("다운로드 크기 상한 초과");
  return buffer;
}

function cString(bytes) {
  const end = bytes.indexOf(0);
  return bytes.subarray(0, end === -1 ? bytes.length : end).toString("utf8");
}

function parseOctal(bytes) {
  // base-256(최상위 비트) 인코딩은 8GB 넘는 항목에나 쓰인다, 여기서는 받을 이유가 없다
  if (bytes[0] & 0x80) return null;
  const text = bytes.toString("latin1").replace(/[\0 ]+$/g, "").replace(/^ +/, "");
  if (!/^[0-7]*$/.test(text)) return null;
  return text ? parseInt(text, 8) : 0;
}

// pax 확장 헤더: "길이 키=값\n" 레코드의 나열
function parsePax(data) {
  const out = {};
  let pos = 0;
  while (pos < data.length) {
    const space = data.indexOf(0x20, pos);
    if (space === -1) throw new Error("pax 헤더가 깨졌습니다");
    const length = Number(data.subarray(pos, space).toString("latin1"));
    if (!Number.isSafeInteger(length) || length <= space - pos || pos + length > data.length) {
      throw new Error("pax 헤더가 깨졌습니다");
    }
    const record = data.subarray(space + 1, pos + length).toString("utf8").replace(/\n$/, "");
    const eq = record.indexOf("=");
    if (eq > 0) out[record.slice(0, eq)] = record.slice(eq + 1);
    pos += length;
  }
  return out;
}

// 최소 tar 리더 (ustar, pax, GNU 긴 이름). 링크, 장치 파일 판정은 호출자가 한다.
function parseTar(buffer) {
  const entries = [];
  let offset = 0;
  let pax = null;
  let longName = null;
  let ended = false;
  while (offset + 512 <= buffer.length) {
    const header = buffer.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) {
      ended = true;
      break;
    }
    const stored = parseOctal(header.subarray(148, 156));
    let sum = 0;
    for (let i = 0; i < 512; i += 1) sum += i >= 148 && i < 156 ? 0x20 : header[i];
    if (stored === null || stored !== sum) throw new Error("tar 헤더 체크섬 불일치");
    const size = parseOctal(header.subarray(124, 136));
    if (size === null) throw new Error("tar 항목 크기를 읽을 수 없습니다");
    const type = header[156] === 0 ? "0" : String.fromCharCode(header[156]);
    let name = cString(header.subarray(0, 100));
    if (header.subarray(257, 263).toString("latin1") === "ustar\0") {
      const prefix = cString(header.subarray(345, 500));
      if (prefix) name = `${prefix}/${name}`;
    }
    const start = offset + 512;
    const end = start + size;
    if (end > buffer.length) throw new Error("tar가 중간에 잘렸습니다");
    const data = buffer.subarray(start, end);
    offset = start + Math.ceil(size / 512) * 512;

    if (type === "x") {
      pax = parsePax(data);
      continue;
    }
    if (type === "g") {
      // 전역 헤더가 경로를 바꾸면 이후 모든 항목 이름을 믿을 수 없다
      const global = parsePax(data);
      if ("path" in global || "linkpath" in global) throw new Error("전역 pax 경로 헤더는 허용하지 않습니다");
      continue;
    }
    if (type === "L") {
      longName = cString(data);
      continue;
    }
    entries.push({
      name: pax?.path ?? longName ?? name,
      type,
      linkname: pax?.linkpath ?? cString(header.subarray(157, 257)),
      data,
    });
    pax = null;
    longName = null;
  }
  if (!ended) throw new Error("tar 끝 표시가 없습니다");
  return entries;
}

// tgz에서 설치할 파일만 골라낸다. 구조 위반(링크, 경로 탈출, 하위 폴더)은 업데이트 전체를 거부한다.
// 허용 목록(새 package.json의 files)에 없는 최상위 일반 파일은 설치하지 않고 건너뛴다
// (npm이 README, LICENSE를 files와 무관하게 넣기 때문이다).
async function extractRelease(tgz, expectedVersion) {
  const tar = await gunzipAsync(tgz, { maxOutputLength: MAX_UNPACKED_BYTES });
  const regular = new Map();
  for (const entry of parseTar(tar)) {
    const name = entry.name;
    if (!name || name.includes("\\") || name.includes("\0")) throw new Error(`허용하지 않는 경로: ${JSON.stringify(name)}`);
    if (name.startsWith("/") || /^[A-Za-z]:/.test(name)) throw new Error(`절대 경로 항목: ${name}`);
    const segments = name.replace(/\/+$/, "").split("/");
    if (segments.includes("..") || segments.includes(".")) throw new Error(`상위 경로 항목: ${name}`);
    if (entry.type === "5") {
      if (segments.length === 1 && segments[0] === "package") continue;
      throw new Error(`하위 폴더 항목: ${name}`);
    }
    if (entry.type === "1" || entry.type === "2" || entry.type === "K") throw new Error(`링크 항목: ${name}`);
    if (entry.type !== "0") throw new Error(`일반 파일이 아닌 항목(${entry.type}): ${name}`);
    if (segments[0] !== "package") throw new Error(`package/ 밖의 항목: ${name}`);
    if (segments.length !== 2) throw new Error(`하위 폴더 항목: ${name}`);
    const file = segments[1];
    if (!/^[A-Za-z0-9._-]+$/.test(file)) throw new Error(`허용하지 않는 파일 이름: ${JSON.stringify(file)}`);
    if (regular.has(file)) throw new Error(`중복 항목: ${name}`);
    regular.set(file, entry.data);
  }

  const manifestFile = regular.get("package.json");
  if (!manifestFile) throw new Error("package.json이 없습니다");
  let pkg;
  try {
    pkg = JSON.parse(manifestFile.toString("utf8"));
  } catch {
    throw new Error("package.json을 해석할 수 없습니다");
  }
  if (pkg?.name !== PACKAGE_NAME) throw new Error(`패키지 이름 불일치 (${pkg?.name})`);
  if (pkg.version !== expectedVersion) throw new Error(`패키지 버전 불일치 (${pkg.version})`);
  if (!Array.isArray(pkg.files)) throw new Error("package.json에 files 목록이 없습니다");
  const allowed = new Set(pkg.files.filter((f) => typeof f === "string" && /^[A-Za-z0-9._-]+$/.test(f)));
  allowed.add("package.json");

  const files = new Map();
  for (const [file, data] of regular) {
    if (allowed.has(file)) files.set(file, data);
  }
  if (!files.has("collect.js")) throw new Error("collect.js가 없습니다");
  for (const [file, data] of files) {
    if (!file.endsWith(".json")) continue;
    try {
      JSON.parse(data.toString("utf8"));
    } catch {
      throw new Error(`${file}을 해석할 수 없습니다`);
    }
  }
  return { files, pkg };
}

async function nodeSyntaxCheck(file) {
  await execFileAsync(process.execPath, ["--check", file], { timeout: SYNTAX_CHECK_TIMEOUT_MS, windowsHide: true });
}

// 문법은 맞아도 불러오는 순간 죽는 릴리스(files에서 빠진 모듈, 이 Node에 없는 API)를 설치하면 다음 수집이
// 시작도 못 해 업데이트 확인까지 닿지 못하고, 모든 기기가 수동 복구를 기다리게 된다. 그래서 그 릴리스의
// collect.js를 --self-test로 별도 프로세스에서 실행한다 (D9). 자체 점검은 모든 런타임 모듈을 불러온 뒤
// "charge-connect self-test ok <버전>"을 찍고 끝나며, 네트워크, 키체인, 상태 파일에는 닿지 않는다.
// 교체 전에는 스테이징 폴더에서, 교체 후에는 앱 폴더에서 같은 점검을 돌린다. 결과 줄의 버전이 설치하려는
// 버전과 같아야 통과다. --self-test를 모르는 collect.js라면 수집을 시작할 수 있으므로 --dry-run(업로드와
// 실패 기록 없음)과 CHARGE_SKIP_UPDATE=1을 함께 주고, 결과 줄이 없거나 시간 초과면 실패로 본다.
// Windows 작업 스케줄러, systemd, cron은 collect.js에 --log를 붙여 부른다. 그 시작 코드(로그 파일, 오류 처리기)에서
// 죽는 릴리스도 걸러야 하므로 점검에도 버리는 로그 파일을 준다. 위치는 dir 옆(~/.charge, 스테이징을 만든 곳)이다.
async function nodeSelfTest(dir, expectedVersion) {
  const logDir = await fs.promises.mkdtemp(path.join(path.dirname(dir), "app.self-test-"));
  const logFile = path.join(logDir, "self-test.log");
  const readLog = () => fs.promises.readFile(logFile, "utf8").catch(() => "");
  try {
    let stdout;
    try {
      ({ stdout } = await execFileAsync(process.execPath, [path.join(dir, "collect.js"), "--self-test", "--dry-run", "--log", logFile], {
        cwd: dir,
        timeout: SELF_TEST_TIMEOUT_MS,
        windowsHide: true,
        env: { ...process.env, CHARGE_SKIP_UPDATE: "1" },
      }));
    } catch (e) {
      // --log를 받은 collect.js는 오류를 stderr가 아니라 로그 파일에 쓴다. 원인 줄을 고를 수 있게 줄머리([시각] 라벨: )를 떼어 붙인다
      const logged = (await readLog()).replace(/^\[[^\]\n]*\] [^:\n]*: /gm, "");
      if (logged.trim()) e.stderr = `${e.stderr ?? ""}\n${logged}`;
      throw e;
    }
    const expected = `${PACKAGE_NAME} self-test ok ${expectedVersion}`;
    // --log를 따르는 collect.js는 결과 줄도 로그 파일에 쓴다
    if (!`${stdout}\n${await readLog()}`.split(/\r?\n/).some((line) => line.trim() === expected)) {
      throw new Error(`자체 점검 결과 줄이 없습니다 (기대: ${expected})`);
    }
  } finally {
    await fs.promises.rm(logDir, { recursive: true, force: true }).catch(() => {});
  }
}

// 자체 점검 프로세스가 끝까지 돌고 0이 아닌 종료 코드를 냈는가 (execFile 오류의 code가 숫자, 시간 초과로 죽이지 않았고 신호도 없다).
// 문자열 code(ENOSPC 같은 입출력 오류), 시간 초과(killed), 신호 종료, 결과 줄 불일치는 여기에 들지 않는다.
function selfTestExitedWithError(e) {
  return Number.isSafeInteger(e?.code) && e.code !== 0 && !e.killed && !e.signal;
}

// 자식 프로세스 오류에서 원인 줄(SyntaxError, TypeError 등)을 고른다. stderr 첫 줄은 보통 파일 위치뿐이다.
function failureLine(e) {
  const lines = String(e?.stderr ?? "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines.find((line) => /^[A-Za-z]*Error\b/.test(line)) ?? lines[0] ?? String(e?.message ?? e).split("\n")[0];
}

// dir의 names 가운데 모든 .js를 node --check로 검사한다. 하나라도 실패하면 파일 이름과 원인 줄로 던진다.
// 스테이징(자동 업데이트)과 cli.js의 수동 설치가 교체 전에 같은 검사를 거친다.
async function checkSyntax(dir, names, { check = nodeSyntaxCheck } = {}) {
  for (const file of names) {
    if (!file.endsWith(".js")) continue;
    try {
      await check(path.join(dir, file));
    } catch (e) {
      throw new Error(`${file} 문법 검사 실패: ${failureLine(e)}`);
    }
  }
}

// 앱 폴더와 같은 볼륨(~/.charge 아래)에 새 폴더를 만들어 풀고, 모든 .js를 문법 검사한 뒤 자체 점검을 돌린다
async function stageRelease(files, chargeHome, { check = nodeSyntaxCheck, selfTest = nodeSelfTest, version } = {}) {
  const dir = await fs.promises.mkdtemp(path.join(chargeHome, "app.staging-"));
  try {
    await fs.promises.chmod(dir, 0o700).catch(() => {});
    for (const [file, data] of files) {
      await fs.promises.writeFile(path.join(dir, file), data, { mode: 0o600 });
    }
    await checkSyntax(dir, [...files.keys()], { check });
    try {
      await selfTest(dir, version);
    } catch (e) {
      throw new Error(`자체 점검 실패: ${failureLine(e)}`);
    }
    return dir;
  } catch (e) {
    await fs.promises.rm(dir, { recursive: true, force: true }).catch(() => {});
    throw e;
  }
}

async function fileMode(file) {
  try {
    return (await fs.promises.stat(file)).mode & 0o777;
  } catch {
    return null;
  }
}

// Windows에서는 백신이나 검색 인덱서가 파일을 잠깐 잡고 있으면 rename이 EPERM, EBUSY, EACCES로 실패한다.
// 대부분 곧 풀리므로 RENAME_RETRY_DELAY_MS 간격으로 RENAME_RETRIES번까지 다시 시도한 뒤에야 실패로 본다 (D14).
const RETRYABLE_RENAME_CODES = new Set(["EPERM", "EBUSY", "EACCES"]);
async function renameWithRetry(from, to, { retries = RENAME_RETRIES, delayMs = RENAME_RETRY_DELAY_MS } = {}) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await fs.promises.rename(from, to);
    } catch (e) {
      if (attempt >= retries || !RETRYABLE_RENAME_CODES.has(e?.code)) throw e;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}

// 파일 하나를 <file>.new로 쓰고 이름을 바꿔 덮는다. 열려 있는 파일을 지우지 않아 Windows에서도 안전하다.
async function replaceFile(source, target, name, { retryDelayMs = RENAME_RETRY_DELAY_MS } = {}) {
  const existing = await fileMode(target);
  let mode = existing ?? 0o600;
  if (!WIN && name.endsWith(".sh")) mode |= 0o700;
  const temporary = `${target}.new`;
  await fs.promises.copyFile(source, temporary);
  if (!WIN) await fs.promises.chmod(temporary, mode);
  await renameWithRetry(temporary, target, { delayMs: retryDelayMs });
}

async function currentRuntimeFiles(appDir) {
  try {
    const pkg = JSON.parse(await fs.promises.readFile(path.join(appDir, "package.json"), "utf8"));
    return Array.isArray(pkg.files) ? pkg.files.filter((f) => typeof f === "string" && /^[A-Za-z0-9._-]+$/.test(f)) : [];
  } catch {
    return [];
  }
}

// replaceFile의 동기판. collect.js가 다른 모듈을 불러오기 전에 되돌릴 때는 await할 수 없다.
function replaceFileSync(source, target, name) {
  let mode = 0o600;
  try {
    mode = fs.statSync(target).mode & 0o777;
  } catch {}
  if (!WIN && name.endsWith(".sh")) mode |= 0o700;
  const temporary = `${target}.new`;
  fs.copyFileSync(source, temporary);
  if (!WIN) fs.chmodSync(temporary, mode);
  fs.renameSync(temporary, target);
}

// 백업(app.prev)의 파일로 되돌리고 이번 업데이트가 새로 더한 파일은 지운다. names를 주지 않으면 백업 전체를
// 되돌린다. 실패한 파일이 있어도 끝까지 시도한 뒤 모아서 던진다 (섞인 상태를 조용히 남기지 않는다).
function restoreBackupSync({ appDir, backupDir, names = null, added = [] }) {
  const restore = names ?? fs.readdirSync(backupDir).filter((name) => {
    try {
      return /^[A-Za-z0-9._-]+$/.test(name) && fs.statSync(path.join(backupDir, name)).isFile();
    } catch {
      return false;
    }
  });
  const failures = [];
  for (const name of restore) {
    try {
      replaceFileSync(path.join(backupDir, name), path.join(appDir, name), name);
    } catch (e) {
      failures.push(`${name} (${e?.code ?? e?.message ?? e})`);
    }
  }
  for (const name of added) {
    if (typeof name !== "string" || !/^[A-Za-z0-9._-]+$/.test(name) || restore.includes(name)) continue;
    try {
      fs.rmSync(path.join(appDir, name), { force: true });
      // <파일>.new를 쓰다가(이름을 바꾸기 전에) 끊긴 교체의 흔적. 되돌린 파일의 .new는 replaceFileSync가 덮어 쓰고 옮기지만,
      // 더한 파일은 지우기만 하므로 여기서 같이 지운다
      fs.rmSync(`${path.join(appDir, name)}.new`, { force: true });
    } catch (e) {
      failures.push(`${name} (${e?.code ?? e?.message ?? e})`);
    }
  }
  if (failures.length) throw new Error(`app.prev에서 되돌리지 못한 파일: ${failures.join(", ")}`);
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

// 다른 프로세스의 업데이트가 지금 이 앱 폴더의 파일을 교체하는 중인가. 진행 표시에 적힌 프로세스가 살아 있고 표시를
// LOCK_STALE_MS 안에 썼을 때만 그렇다고 본다 (전원이 끊긴 뒤 같은 pid를 다른 프로세스가 받아도 그 시간이 지나면 되돌린다).
// pid나 시각이 없는 표시, 깨진 표시는 진행 중이 아니다 (되돌릴 대상이다).
function updateInProgress({ appDir, now = Date.now(), isAlive = processAlive }) {
  let info;
  try {
    info = JSON.parse(fs.readFileSync(path.join(appDir, UPDATE_MARKER), "utf8"));
  } catch {
    return false;
  }
  const pid = info?.pid;
  const startedAt = info?.startedAt;
  if (!Number.isSafeInteger(pid) || pid <= 0 || pid === process.pid || !Number.isFinite(startedAt)) return false;
  if (Math.abs(now - startedAt) > LOCK_STALE_MS) return false;
  return isAlive(pid) === true;
}

// 파일 교체 도중 끊긴 업데이트(전원 차단, 작업 시간 제한에 따른 강제 종료)를 app.prev로 되돌린다.
// 동기 함수다: collect.js가 다른 모듈을 불러오기 전에 불러, 옛 파일과 새 파일이 섞인 채 require가 엇갈려
// 죽기 전에 복구한다. 반환: 진행 표시가 없으면 false, 되돌렸으면 true. 되돌리지 못하면 표시를 남긴 채 던진다
// (다음 실행이 다시 시도하고, 그동안 installStaged는 백업을 덮지 않는다).
function recoverInterruptedUpdate({ appDir }) {
  const marker = path.join(appDir, UPDATE_MARKER);
  let info = null;
  try {
    info = JSON.parse(fs.readFileSync(marker, "utf8"));
  } catch (e) {
    if (e?.code === "ENOENT") return false;
  }
  const backupDir = typeof info?.backup === "string" && info.backup ? info.backup : path.join(path.dirname(appDir), "app.prev");
  restoreBackupSync({ appDir, backupDir, added: Array.isArray(info?.added) ? info.added : [] });
  fs.rmSync(marker, { force: true });
  return true;
}

// 현재 앱 파일을 app.prev로 백업한 뒤 새 파일로 교체한다. package.json은 맨 마지막에 바꿔서
// 도중에 실패해도 버전 표시는 옛 값으로 남고 다음 확인 창에 다시 시도하게 한다.
// 교체 직전에 진행 표시(UPDATE_MARKER: 백업 위치, 교체할 파일 목록, 새로 더하는 파일, from/to 버전, 이 설치의 id,
// pid, 시작 시각)를 남기고, 교체와 설치 후 자체 점검(verify)이 모두 끝나야 지운다. 프로세스가 도중에 죽으면 다음 실행의
// collect.js가 이 표시를 보고 다른 모듈을 불러오기 전에 app.prev로 되돌린다 (pid가 살아 있는 동안은 건드리지 않는다).
// verify가 실패하면 여기서 바로 app.prev로 되돌리고 code "SELF_TEST_FAILED" 오류를 던진다 (호출자가 그 릴리스를
// 다시 설치하지 않도록 기억한다). 교체 도중이나 점검 뒤에 표시가 이 설치의 것이 아니게 됐거나 앱 폴더 파일이 스테이징과
// 다르면, 다른 실행이 백업으로 되돌린 것이다. 그때도 되돌리되 릴리스 탓이 아니므로 SELF_TEST_FAILED로 던지지 않는다.
async function installStaged({
  stagingDir, names, appDir, backupDir,
  fromVersion = null, toVersion = null, verify = null, retryDelayMs = RENAME_RETRY_DELAY_MS,
}) {
  const marker = path.join(appDir, UPDATE_MARKER);
  // 되돌리지 못한 교체가 남아 있으면 앱 폴더가 섞여 있을 수 있다, 그 상태로 백업을 덮으면 돌아갈 곳이 사라진다
  if (fs.existsSync(marker)) {
    throw new Error("이전 업데이트가 교체 도중 끊긴 뒤 아직 되돌려지지 않았습니다 (npx charge-connect@latest update로 다시 설치하세요)");
  }
  await fs.promises.rm(backupDir, { recursive: true, force: true });
  await fs.promises.mkdir(backupDir, { recursive: true, mode: 0o700 });
  const backedUp = new Set();
  for (const name of new Set([...(await currentRuntimeFiles(appDir)), ...names, "package.json"])) {
    try {
      await fs.promises.copyFile(path.join(appDir, name), path.join(backupDir, name));
      backedUp.add(name);
    } catch (e) {
      if (e?.code !== "ENOENT") throw e;
    }
  }

  const ordered = [...names.filter((n) => n !== "package.json"), ...names.filter((n) => n === "package.json")];
  const markerInfo = {
    backup: backupDir,
    files: ordered,
    added: ordered.filter((name) => !backedUp.has(name)),
    from: fromVersion,
    to: toVersion,
    id: crypto.randomUUID(),
    pid: process.pid,
    startedAt: Date.now(),
  };
  if (!writeStateAtomic(marker, markerInfo)) {
    throw new Error("업데이트 진행 표시를 쓰지 못했습니다");
  }
  // 표시가 아직 이 설치의 것인가 (다른 실행이 되돌렸으면 지워졌다)
  const ownsMarker = () => {
    try {
      return JSON.parse(fs.readFileSync(marker, "utf8"))?.id === markerInfo.id;
    } catch {
      return false;
    }
  };
  // 자체 점검은 package.json의 버전만 찍으므로, 점검한 앱 폴더가 정말 스테이징한 파일인지 내용으로 확인한다
  const installedAsStaged = () => ordered.every((name) => {
    try {
      return fs.readFileSync(path.join(appDir, name)).equals(fs.readFileSync(path.join(stagingDir, name)));
    } catch {
      return false;
    }
  });
  const INTERRUPTED = "교체 도중 다른 실행이 앱 폴더를 app.prev로 되돌렸습니다 (다음 확인 창에 다시 설치합니다)";
  // 바꿨거나 바꾸던 파일. 이름을 바꾸다 실패한 파일도 넣는다: rename이 오류를 알렸어도 디스크에는 이미 반영됐을 수 있어
  // (입출력 오류, 되풀이한 뒤의 실패) 그 파일을 빼고 되돌리면 새 파일 하나가 옛 파일들 사이에 남는다.
  const replaced = [];
  // 바꾼 파일을 백업으로 되돌리고(새로 더한 파일은 지우고) 진행 표시를 지운다. 되돌리기마저 실패하면
  // 진행 표시를 남긴 채 합친 오류를 돌려준다, 다음 실행의 collect.js가 맨 앞에서 백업 전체로 다시 되돌린다.
  const rollBack = (reason) => {
    try {
      restoreBackupSync({
        appDir,
        backupDir,
        names: replaced.filter((name) => backedUp.has(name)),
        added: replaced.filter((name) => !backedUp.has(name)),
      });
    } catch (rollback) {
      return new Error(`${reason}; 되돌리기도 실패해 다음 실행에서 다시 시도합니다: ${rollback.message}`);
    }
    fs.rmSync(marker, { force: true });
    return null;
  };
  try {
    for (const name of ordered) {
      // 다른 실행이 표시를 지우고 되돌렸으면 남은 파일을 더 바꾸지 않는다 (계속 바꾸면 옛 파일과 새 파일이 섞인 폴더가 남는다)
      if (!ownsMarker()) throw new Error(INTERRUPTED);
      replaced.push(name);
      await replaceFile(path.join(stagingDir, name), path.join(appDir, name), name, { retryDelayMs });
    }
  } catch (e) {
    // 반쯤 바뀐 앱은 다음 수집에서 require가 엇갈려 죽을 수 있다, 바꾼 파일(바꾸던 파일까지)을 백업으로 되돌린다
    const current = replaced[replaced.length - 1];
    if (current) await fs.promises.rm(path.join(appDir, `${current}.new`), { force: true }).catch(() => {});
    throw rollBack(e?.message ?? e) ?? e;
  }
  const intact = () => ownsMarker() && installedAsStaged();
  if (verify) {
    // 앱 폴더에서도 같은 자체 점검을 돌린다. 스테이징에서는 통과했어도 앱 폴더의 환경(남아 있던 파일,
    // 권한, 경로)에서 죽는 릴리스를 그대로 두면 다음 수집부터 매번 실패한다.
    try {
      await verify();
    } catch (e) {
      const reason = `설치 후 자체 점검 실패: ${failureLine(e)}`;
      // 점검 도중 다른 실행이 되돌렸다면 점검은 옛 파일을 본 것이다, 실패한 릴리스로 기억하지 않는다
      if (!intact()) throw rollBack(`${INTERRUPTED}; ${reason}`) ?? new Error(`${INTERRUPTED}; ${reason}`);
      const failed = rollBack(reason) ?? new Error(`${reason} (app.prev로 되돌렸습니다)`);
      // 점검 프로세스가 스스로 0이 아닌 코드로 끝났을 때만 릴리스 탓으로 기억한다. 시간 초과, 신호로 죽은 경우, 점검용 임시 폴더를
      // 못 만든 입출력 오류는 이 PC의 사정(깨어난 직후의 느린 시작, 새 파일을 검사하는 백신)일 수 있다. 스테이징 점검은 방금
      // 통과했으므로 그때는 되돌리기만 하고 다음 확인 창에 다시 설치한다.
      if (selfTestExitedWithError(e)) failed.code = "SELF_TEST_FAILED";
      throw failed;
    }
  }
  // 옛 collect.js도 새 package.json의 버전을 찍으므로 점검 통과만으로는 새 파일이 설치됐다고 볼 수 없다
  if (!intact()) throw rollBack(INTERRUPTED) ?? new Error(INTERRUPTED);
  fs.rmSync(marker, { force: true });
}

function writeStateAtomic(file, data) {
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

// 잠금 파일의 지문: 수정 시각, 크기, 내용. 낡았다고 본 잠금이 넘겨받는 사이에 다른 실행의 새 잠금으로 바뀌었는지 이것으로
// 가린다 (다른 프로세스의 잠금은 내용(pid)이 다르고, 같은 프로세스가 다시 만든 잠금도 시각이 다르다). 내용을 읽을 수 없는
// 파일(권한)은 시각과 크기로만 본다. 반환: { key, content, mtimeMs }, 파일이 없으면 null. 그 밖의 stat 오류는 던진다.
function lockFingerprint(file) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch (e) {
    if (e?.code === "ENOENT") return null;
    throw e;
  }
  let content = null;
  try {
    content = fs.readFileSync(file, "utf8");
  } catch {}
  return { key: `${stat.mtimeMs}:${stat.size}:${content ?? ""}`, content, mtimeMs: stat.mtimeMs };
}

// 낡은 잠금(만든 프로세스가 죽었거나 너무 오래된 것)을 넘겨받는다. "지우고 다시 만들기"는 원자적이지 않다: 같은 잠금을 낡았다고
// 본 두 프로세스가 rm, 생성, rm, 생성으로 엇갈리면 뒤의 rm이 앞의 새 잠금을 지워 둘 다 잡는다. 그래서 넘겨받기 자체를
// <잠금>.takeover('wx')로 직렬화하고, 그 안에서 잠금을 다시 읽어 낡았다고 본 그 파일(지문 seen)일 때만 지운 뒤 create를 부른다.
// 그사이 바뀌었으면 다른 실행이 먼저 넘겨받아 새로 만든 것이므로 지우지 않는다. 넘겨받기는 몇 밀리초면 끝나므로 staleMs보다
// 오래된 표시는 그 사이에 죽은 프로세스의 흔적으로 보고 지운다 (그 지우기에는 같은 경쟁이 남지만, 넘겨받는 도중에 죽은 실행이
// 먼저 있어야 한다). 반환: 잡았으면 true, 다른 실행이 넘겨받는 중이거나 이미 넘겨받았으면 false, 표시나 잠금 파일을 만들거나
// 지울 수 없으면 그 오류. create는 잠금을 'wx'로 만드는 함수로, 만들었으면 true, 이미 있으면 false, 그 밖에는 오류를 돌려준다.
function takeOverStaleLock(file, seen, create, staleMs) {
  const takeover = `${file}.takeover`;
  const claim = () => {
    try {
      fs.writeFileSync(takeover, String(process.pid), { flag: "wx", mode: 0o600 });
      return true;
    } catch (e) {
      return e?.code === "EEXIST" ? false : e ?? new Error("takeover");
    }
  };
  let claimed = claim();
  if (claimed === false) {
    let abandoned = false;
    try {
      abandoned = Date.now() - fs.statSync(takeover).mtimeMs > staleMs;
    } catch (e) {
      abandoned = e?.code === "ENOENT";
    }
    if (!abandoned) return false;
    try {
      fs.rmSync(takeover, { force: true });
    } catch {}
    claimed = claim();
  }
  if (claimed !== true) return claimed;
  try {
    const current = lockFingerprint(file);
    if (current && current.key !== seen) return false;
    fs.rmSync(file, { force: true });
    return create();
  } catch (e) {
    return e ?? new Error("takeover");
  } finally {
    try {
      fs.rmSync(takeover, { force: true });
    } catch {}
  }
}

// ~/.charge/update.lock: 자동 업데이트(maybeAutoUpdate)와 수동 설치(cli.js의 installRuntime, `charge-connect update`와 페어링)가
// 앱 폴더를 동시에 바꾸지 않게 하는 잠금. 'wx'로 만들며 내용은 만든 프로세스의 pid다. 그 프로세스가 죽었거나 LOCK_STALE_MS가
// 지난 잠금은 낡은 것으로 보고 넘겨받는다 (takeOverStaleLock). 반환: 잡았으면 true, 살아 있는 다른 프로세스가 잡고 있거나
// 만들 수 없으면 false.
function acquireLock(file, now = Date.now(), { isAlive = processAlive } = {}) {
  const tryCreate = () => {
    try {
      fs.writeFileSync(file, String(process.pid), { flag: "wx", mode: 0o600 });
      return true;
    } catch (e) {
      if (e?.code !== "EEXIST") return false;
      return null;
    }
  };
  const first = tryCreate();
  if (first !== null) return first;
  try {
    const seen = lockFingerprint(file);
    // 그사이 풀렸으면 다시 만들어 본다
    if (!seen) return tryCreate() === true;
    const pid = Number.parseInt(seen.content ?? "", 10);
    const dead = Number.isSafeInteger(pid) && pid > 0 && !isAlive(pid);
    if (dead || now - seen.mtimeMs > LOCK_STALE_MS) {
      return takeOverStaleLock(file, seen.key, () => tryCreate() === true, LOCK_STALE_MS) === true;
    }
  } catch {}
  return false;
}

// 자체 점검(app.self-test-*)과 스테이징(app.staging-*) 폴더는 만든 실행이 끝나며 지우지만, 그 도중 강제 종료되면(Ctrl+C, 전원
// 차단, 작업 시간 제한) ~/.charge에 남아 쌓인다. 둘 다 update.lock을 잡은 실행만 만들므로, 잠금을 잡은 뒤에 부르면 남아 있는
// 폴더는 모두 죽은 실행의 것이다. 지우지 못한 폴더는 그대로 둔다 (다음에 다시 시도한다).
function sweepUpdateLeftovers(chargeHome) {
  let entries = [];
  try {
    entries = fs.readdirSync(chargeHome);
  } catch {
    return;
  }
  for (const name of entries) {
    if (!/^app\.(self-test|staging)-/.test(name)) continue;
    try {
      fs.rmSync(path.join(chargeHome, name), { recursive: true, force: true });
    } catch {}
  }
}

// 이 프로세스가 만든 잠금만 지운다 (낡았다고 판정한 다른 프로세스가 그사이 새로 만든 잠금을 지우지 않게)
function releaseLock(file) {
  try {
    if (fs.readFileSync(file, "utf8") === String(process.pid)) fs.rmSync(file, { force: true });
  } catch {}
}

async function fetchManifest(mode, fetchFn) {
  const res = await fetchFn(`${mode.url}/rest/v1/rpc/charge_latest_collector`, {
    method: "POST",
    headers: { apikey: mode.anon, Authorization: `Bearer ${mode.anon}`, "Content-Type": "application/json" },
    body: "{}",
    signal: AbortSignal.timeout(MANIFEST_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`매니페스트 조회 실패 (${res.status})`);
  const rows = await res.json();
  const row = Array.isArray(rows) ? rows[0] : rows;
  return row && typeof row === "object" ? row : null;
}

function sameDirectory(a, b) {
  const real = (p) => {
    try {
      return fs.realpathSync.native(p);
    } catch {
      return path.resolve(p);
    }
  };
  const left = real(a);
  const right = real(b);
  return WIN ? left.toLowerCase() === right.toLowerCase() : left === right;
}

// 업데이트 확인 상태: { lastCheck, nextCheck, failed: [{ version, integrity }] }. 깨진 항목은 버린다.
// failed는 설치 후 자체 점검에 실패해 되돌린 릴리스로, 같은 버전과 무결성이면 다시 설치하지 않는다.
function readUpdateState(file) {
  let saved = null;
  try {
    saved = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {}
  const failed = Array.isArray(saved?.failed)
    ? saved.failed
      .filter((entry) => typeof entry?.version === "string" && MANIFEST_FORMATS.version.test(entry.version)
        && typeof entry?.integrity === "string" && MANIFEST_FORMATS.integrity.test(entry.integrity))
      .map(({ version, integrity }) => ({ version, integrity }))
      .slice(-MAX_FAILED_RELEASES)
    : [];
  return { lastCheck: Number(saved?.lastCheck), nextCheck: Number(saved?.nextCheck), failed };
}

function rememberFailedRelease(file, release) {
  const state = readUpdateState(file);
  const failed = [...state.failed.filter((f) => f.version !== release.version || f.integrity !== release.integrity), release]
    .slice(-MAX_FAILED_RELEASES);
  const saved = { failed };
  if (Number.isFinite(state.lastCheck)) saved.lastCheck = state.lastCheck;
  if (Number.isFinite(state.nextCheck)) saved.nextCheck = state.nextCheck;
  return writeStateAtomic(file, saved);
}

// 반환: { updated, reason, version? }. 어떤 실패도 던지지 않는다 (수집 사이클을 깨면 안 된다).
async function maybeAutoUpdate({
  mode,
  appDir,
  chargeHome,
  currentVersion,
  dryRun = false,
  env = process.env,
  stateFile = appDir ? path.join(appDir, ".update-check.json") : null,
  fetchFn = globalThis.fetch,
  releaseKeys = RELEASE_KEYS,
  check = nodeSyntaxCheck,
  selfTest = nodeSelfTest,
  retryDelayMs = RENAME_RETRY_DELAY_MS,
  now = Date.now(),
  random = Math.random,
  log = console.log,
  logError = console.error,
} = {}) {
  if (dryRun) return { updated: false, reason: "dry-run" };
  if (!mode?.url || !mode?.anon) return { updated: false, reason: "unpaired" };
  if (env.CHARGE_SKIP_UPDATE === "1" || mode.auto_update === false) return { updated: false, reason: "disabled" };
  if (!appDir || !chargeHome || !stateFile) return { updated: false, reason: "no-app-dir" };
  // 저장소 체크아웃이나 npx 캐시에서 돌 때 그 파일을 덮으면 안 된다, 설치된 런타임만 스스로 갱신한다
  if (!sameDirectory(appDir, path.join(chargeHome, "app"))) return { updated: false, reason: "not-installed-runtime" };

  const state = readUpdateState(stateFile);
  const next = state.nextCheck;
  // 시계가 크게 뒤로 갔으면(다음 확인이 창 길이보다 먼 미래) 기록을 믿지 않는다
  if (Number.isFinite(next) && now < next && next - now <= CHECK_INTERVAL_MS + CHECK_JITTER_MS) {
    return { updated: false, reason: "not-due" };
  }
  // 네트워크보다 먼저 다음 확인 시각을 적는다, 실패해도 5분마다 재시도하지 않고 다음 창을 기다린다
  const nextCheck = now + CHECK_INTERVAL_MS + Math.floor(random() * CHECK_JITTER_MS);
  if (!writeStateAtomic(stateFile, { lastCheck: now, nextCheck, failed: state.failed })) {
    logError("자동 업데이트 확인 시각을 저장하지 못해 이번에는 건너뜁니다");
    return { updated: false, reason: "state-unwritable" };
  }

  let lockFile = null;
  let stagingDir = null;
  let manifest = null;
  try {
    manifest = await fetchManifest(mode, fetchFn);
    if (!manifest) return { updated: false, reason: "no-release" };
    const verdict = checkManifest(manifest, { currentVersion, releaseKeys });
    if (!verdict.ok) {
      if (!verdict.quiet) logError(`자동 업데이트 건너뜀: ${cleanLogText(verdict.reason)}`);
      return { updated: false, reason: verdict.reason };
    }
    if (state.failed.some((f) => f.version === manifest.version && f.integrity === manifest.integrity)) {
      logError(`자동 업데이트 건너뜀: ${manifest.version}은 이 PC에서 설치 후 자체 점검에 실패해 되돌린 릴리스입니다 (더 높은 버전을 기다립니다)`);
      return { updated: false, reason: "failed-release" };
    }
    lockFile = path.join(chargeHome, "update.lock");
    if (!acquireLock(lockFile, now)) {
      lockFile = null;
      return { updated: false, reason: "locked" };
    }
    // 잠금을 잡았으니 남아 있는 점검, 스테이징 폴더는 죽은 실행의 것이다
    sweepUpdateLeftovers(chargeHome);

    // 리다이렉트는 따라가지 않는다: 서명된 주소 그대로에서만 받는다
    const res = await fetchFn(manifest.tarball, {
      headers: { "User-Agent": `${PACKAGE_NAME}/${currentVersion}` },
      redirect: "error",
      signal: AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`다운로드 실패 (${res.status})`);
    // 본문 전체를 상한까지 받아 sha512를 확인한 뒤에야 압축 해제, tar 해석을 한다
    const tgz = await readCapped(res, MAX_TARBALL_BYTES);
    if (sha512Integrity(tgz) !== manifest.integrity) throw new Error("sha512 무결성 불일치");
    const { files } = await extractRelease(tgz, manifest.version);
    const version = manifest.version;
    stagingDir = await stageRelease(files, chargeHome, { check, selfTest, version });
    await installStaged({
      stagingDir,
      names: [...files.keys()],
      appDir,
      backupDir: path.join(chargeHome, "app.prev"),
      fromVersion: currentVersion,
      toVersion: version,
      verify: () => selfTest(appDir, version),
      retryDelayMs,
    });
    log(`${PACKAGE_NAME} ${currentVersion} -> ${version} 업데이트 완료 (다음 수집부터 적용)`);
    return { updated: true, reason: "updated", version };
  } catch (e) {
    if (e?.code === "SELF_TEST_FAILED" && manifest && !rememberFailedRelease(stateFile, { version: manifest.version, integrity: manifest.integrity })) {
      logError("자체 점검에 실패한 릴리스를 기록하지 못했습니다 (다음 확인 창에 다시 시도할 수 있습니다)");
    }
    logError(`자동 업데이트 실패: ${cleanLogText(e?.message ?? e)}`);
    return { updated: false, reason: e?.message ?? String(e) };
  } finally {
    if (stagingDir) await fs.promises.rm(stagingDir, { recursive: true, force: true }).catch(() => {});
    if (lockFile) releaseLock(lockFile);
  }
}

module.exports = {
  CHECK_INTERVAL_MS,
  CHECK_JITTER_MS,
  MANIFEST_FORMATS,
  MAX_TARBALL_BYTES,
  PACKAGE_NAME,
  RELEASE_KEYS,
  RELEASE_MESSAGE_PREFIX,
  RENAME_RETRIES,
  UPDATE_MARKER,
  acquireUpdateLock: acquireLock,
  checkManifest,
  checkSyntax,
  extractRelease,
  installStaged,
  isNewerRelease,
  lockFingerprint,
  manifestFormatError,
  maybeAutoUpdate,
  nodeSelfTest,
  nodeSyntaxCheck,
  parseReleaseVersion,
  parseTar,
  readCapped,
  readUpdateState,
  recoverInterruptedUpdate,
  releaseMessage,
  releaseTarballURL,
  releaseUpdateLock: releaseLock,
  sha512Integrity,
  stageRelease,
  sweepUpdateLeftovers,
  takeOverStaleLock,
  updateInProgress,
  verifyReleaseSignature,
};
