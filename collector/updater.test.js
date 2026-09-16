// 자동 업데이트 테스트, 실행: node --test updater.test.js
// 실제 레지스트리, 서버, 릴리스 개인키는 쓰지 않는다. 테스트마다 임시 키 쌍과 tgz를 직접 만든다.
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const zlib = require("node:zlib");

const U = require("./updater");

const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
const TEST_PUBLIC_KEY = publicKey.export({ type: "spki", format: "der" }).toString("base64");
const other = crypto.generateKeyPairSync("ed25519");
const OTHER_PUBLIC_KEY = other.publicKey.export({ type: "spki", format: "der" }).toString("base64");
// 테스트는 내장 운영 키 목록 대신 이 목록을 넘긴다 (key id k1 = 임시 키)
const TEST_KEYS = { k1: TEST_PUBLIC_KEY };
const NOW = Date.parse("2026-09-15T00:00:00Z");
const MODE = { url: "https://charge.example.invalid", anon: "anon-key", token: "device-token" };
const POSIX = process.platform !== "win32";

function tarHeader(name, size, { type = "0", linkname = "" } = {}) {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, "utf8");
  header.write("0000644\0", 100, 8, "latin1");
  header.write("0000000\0", 108, 8, "latin1");
  header.write("0000000\0", 116, 8, "latin1");
  header.write(`${size.toString(8).padStart(11, "0")}\0`, 124, 12, "latin1");
  header.write("00000000000\0", 136, 12, "latin1");
  header.fill(0x20, 148, 156);
  header.write(type, 156, 1, "latin1");
  header.write(linkname, 157, 100, "utf8");
  header.write("ustar\0", 257, 6, "latin1");
  header.write("00", 263, 2, "latin1");
  let sum = 0;
  for (const byte of header) sum += byte;
  header.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148, 8, "latin1");
  return header;
}

function paxRecord(key, value) {
  const body = ` ${key}=${value}\n`;
  let length = body.length + 1;
  while (String(length).length + body.length !== length) length = String(length).length + body.length;
  return `${length}${body}`;
}

function buildTgz(entries) {
  const parts = [];
  for (const entry of entries) {
    const data = Buffer.from(entry.data ?? "");
    parts.push(tarHeader(entry.name, data.length, entry), data, Buffer.alloc((512 - (data.length % 512)) % 512));
  }
  parts.push(Buffer.alloc(1024));
  return zlib.gzipSync(Buffer.concat(parts));
}

// 가짜 릴리스의 collect.js: 실제 collect.js처럼 --self-test면 런타임 모듈을 불러오고 버전 줄을 찍는다.
// before는 자체 점검보다 먼저 도는 코드다 (불러오는 순간 죽는 릴리스를 흉내 낼 때 쓴다).
function fakeCollect(version, before = "") {
  return [
    before,
    'if (process.argv.includes("--self-test")) {',
    '  require("./identity.js");',
    '  require("./updater.js");',
    `  console.log("charge-connect self-test ok ${version}");`,
    "}",
    `module.exports = "collect ${version}";`,
    "",
  ].join(String.fromCharCode(10));
}

function releaseEntries(version, { files = ["cli.js", "collect.js", "identity.js", "updater.js", "install.sh"], extra = [], collectBefore = "" } = {}) {
  return [
    { name: "package/package.json", data: JSON.stringify({ name: "charge-connect", version, files }) },
    { name: "package/collect.js", data: fakeCollect(version, collectBefore) },
    { name: "package/cli.js", data: `module.exports = "cli ${version}";\n` },
    { name: "package/identity.js", data: `module.exports = "identity ${version}";\n` },
    { name: "package/updater.js", data: `module.exports = "updater ${version}";\n` },
    { name: "package/install.sh", data: "#!/bin/bash\necho installed\n" },
    ...extra,
  ];
}

function sign(fields, key = privateKey) {
  return { ...fields, signature: crypto.sign(null, Buffer.from(U.releaseMessage(fields), "utf8"), key).toString("base64") };
}

function manifestFor(version, tgz, overrides = {}, key = privateKey) {
  return sign({
    key_id: "k1",
    version,
    integrity: U.sha512Integrity(tgz),
    tarball: U.releaseTarballURL(version),
    ...overrides,
  }, key);
}

// 설치된 0.2.0 앱 폴더와 그 옆의 설정/상태 파일
function setupInstall() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "charge-update-"));
  const chargeHome = path.join(root, ".charge");
  const appDir = path.join(chargeHome, "app");
  fs.mkdirSync(appDir, { recursive: true });
  const oldFiles = {
    "package.json": JSON.stringify({ name: "charge-connect", version: "0.2.0", files: ["cli.js", "collect.js", "identity.js", "updater.js", "install.sh"] }),
    "collect.js": "module.exports = 'collect old';\n",
    "cli.js": "module.exports = 'cli old';\n",
    "identity.js": "module.exports = 'identity old';\n",
    "updater.js": "module.exports = 'updater old';\n",
    "install.sh": "#!/bin/bash\necho old\n",
    ".collection-health.json": "{\"scope\":null,\"failures\":{}}",
    ".last-payload.json": "{\"daily\":[]}",
  };
  for (const [name, body] of Object.entries(oldFiles)) fs.writeFileSync(path.join(appDir, name), body);
  if (POSIX) fs.chmodSync(path.join(appDir, "install.sh"), 0o755);
  fs.writeFileSync(path.join(chargeHome, "config.json"), JSON.stringify(MODE));
  fs.writeFileSync(path.join(chargeHome, "device.json"), "{\"installation_id\":\"x\"}");
  const snapshot = () => Object.fromEntries(
    fs.readdirSync(appDir).filter((n) => !n.startsWith(".update-check")).sort()
      .map((n) => [n, fs.readFileSync(path.join(appDir, n), "utf8")])
  );
  return { root, chargeHome, appDir, oldFiles, snapshot, cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

function fakeServer({ manifest = null, tgz = null, manifestStatus = 200 } = {}) {
  const calls = [];
  const fetchFn = async (url, options = {}) => {
    const href = String(url);
    calls.push(href);
    if (href === `${MODE.url}/rest/v1/rpc/charge_latest_collector`) {
      assert.equal(options.method, "POST");
      assert.equal(options.headers.apikey, MODE.anon);
      return new Response(JSON.stringify(manifest ? [manifest] : []), { status: manifestStatus });
    }
    if (href.startsWith("https://registry.npmjs.org/")) {
      // 서명된 주소에서만 받는다, 리다이렉트를 따라가면 안 된다
      assert.equal(options.redirect, "error");
      return new Response(tgz, { status: 200 });
    }
    throw new Error(`unexpected request ${href}`);
  };
  return { calls, fetchFn };
}

async function runUpdate(install, server, options = {}) {
  const logs = [];
  const errors = [];
  const result = await U.maybeAutoUpdate({
    mode: MODE,
    appDir: install.appDir,
    chargeHome: install.chargeHome,
    currentVersion: "0.2.0",
    env: {},
    fetchFn: server.fetchFn,
    releaseKeys: TEST_KEYS,
    retryDelayMs: 1,
    now: NOW,
    random: () => 0,
    log: (m) => logs.push(m),
    logError: (m) => errors.push(m),
    ...options,
  });
  return { result, logs, errors };
}

function leftovers(chargeHome) {
  return fs.readdirSync(chargeHome).filter((n) => n.startsWith("app.staging-") || n.startsWith("app.self-test-") || n === "update.lock");
}

test("U01 embedded release keys are Ed25519 SPKI keys and versions compare strictly", () => {
  assert.deepEqual(Object.keys(U.RELEASE_KEYS), ["k1"]);
  assert.equal(U.RELEASE_KEYS.k1, "MCowBQYDK2VwAyEAPUtk9Ynk8VdZNrEns+J9TsNmO5lUMRt7U0uslbeOp6U=");
  assert.ok(Object.isFrozen(U.RELEASE_KEYS));
  for (const key of Object.values(U.RELEASE_KEYS)) {
    assert.equal(crypto.createPublicKey({ key: Buffer.from(key, "base64"), format: "der", type: "spki" }).asymmetricKeyType, "ed25519");
  }
  assert.equal(U.isNewerRelease("0.2.0", "0.2.1"), true);
  assert.equal(U.isNewerRelease("0.9.9", "0.10.0"), true);
  assert.equal(U.isNewerRelease("0.2.0", "0.2.0"), false);
  assert.equal(U.isNewerRelease("0.2.1", "0.2.0"), false);
  for (const bad of ["0.3.0-beta.1", "0.3", "v0.3.0", "0.03.0", "", null, "0.3.0 ", "1.0.0+build"]) {
    assert.equal(U.isNewerRelease("0.2.0", bad), false, `${bad}`);
  }
  assert.equal(U.releaseTarballURL("0.2.1"), "https://registry.npmjs.org/charge-connect/-/charge-connect-0.2.1.tgz");
  assert.equal(
    U.releaseMessage({ key_id: "k1", version: "1.2.3", integrity: "sha512-x", tarball: "t" }),
    ["charge-connect-release/v1", "k1", "1.2.3", "sha512-x", "t"].join(String.fromCharCode(10))
  );
});

test("U02 signed release installs end to end, backs up the old app and keeps config and state", async () => {
  const install = setupInstall();
  try {
    const tgz = buildTgz(releaseEntries("0.2.1", {
      extra: [
        { name: "package/README.md", data: "# not in files" },
        { name: "package/notlisted.js", data: "module.exports = 'nope';\n" },
      ],
    }));
    const server = fakeServer({ manifest: manifestFor("0.2.1", tgz), tgz });
    // 강제 종료된 지난 업데이트가 남긴 점검, 스테이징 폴더는 잠금을 잡은 뒤 치운다
    for (const name of ["app.self-test-dead", "app.staging-dead"]) fs.mkdirSync(path.join(install.chargeHome, name));
    const { result, logs, errors } = await runUpdate(install, server);
    assert.deepEqual(errors, []);
    assert.equal(result.updated, true);
    assert.deepEqual(logs, ["charge-connect 0.2.0 -> 0.2.1 업데이트 완료 (다음 수집부터 적용)"]);
    assert.deepEqual(server.calls, [
      `${MODE.url}/rest/v1/rpc/charge_latest_collector`,
      "https://registry.npmjs.org/charge-connect/-/charge-connect-0.2.1.tgz",
    ]);
    const app = install.appDir;
    assert.equal(fs.readFileSync(path.join(app, "collect.js"), "utf8"), fakeCollect("0.2.1"));
    assert.equal(JSON.parse(fs.readFileSync(path.join(app, "package.json"), "utf8")).version, "0.2.1");
    // 허용 목록 밖의 파일은 설치하지 않는다
    assert.equal(fs.existsSync(path.join(app, "README.md")), false);
    assert.equal(fs.existsSync(path.join(app, "notlisted.js")), false);
    // 상태 파일, 설정 파일은 그대로
    assert.equal(fs.readFileSync(path.join(app, ".collection-health.json"), "utf8"), install.oldFiles[".collection-health.json"]);
    assert.equal(fs.readFileSync(path.join(app, ".last-payload.json"), "utf8"), install.oldFiles[".last-payload.json"]);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(install.chargeHome, "config.json"), "utf8")), MODE);
    // 백업은 교체 전 파일
    const prev = path.join(install.chargeHome, "app.prev");
    assert.equal(fs.readFileSync(path.join(prev, "collect.js"), "utf8"), install.oldFiles["collect.js"]);
    assert.equal(JSON.parse(fs.readFileSync(path.join(prev, "package.json"), "utf8")).version, "0.2.0");
    if (POSIX) assert.ok(fs.statSync(path.join(app, "install.sh")).mode & 0o100, "install.sh keeps its executable bit");
    assert.equal(fs.readdirSync(app).some((n) => n.endsWith(".new")), false);
    assert.equal(fs.existsSync(path.join(app, U.UPDATE_MARKER)), false, "the in-progress marker is removed after a finished swap");
    assert.deepEqual(leftovers(install.chargeHome), []);

    // 12시간 창 안에서는 다시 묻지 않는다
    const again = await runUpdate(install, server, { now: NOW + 60_000 });
    assert.equal(again.result.reason, "not-due");
    assert.equal(server.calls.length, 2);
  } finally {
    install.cleanup();
  }
});

test("U03 bad signature, wrong tarball URL, older or equal versions never download", async () => {
  const cases = [];
  const tgz = buildTgz(releaseEntries("0.2.1"));
  cases.push(["signed by another key", manifestFor("0.2.1", tgz, {}, other.privateKey), /서명/]);
  const tampered = manifestFor("0.2.1", tgz);
  cases.push(["field changed after signing", { ...tampered, version: "0.2.2", tarball: U.releaseTarballURL("0.2.2") }, /서명/]);
  cases.push(["garbage signature", { ...tampered, signature: "not base64!" }, /signature 형식/]);
  cases.push(["wrong tarball host", manifestFor("0.2.1", tgz, { tarball: "https://evil.example/charge-connect-0.2.1.tgz" }), /tarball/]);
  cases.push(["tarball of another version", manifestFor("0.2.1", tgz, { tarball: U.releaseTarballURL("0.2.0") }), /tarball/]);
  cases.push(["prerelease", manifestFor("0.3.0-beta.1", tgz, { tarball: U.releaseTarballURL("0.3.0-beta.1") }), /version 형식/]);
  // D14: 서명을 확인하기 전에 모든 필드를 엄격한 형식으로 거른다
  const good = manifestFor("0.2.1", tgz);
  const { key_id: _dropped, ...withoutKeyId } = good;
  cases.push(["unknown key id", manifestFor("0.2.1", tgz, { key_id: "k2" }), /알 수 없는 서명 키 id \(k2\)/]);
  cases.push(["missing key id", withoutKeyId, /key_id 형식/]);
  cases.push(["uppercase key id", manifestFor("0.2.1", tgz, { key_id: "K1" }), /key_id 형식/]);
  cases.push(["key id too long", manifestFor("0.2.1", tgz, { key_id: "k".repeat(17) }), /key_id 형식/]);
  cases.push(["signature of 63 bytes", { ...good, signature: crypto.randomBytes(63).toString("base64") }, /signature 형식/]);
  cases.push(["signature with trailing data", { ...good, signature: `${good.signature}AA` }, /signature 형식/]);
  cases.push(["integrity not sha512", { ...good, integrity: "sha1-abc" }, /integrity 형식/]);
  cases.push(["integrity with trailing space", { ...good, integrity: `${good.integrity} ` }, /integrity 형식/]);
  cases.push(["leading zero version", manifestFor("0.02.1", tgz, { tarball: U.releaseTarballURL("0.02.1") }), /version 형식/]);
  cases.push(["seven digit version", manifestFor("1234567.0.0", tgz, { tarball: U.releaseTarballURL("1234567.0.0") }), /version 형식/]);
  cases.push(["numeric version", { ...good, version: 21 }, /version 형식/]);
  cases.push(["equal version", manifestFor("0.2.0", tgz, { tarball: U.releaseTarballURL("0.2.0") }), null]);
  cases.push(["older version", manifestFor("0.1.9", tgz, { tarball: U.releaseTarballURL("0.1.9") }), null]);
  for (const [label, manifest, errorPattern] of cases) {
    const install = setupInstall();
    try {
      const before = install.snapshot();
      const server = fakeServer({ manifest, tgz });
      const { result, errors } = await runUpdate(install, server);
      assert.equal(result.updated, false, label);
      assert.deepEqual(server.calls, [`${MODE.url}/rest/v1/rpc/charge_latest_collector`], label);
      assert.deepEqual(install.snapshot(), before, label);
      if (errorPattern) {
        assert.equal(errors.length, 1, label);
        assert.match(errors[0], errorPattern, label);
      } else {
        assert.deepEqual(errors, [], `${label} is the normal steady state and stays quiet`);
      }
    } finally {
      install.cleanup();
    }
  }
});

test("U04 integrity mismatch and oversized downloads leave the app untouched", async () => {
  const tgz = buildTgz(releaseEntries("0.2.1"));
  const otherTgz = buildTgz(releaseEntries("0.2.1", { extra: [{ name: "package/README.md", data: "different" }] }));
  const big = crypto.randomBytes(U.MAX_TARBALL_BYTES + 1024);
  for (const [label, manifest, served, pattern] of [
    ["integrity mismatch", manifestFor("0.2.1", otherTgz), tgz, /무결성/],
    ["over 2 MB", manifestFor("0.2.1", big), big, /상한/],
  ]) {
    const install = setupInstall();
    try {
      const before = install.snapshot();
      const { result, errors } = await runUpdate(install, fakeServer({ manifest, tgz: served }));
      assert.equal(result.updated, false, label);
      assert.equal(errors.length, 1, label);
      assert.match(errors[0], pattern, label);
      assert.deepEqual(install.snapshot(), before, label);
      assert.equal(fs.existsSync(path.join(install.chargeHome, "app.prev")), false, label);
      assert.deepEqual(leftovers(install.chargeHome), [], label);
    } finally {
      install.cleanup();
    }
  }
});

test("U05 hostile tar entries reject the whole update", async () => {
  const pax = (key, value) => ({ name: "package/PaxHeader", type: "x", data: paxRecord(key, value) });
  const cases = [
    ["dot-dot traversal", [{ name: "package/../evil.js", data: "x" }], /상위 경로/],
    ["pax path traversal", [pax("path", "package/../../evil.js"), { name: "package/innocent.js", data: "x" }], /상위 경로/],
    ["absolute path", [{ name: "/tmp/evil.js", data: "x" }], /절대 경로/],
    ["symlink", [{ name: "package/cloud.json", type: "2", linkname: "/etc/passwd" }], /링크/],
    ["hard link", [{ name: "package/cloud.json", type: "1", linkname: "package/collect.js" }], /링크/],
    ["nested directory file", [{ name: "package/lib/collect.js", data: "x" }], /하위 폴더/],
    ["nested directory entry", [{ name: "package/lib/", type: "5" }], /하위 폴더/],
    ["outside package root", [{ name: "other/collect.js", data: "x" }], /package\//],
    ["duplicate entry", [{ name: "package/collect.js", data: "again" }], /중복/],
  ];
  for (const [label, extra, pattern] of cases) {
    const install = setupInstall();
    try {
      const before = install.snapshot();
      const tgz = buildTgz(releaseEntries("0.2.1", { extra }));
      const { result, errors } = await runUpdate(install, fakeServer({ manifest: manifestFor("0.2.1", tgz), tgz }));
      assert.equal(result.updated, false, label);
      assert.equal(errors.length, 1, label);
      assert.match(errors[0], pattern, label);
      assert.deepEqual(install.snapshot(), before, label);
      assert.equal(fs.existsSync(path.join(install.root, "evil.js")), false, label);
      assert.equal(fs.existsSync(path.join(install.chargeHome, "evil.js")), false, label);
      assert.deepEqual(leftovers(install.chargeHome), [], label);
    } finally {
      install.cleanup();
    }
  }

  // 패키지 정체성 검사: 이름, 버전, collect.js 존재
  for (const [label, entries, pattern] of [
    ["wrong name", [{ name: "package/package.json", data: JSON.stringify({ name: "evil", version: "0.2.1", files: ["collect.js"] }) }, { name: "package/collect.js", data: "1;" }], /이름/],
    ["wrong version", [{ name: "package/package.json", data: JSON.stringify({ name: "charge-connect", version: "0.2.2", files: ["collect.js"] }) }, { name: "package/collect.js", data: "1;" }], /버전/],
    ["no collect.js", [{ name: "package/package.json", data: JSON.stringify({ name: "charge-connect", version: "0.2.1", files: ["cli.js"] }) }, { name: "package/cli.js", data: "1;" }], /collect\.js/],
  ]) {
    await assert.rejects(U.extractRelease(buildTgz(entries), "0.2.1"), pattern, label);
  }
});

test("U06 a file failing node --check leaves the old app untouched", async () => {
  const install = setupInstall();
  try {
    const before = install.snapshot();
    const entries = releaseEntries("0.2.1").map((e) => (e.name === "package/collect.js" ? { ...e, data: "module.exports = ;\n" } : e));
    const tgz = buildTgz(entries);
    const { result, errors } = await runUpdate(install, fakeServer({ manifest: manifestFor("0.2.1", tgz), tgz }));
    assert.equal(result.updated, false);
    assert.equal(errors.length, 1);
    assert.match(errors[0], /collect\.js 문법 검사 실패/);
    assert.deepEqual(install.snapshot(), before);
    assert.equal(fs.existsSync(path.join(install.chargeHome, "app.prev")), false);
    assert.deepEqual(leftovers(install.chargeHome), []);
  } finally {
    install.cleanup();
  }
});

test("U07 update runs only when paired, enabled, due and inside the installed runtime", async () => {
  const install = setupInstall();
  try {
    const server = fakeServer({ manifest: null });
    for (const [label, options] of [
      ["dry-run", { dryRun: true }],
      ["unpaired", { mode: null }],
      ["env opt-out", { env: { CHARGE_SKIP_UPDATE: "1" } }],
      ["config opt-out", { mode: { ...MODE, auto_update: false } }],
      ["repo checkout", { appDir: install.root }],
    ]) {
      const { result } = await runUpdate(install, server, options);
      assert.equal(result.updated, false, label);
    }
    assert.deepEqual(server.calls, [], "no guard may reach the network");
    assert.equal(fs.existsSync(path.join(install.appDir, ".update-check.json")), false);

    // 확인 시각은 네트워크보다 먼저 저장하고, 실패는 한 줄만 남긴 채 다음 창을 기다린다
    const failing = fakeServer({ manifestStatus: 500 });
    const first = await runUpdate(install, failing, { random: () => 0.5 });
    assert.equal(first.errors.length, 1);
    assert.match(first.errors[0], /매니페스트/);
    const state = JSON.parse(fs.readFileSync(path.join(install.appDir, ".update-check.json"), "utf8"));
    assert.equal(state.nextCheck, NOW + U.CHECK_INTERVAL_MS + U.CHECK_JITTER_MS / 2);
    if (POSIX) assert.equal(fs.statSync(path.join(install.appDir, ".update-check.json")).mode & 0o777, 0o600);
    const soon = await runUpdate(install, failing, { now: NOW + U.CHECK_INTERVAL_MS });
    assert.equal(soon.result.reason, "not-due");
    const due = await runUpdate(install, failing, { now: state.nextCheck });
    assert.equal(due.errors.length, 1);
    assert.equal(failing.calls.length, 2);

    // 깨진 상태 파일, 시계가 크게 뒤로 간 기록은 믿지 않고 바로 확인한다
    for (const corrupt of ["garbage", JSON.stringify({ nextCheck: NOW + 30 * 86400_000 })]) {
      fs.writeFileSync(path.join(install.appDir, ".update-check.json"), corrupt);
      const empty = fakeServer({ manifest: null });
      const r = await runUpdate(install, empty);
      assert.equal(r.result.reason, "no-release");
      assert.equal(empty.calls.length, 1);
    }
  } finally {
    install.cleanup();
  }
});

test("U08 tar reader handles pax long names and rejects corrupt archives", () => {
  const long = `package/${"a".repeat(120)}.js`;
  const tar = zlib.gunzipSync(buildTgz([
    { name: "package/PaxHeader", type: "x", data: paxRecord("path", long) },
    { name: "package/short", data: "long body" },
  ]));
  const entries = U.parseTar(tar);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].name, long);
  assert.equal(entries[0].data.toString(), "long body");

  const broken = Buffer.from(tar);
  broken[0] ^= 0xff; // 체크섬 불일치
  assert.throws(() => U.parseTar(broken), /체크섬/);
  assert.throws(() => U.parseTar(tar.subarray(0, 700)), /잘렸|끝 표시/);
});

test("U09 a signed release whose self-test fails in the staging directory is never installed", async () => {
  const replace = (file, data) => (entry) => (entry.name === `package/${file}` ? { ...entry, data } : entry);
  for (const [label, mutate, pattern] of [
    // Node 18처럼 API가 없는 환경, files에서 빠진 모듈, updater 자체의 결함
    ["missing API at load", replace("collect.js", 'require("node:fs").definitelyMissingApi();'), /자체 점검 실패: TypeError/],
    ["module left out of files", replace("collect.js", 'require("./helper.js");'), /자체 점검 실패: Error: Cannot find module/],
    ["updater throws at load", replace("updater.js", 'throw new Error("broken updater");'), /자체 점검 실패: Error: broken updater/],
    // --self-test를 모르는 collect.js, 다른 버전을 찍는 collect.js는 결과 줄이 맞지 않는다
    ["collect.js without --self-test", replace("collect.js", "module.exports = 1;"), /자체 점검 실패: .*결과 줄이 없습니다/],
    ["self-test reports another version", replace("collect.js", fakeCollect("0.2.0")), /자체 점검 실패: .*결과 줄이 없습니다/],
  ]) {
    const install = setupInstall();
    try {
      const before = install.snapshot();
      const tgz = buildTgz(releaseEntries("0.2.1").map(mutate));
      const { result, errors } = await runUpdate(install, fakeServer({ manifest: manifestFor("0.2.1", tgz), tgz }));
      assert.equal(result.updated, false, label);
      assert.equal(errors.length, 1, label);
      assert.match(errors[0], pattern, label);
      assert.deepEqual(install.snapshot(), before, label);
      assert.equal(fs.existsSync(path.join(install.chargeHome, "app.prev")), false, label);
      assert.deepEqual(leftovers(install.chargeHome), [], label);
    } finally {
      install.cleanup();
    }
  }
});

// 실제 런타임(collect.js, identity.js, updater.js, cli.js, package.json)을 복사한 설치. 자체 점검은 cli.js까지 불러온다.
function setupRealRuntime(prefix) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const chargeHome = path.join(root, ".charge");
  const appDir = path.join(chargeHome, "app");
  fs.mkdirSync(appDir, { recursive: true });
  const runtime = ["collect.js", "identity.js", "updater.js", "cli.js", "package.json"];
  for (const name of runtime) fs.copyFileSync(path.join(__dirname, name), path.join(appDir, name));
  const original = Object.fromEntries(runtime.map((name) => [name, fs.readFileSync(path.join(appDir, name), "utf8")]));
  const env = { ...process.env, HOME: root, USERPROFILE: root, CHARGE_HOME: chargeHome };
  for (const key of ["CHARGE_TOKEN", "CHARGE_URL", "CHARGE_ANON", "CHARGE_SKIP_UPDATE", "CHARGE_INSTALL_ID"]) delete env[key];
  return { root, chargeHome, appDir, runtime, original, env, cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

// 수집을 시작하기 전에 main이 예외로 끝나게 하는 preload. config.json에 crash_for_test를 넣으면 설정의
// claude_environment를 읽는 순간 던진다. 네트워크는 모두 가짜이고, 요청 주소만 파일에 남긴다.
function crashBeforeUploadPreload(root) {
  const callsFile = path.join(root, "calls.txt");
  const preload = path.join(root, "preload.js");
  fs.writeFileSync(preload, [
    'const fs = require("node:fs");',
    "const parse = JSON.parse;",
    "JSON.parse = function (...args) {",
    "  const value = parse.apply(this, args);",
    "  if (value && value.crash_for_test === true) {",
    '    Object.defineProperty(value, "claude_environment", { get() { throw new Error("crash before upload"); } });',
    "  }",
    "  return value;",
    "};",
    "globalThis.fetch = async (url) => {",
    `  fs.appendFileSync(${JSON.stringify(callsFile)}, String(url) + String.fromCharCode(10));`,
    '  return new Response("[]", { status: 200, headers: { "content-type": "application/json" } });',
    "};",
  ].join(String.fromCharCode(10)));
  return { preload, callsFile };
}

test("U10 an update killed mid-swap is rolled back by the next run, which re-runs itself if collect.js was already new", async () => {
  const { spawnSync } = require("node:child_process");
  for (const [label, names] of [
    // 끊긴 시점에 collect.js는 아직 옛 파일: 되돌린 뒤 같은 프로세스로 계속한다
    ["collect.js not replaced yet", ["identity.js", "helper.js", "collect.js", "package.json"]],
    // collect.js가 이미 새 파일: 되돌린 옛 collect.js를 같은 인자로 다시 실행한다
    ["collect.js already replaced", ["collect.js", "identity.js", "helper.js", "package.json"]],
  ]) {
    const install = setupRealRuntime("charge-update-kill-");
    try {
      const { root, appDir, chargeHome, original } = install;
      const backupDir = path.join(chargeHome, "app.prev");
      const stagingDir = path.join(chargeHome, "app.staging-test");
      fs.mkdirSync(stagingDir);
      // 새 identity.js는 옛 collect.js와 섞이면 불러오는 순간 죽는다, 새 파일(helper.js)도 하나 더한다
      fs.writeFileSync(path.join(stagingDir, "identity.js"), 'throw new Error("mixed release");');
      fs.writeFileSync(path.join(stagingDir, "helper.js"), "module.exports = 1;");
      // 새 collect.js는 main에 닿으면 흔적을 남긴다. 되돌린 뒤에는 이 코드가 아니라 옛 collect.js가 돌아야 한다.
      const entry = "} else if (require.main === module) {";
      assert.ok(original["collect.js"].includes(entry));
      fs.writeFileSync(path.join(stagingDir, "collect.js"), original["collect.js"].replace(entry, `${entry} console.error("NEW COLLECT MAIN");`));
      fs.writeFileSync(path.join(stagingDir, "package.json"), JSON.stringify({ name: "charge-connect", version: "0.2.1", files: ["collect.js", "identity.js", "helper.js"] }));
      const args = { stagingDir, names, appDir, backupDir, fromVersion: "0.2.0", toVersion: "0.2.1" };

      // 자식 프로세스가 교체하다가 두 번째 rename 직후 강제 종료된다 (전원 차단, 작업 시간 제한과 같은 상황)
      const killed = spawnSync(process.execPath, ["-e", [
        'const fs = require("node:fs");',
        "const rename = fs.promises.rename;",
        "let count = 0;",
        'fs.promises.rename = async (from, to) => { await rename(from, to); if (++count === 2) process.kill(process.pid, "SIGKILL"); };',
        `require(${JSON.stringify(path.join(__dirname, "updater.js"))}).installStaged(${JSON.stringify(args)});`,
      ].join(String.fromCharCode(10))], { encoding: "utf8", timeout: 30_000 });
      const { id, pid, startedAt, ...marker } = JSON.parse(fs.readFileSync(path.join(appDir, U.UPDATE_MARKER), "utf8"));
      assert.deepEqual(marker, { backup: backupDir, files: names, added: ["helper.js"], from: "0.2.0", to: "0.2.1" }, killed.stderr);
      // 표시에는 이 설치의 id와 교체하던 프로세스가 적힌다. 그 프로세스가 죽었으니 진행 중이 아니다
      assert.match(id, /^[0-9a-f-]{36}$/);
      assert.equal(pid, killed.pid);
      assert.ok(Math.abs(Date.now() - startedAt) < 60_000);
      assert.equal(U.updateInProgress({ appDir }), false);
      assert.equal(fs.readFileSync(path.join(appDir, names[1]), "utf8"), fs.readFileSync(path.join(stagingDir, names[1]), "utf8"), label);
      assert.equal(fs.readFileSync(path.join(appDir, "package.json"), "utf8"), original["package.json"]);

      // 되돌리기 전에는 새 업데이트가 백업을 덮지 못한다
      await assert.rejects(U.installStaged(args), /되돌려지지 않았습니다/);
      assert.equal(fs.readFileSync(path.join(backupDir, "identity.js"), "utf8"), original["identity.js"]);

      // 다음 실행: collect.js가 다른 모듈을 불러오기 전에 되돌린다. 수집 전에 main이 예외로 끝나게 한다.
      fs.writeFileSync(path.join(chargeHome, "config.json"), JSON.stringify({ ...MODE, crash_for_test: true }));
      const { preload } = crashBeforeUploadPreload(root);
      const next = spawnSync(process.execPath, ["-r", preload, path.join(appDir, "collect.js")], { encoding: "utf8", env: install.env, timeout: 30_000 });
      assert.equal(next.status, 1, `${label}: ${next.stderr}`);
      assert.equal(next.stderr.includes("mixed release"), false, next.stderr);
      assert.equal(next.stderr.includes("NEW COLLECT MAIN"), false, `${label}: the new collect.js must not run its main`);
      assert.match(next.stderr, /교체 도중 끊긴 자동 업데이트를 app\.prev 백업으로 되돌렸습니다/);
      assert.equal(next.stderr.split("crash before upload").length - 1, 1, `${label}: the collection starts exactly once`);
      for (const name of install.runtime) assert.equal(fs.readFileSync(path.join(appDir, name), "utf8"), original[name], name);
      assert.equal(fs.existsSync(path.join(appDir, "helper.js")), false, "files added by the interrupted update are removed");
      assert.equal(fs.existsSync(path.join(appDir, U.UPDATE_MARKER)), false);
      assert.equal(fs.readdirSync(appDir).some((n) => n.endsWith(".new")), false);
      assert.equal(U.recoverInterruptedUpdate({ appDir }), false, "nothing left to recover");
    } finally {
      install.cleanup();
    }
  }
});

test("U11 a swap still blocked after the retries rolls back in place, and a failed rollback keeps the marker for the next run", async () => {
  const install = setupInstall();
  const realRename = fs.promises.rename;
  const realRenameSync = fs.renameSync;
  try {
    const before = install.snapshot();
    const backupDir = path.join(install.chargeHome, "app.prev");
    const stagingDir = fs.mkdtempSync(path.join(install.root, "staging-"));
    for (const name of ["cli.js", "collect.js", "new-module.js"]) fs.writeFileSync(path.join(stagingDir, name), `module.exports = "${name} 0.2.1";`);
    fs.writeFileSync(path.join(stagingDir, "package.json"), JSON.stringify({ name: "charge-connect", version: "0.2.1", files: ["cli.js", "collect.js", "new-module.js"] }));
    const args = { stagingDir, names: ["cli.js", "new-module.js", "collect.js", "package.json"], appDir: install.appDir, backupDir, retryDelayMs: 1 };
    const busy = () => Object.assign(new Error("resource busy"), { code: "EBUSY" });
    // 세 번째로 바꾸는 파일(collect.js)의 rename은 다시 시도해도 계속 막힌다
    let blockedAttempts = 0;
    const blockThirdFile = () => {
      let count = 0;
      let blocked = null;
      blockedAttempts = 0;
      fs.promises.rename = async (from, to) => {
        count += 1;
        if (count === 3) blocked = to;
        if (blocked !== null && to === blocked) {
          blockedAttempts += 1;
          throw busy();
        }
        return realRename(from, to);
      };
    };

    // 1. 다시 시도해도 막히면 바꾼 두 파일을 되돌리고(새 파일은 지우고) 표시도 지운다
    blockThirdFile();
    await assert.rejects(U.installStaged(args), /resource busy/);
    fs.promises.rename = realRename;
    assert.equal(blockedAttempts, 1 + U.RENAME_RETRIES);
    assert.deepEqual(install.snapshot(), before);

    // 2. 되돌리기(rename)마저 막히면 조용히 넘어가지 않고, 표시를 남겨 다음 실행이 백업 전체로 되돌리게 한다
    blockThirdFile();
    fs.renameSync = (from, to) => {
      if (String(to).endsWith(U.UPDATE_MARKER)) return realRenameSync(from, to);
      throw busy();
    };
    await assert.rejects(U.installStaged(args), /되돌리기도 실패.*cli\.js \(EBUSY\)/);
    fs.promises.rename = realRename;
    fs.renameSync = realRenameSync;
    assert.ok(fs.existsSync(path.join(install.appDir, U.UPDATE_MARKER)));
    assert.equal(U.recoverInterruptedUpdate({ appDir: install.appDir }), true);
    assert.deepEqual(install.snapshot(), before);
  } finally {
    fs.promises.rename = realRename;
    fs.renameSync = realRenameSync;
    install.cleanup();
  }
});

test("U12 a scheduled run that throws before uploading still reaches the update check", () => {
  const { spawnSync } = require("node:child_process");
  const install = setupRealRuntime("charge-update-crash-");
  try {
    const { root, chargeHome, appDir } = install;
    fs.writeFileSync(path.join(chargeHome, "config.json"), JSON.stringify({ ...MODE, crash_for_test: true }));
    const { preload, callsFile } = crashBeforeUploadPreload(root);
    const run = spawnSync(process.execPath, ["-r", preload, path.join(appDir, "collect.js")], { encoding: "utf8", env: install.env, timeout: 30_000 });
    assert.equal(run.status, 1, run.stderr);
    assert.match(run.stderr, /crash before upload/);
    assert.deepEqual(fs.readFileSync(callsFile, "utf8").trim().split(String.fromCharCode(10)), [`${MODE.url}/rest/v1/rpc/charge_latest_collector`]);
    assert.ok(fs.existsSync(path.join(appDir, ".update-check.json")), "the update window was recorded");
  } finally {
    install.cleanup();
  }
});

test("U13 a release that fails its self-test in the app directory is rolled back and never retried (D9)", async () => {
  const install = setupInstall();
  try {
    const before = install.snapshot();
    // 스테이징 폴더에서는 통과하고 앱 폴더(이름이 app)에서만 불러오는 순간 죽는 릴리스
    const tgz = buildTgz(releaseEntries("0.2.1", {
      collectBefore: 'if (require("node:path").basename(__dirname) === "app") throw new Error("breaks only in app");',
    }));
    const manifest = manifestFor("0.2.1", tgz);
    const server = fakeServer({ manifest, tgz });
    const { result, errors } = await runUpdate(install, server);
    assert.equal(result.updated, false);
    assert.equal(errors.length, 1, errors.join("\n"));
    assert.match(errors[0], /설치 후 자체 점검 실패: Error: breaks only in app/);
    assert.deepEqual(install.snapshot(), before, "every file is restored from app.prev");
    assert.equal(fs.existsSync(path.join(install.appDir, U.UPDATE_MARKER)), false);
    const stateFile = path.join(install.appDir, ".update-check.json");
    assert.deepEqual(U.readUpdateState(stateFile).failed, [{ version: "0.2.1", integrity: manifest.integrity }]);
    assert.equal(U.readUpdateState(stateFile).nextCheck, NOW + U.CHECK_INTERVAL_MS, "the check window is kept");

    // 다음 확인 창: 같은 릴리스는 내려받지도 않는다
    const again = await runUpdate(install, server, { now: NOW + U.CHECK_INTERVAL_MS + U.CHECK_JITTER_MS });
    assert.equal(again.result.reason, "failed-release");
    assert.equal(again.errors.length, 1);
    assert.match(again.errors[0], /0\.2\.1/);
    assert.equal(server.calls.filter((url) => url.startsWith("https://registry.npmjs.org/")).length, 1);
    assert.deepEqual(U.readUpdateState(stateFile).failed, [{ version: "0.2.1", integrity: manifest.integrity }], "kept across check windows");
    assert.deepEqual(install.snapshot(), before);

    // 고친 더 높은 버전은 설치된다
    const fixedTgz = buildTgz(releaseEntries("0.2.2"));
    const fixed = await runUpdate(install, fakeServer({ manifest: manifestFor("0.2.2", fixedTgz), tgz: fixedTgz }), {
      now: NOW + 2 * (U.CHECK_INTERVAL_MS + U.CHECK_JITTER_MS),
    });
    assert.deepEqual(fixed.errors, []);
    assert.equal(fixed.result.updated, true);
    assert.equal(JSON.parse(fs.readFileSync(path.join(install.appDir, "package.json"), "utf8")).version, "0.2.2");
  } finally {
    install.cleanup();
  }
});

test("U14 a rename blocked briefly by a Windows-style lock is retried, other errors are not (D14)", async () => {
  const install = setupInstall();
  const realRename = fs.promises.rename;
  try {
    const stagingDir = fs.mkdtempSync(path.join(install.root, "staging-"));
    fs.writeFileSync(path.join(stagingDir, "collect.js"), "module.exports = 'collect 0.2.1';");
    fs.writeFileSync(path.join(stagingDir, "package.json"), JSON.stringify({ name: "charge-connect", version: "0.2.1", files: ["collect.js"] }));
    const args = { stagingDir, names: ["collect.js", "package.json"], appDir: install.appDir, backupDir: path.join(install.chargeHome, "app.prev"), retryDelayMs: 1 };
    const codes = ["EPERM", "EBUSY", "EACCES"];
    let calls = 0;
    fs.promises.rename = async (from, to) => {
      calls += 1;
      if (codes.length) throw Object.assign(new Error("locked"), { code: codes.shift() });
      return realRename(from, to);
    };
    await U.installStaged(args);
    fs.promises.rename = realRename;
    assert.equal(calls, 5, "three locked attempts, then both files");
    assert.equal(fs.readFileSync(path.join(install.appDir, "collect.js"), "utf8"), "module.exports = 'collect 0.2.1';");
    assert.equal(fs.existsSync(path.join(install.appDir, U.UPDATE_MARKER)), false);

    // 잠금이 아닌 오류는 다시 시도하지 않고 바로 되돌린다
    let enospc = 0;
    fs.promises.rename = async () => {
      enospc += 1;
      throw Object.assign(new Error("no space left"), { code: "ENOSPC" });
    };
    await assert.rejects(U.installStaged(args), /no space left/);
    fs.promises.rename = realRename;
    assert.equal(enospc, 1);
    assert.equal(fs.existsSync(path.join(install.appDir, U.UPDATE_MARKER)), false);
  } finally {
    fs.promises.rename = realRename;
    install.cleanup();
  }
});

test("U15 the key id is part of the signed message and must name an embedded key (D9)", () => {
  const tgz = buildTgz(releaseEntries("0.2.1"));
  const keys = { k1: TEST_PUBLIC_KEY, k2: OTHER_PUBLIC_KEY };
  const check = (manifest) => U.checkManifest(manifest, { currentVersion: "0.2.0", releaseKeys: keys });
  const byK2 = manifestFor("0.2.1", tgz, { key_id: "k2" }, other.privateKey);
  assert.deepEqual(check(byK2), { ok: true });
  assert.equal(U.releaseMessage(byK2).split(String.fromCharCode(10))[0], "charge-connect-release/v1");
  // 같은 서명을 다른 key id로 옮기면 실패한다
  assert.equal(check({ ...byK2, key_id: "k1" }).reason, "서명 검증 실패");
  // k1 키로 서명하고 k2라고 적어도 실패한다
  assert.equal(check(manifestFor("0.2.1", tgz, { key_id: "k2" })).reason, "서명 검증 실패");
  // 목록에 없는 id, 객체 프로토타입 이름은 알 수 없는 키다
  for (const id of ["k3", "constructor", "hasownproperty"]) {
    assert.match(check(manifestFor("0.2.1", tgz, { key_id: id })).reason, /알 수 없는 서명 키 id/, id);
    assert.equal(U.verifyReleaseSignature(manifestFor("0.2.1", tgz, { key_id: id }), keys), false, id);
  }
  // 테스트 키로 서명한 매니페스트는 내장 운영 키 목록으로는 통과하지 못한다
  assert.equal(U.verifyReleaseSignature(manifestFor("0.2.1", tgz)), false);
  assert.equal(U.manifestFormatError(byK2), null);
});

test("U16 updater.js requires only node: built-in modules, so recovery still loads in a mixed app folder", () => {
  const source = fs.readFileSync(path.join(__dirname, "updater.js"), "utf8");
  const required = [...source.matchAll(/require\(["']([^"']+)["']\)/g)].map((match) => match[1]);
  assert.ok(required.length > 0);
  assert.deepEqual(required.filter((name) => !name.startsWith("node:")), []);
});

test("U17 a run that starts while another process is swapping files skips its collection instead of rolling the update back", async () => {
  const { spawnSync } = require("node:child_process");
  // 진행 표시로 판정한다: 표시를 쓴 프로세스가 살아 있고 표시가 10분 안에 쓰였을 때만 진행 중이다
  const probe = setupInstall();
  try {
    const { appDir } = probe;
    const write = (info) => fs.writeFileSync(path.join(appDir, U.UPDATE_MARKER), typeof info === "string"
      ? info
      : JSON.stringify({ backup: "b", files: [], added: [], ...info }));
    const alive = (pid) => pid === 4242;
    assert.equal(U.updateInProgress({ appDir, now: NOW, isAlive: alive }), false, "no marker");
    write({ pid: 4242, startedAt: NOW });
    assert.equal(U.updateInProgress({ appDir, now: NOW + 60_000, isAlive: alive }), true);
    assert.equal(U.updateInProgress({ appDir, now: NOW + 60_000, isAlive: () => false }), false, "the updating process died");
    assert.equal(U.updateInProgress({ appDir, now: NOW + 11 * 60_000, isAlive: alive }), false, "too old to trust the pid");
    for (const info of [{}, { pid: "4242", startedAt: NOW }, { pid: 4242 }, { pid: process.pid, startedAt: NOW }, "{broken"]) {
      write(info);
      assert.equal(U.updateInProgress({ appDir, now: NOW, isAlive: () => true }), false, JSON.stringify(info));
    }
    // 실제 프로세스: 살아 있는 부모 프로세스, 이미 끝난 자식 프로세스
    write({ pid: process.ppid, startedAt: Date.now() });
    assert.equal(U.updateInProgress({ appDir }), true);
    const exited = spawnSync(process.execPath, ["-e", ""]);
    write({ pid: exited.pid, startedAt: Date.now() });
    assert.equal(U.updateInProgress({ appDir }), false);
  } finally {
    probe.cleanup();
  }

  const install = setupRealRuntime("charge-update-live-");
  try {
    const { root, chargeHome, appDir } = install;
    // 작업 트리 런타임으로 만든 서명 릴리스 0.2.1. 파일마다 표시를 붙여 섞였는지 보이게 한다
    const names = ["collect.js", "identity.js", "updater.js", "cli.js"];
    const release = Object.fromEntries(names.map((name) => [name, `${fs.readFileSync(path.join(__dirname, name), "utf8")}\n// release 0.2.1\n`]));
    release["package.json"] = JSON.stringify({ name: "charge-connect", version: "0.2.1", files: names });
    const tgz = buildTgz(Object.entries(release).map(([name, data]) => ({ name: `package/${name}`, data })));
    fs.writeFileSync(path.join(chargeHome, "config.json"), JSON.stringify({ ...MODE, crash_for_test: true }));
    const { preload, callsFile } = crashBeforeUploadPreload(root);
    let concurrent = null;
    const { result, logs, errors } = await runUpdate(install, fakeServer({ manifest: manifestFor("0.2.1", tgz), tgz }), {
      selfTest: async (dir, version) => {
        // 설치 후 자체 점검 중(표시가 있고 파일은 모두 새 것)에 겹친 스케줄 실행이 뜬다
        if (path.basename(dir) === "app") {
          assert.ok(fs.existsSync(path.join(dir, U.UPDATE_MARKER)));
          concurrent = spawnSync(process.execPath, ["-r", preload, path.join(dir, "collect.js")], { encoding: "utf8", env: install.env, timeout: 30_000 });
        }
        return U.nodeSelfTest(dir, version);
      },
    });
    assert.equal(concurrent.status, 0, concurrent.stderr);
    assert.match(concurrent.stdout, /자동 업데이트가 수집기 파일을 교체하는 중이라 이번 수집은 건너뜁니다/);
    assert.equal(/되돌렸습니다|crash before upload/.test(concurrent.stderr), false, concurrent.stderr);
    assert.equal(fs.existsSync(callsFile), false, "the skipped run neither collects nor checks for updates");
    assert.deepEqual(errors, []);
    assert.equal(result.updated, true);
    assert.deepEqual(logs, ["charge-connect 0.2.0 -> 0.2.1 업데이트 완료 (다음 수집부터 적용)"]);
    for (const [name, data] of Object.entries(release)) assert.equal(fs.readFileSync(path.join(appDir, name), "utf8"), data, name);
    assert.equal(fs.existsSync(path.join(appDir, U.UPDATE_MARKER)), false);
    assert.deepEqual(U.readUpdateState(path.join(appDir, ".update-check.json")).failed, []);
    assert.deepEqual(leftovers(chargeHome), []);
  } finally {
    install.cleanup();
  }
});

test("U18 an update whose marker another run took over is rolled back, not reported as done and not remembered as failed", async () => {
  const realRename = fs.promises.rename;
  const cases = [
    // 설치 후 자체 점검 중에 다른 실행이 app.prev로 되돌렸다: 점검은 옛 파일을 보고 실패한다
    ["restored during a failing self-test", {
      selfTest: async (dir, version) => {
        if (path.basename(dir) === "app") U.recoverInterruptedUpdate({ appDir: dir });
        return U.nodeSelfTest(dir, version);
      },
    }],
    // 점검은 통과했지만(옛 collect.js도 새 package.json의 버전을 찍는다) 앱 폴더가 스테이징한 파일과 다르다
    ["restored during a passing self-test", {
      selfTest: async (dir) => {
        if (path.basename(dir) === "app") U.recoverInterruptedUpdate({ appDir: dir });
      },
    }],
    // 첫 파일을 바꾼 직후 다른 실행이 되돌렸다: 남은 파일은 더 바꾸지 않는다
    ["restored after the first rename", {
      selfTest: async () => {},
      hook: (install) => {
        let fired = false;
        fs.promises.rename = async (from, to) => {
          await realRename(from, to);
          if (!fired && path.dirname(String(to)) === install.appDir) {
            fired = true;
            U.recoverInterruptedUpdate({ appDir: install.appDir });
          }
        };
      },
    }],
  ];
  for (const [label, { selfTest, hook }] of cases) {
    const install = setupInstall();
    try {
      const before = install.snapshot();
      const tgz = buildTgz(releaseEntries("0.2.1"));
      const manifest = manifestFor("0.2.1", tgz);
      if (hook) hook(install);
      const { result, logs, errors } = await runUpdate(install, fakeServer({ manifest, tgz }), { selfTest });
      fs.promises.rename = realRename;
      assert.equal(result.updated, false, label);
      assert.deepEqual(logs, [], `${label}: no success line`);
      assert.equal(errors.length, 1, `${label}: ${errors.join("\n")}`);
      assert.match(errors[0], /다른 실행이 앱 폴더를 app\.prev로 되돌렸습니다/, label);
      assert.deepEqual(install.snapshot(), before, `${label}: the app folder is the old release, not a mix`);
      assert.equal(fs.existsSync(path.join(install.appDir, U.UPDATE_MARKER)), false, label);
      assert.deepEqual(U.readUpdateState(path.join(install.appDir, ".update-check.json")).failed, [], `${label}: a good release is not blacklisted`);
      assert.deepEqual(leftovers(install.chargeHome), [], label);
      // 다음 확인 창에는 같은 릴리스를 다시 설치한다
      const again = await runUpdate(install, fakeServer({ manifest, tgz }), { now: NOW + U.CHECK_INTERVAL_MS + U.CHECK_JITTER_MS });
      assert.deepEqual(again.errors, [], label);
      assert.equal(again.result.updated, true, label);
    } finally {
      fs.promises.rename = realRename;
      install.cleanup();
    }
  }
});

test("U19 the self-test also runs the --log start-up path the Windows and Linux schedules use", async () => {
  // 가짜 릴리스: --log를 받을 때만 불러오는 순간 죽는다
  const install = setupInstall();
  try {
    const before = install.snapshot();
    const tgz = buildTgz(releaseEntries("0.2.1", { collectBefore: 'if (process.argv.includes("--log")) require("node:fs").definitelyMissingApi();' }));
    const { result, errors } = await runUpdate(install, fakeServer({ manifest: manifestFor("0.2.1", tgz), tgz }));
    assert.equal(result.updated, false);
    assert.equal(errors.length, 1, errors.join("\n"));
    assert.match(errors[0], /자체 점검 실패: TypeError/);
    assert.deepEqual(install.snapshot(), before);
    assert.deepEqual(leftovers(install.chargeHome), []);
  } finally {
    install.cleanup();
  }

  // 실제 런타임: 점검은 통과하고, 버리는 로그 폴더를 남기지 않으며, 앱 폴더에 아무것도 쓰지 않는다
  const real = setupRealRuntime("charge-update-selftest-log-");
  try {
    const before = fs.readdirSync(real.appDir).sort();
    await U.nodeSelfTest(real.appDir, require("./package.json").version);
    assert.deepEqual(fs.readdirSync(real.appDir).sort(), before);
    assert.deepEqual(leftovers(real.chargeHome), []);

    // --log 시작 코드가 깨진 실제 collect.js는 스테이징에서 걸린다. 오류 처리기를 등록한 뒤에 죽으면 원인이 stderr가 아니라
    // 로그 파일에 남는데, 그 원인 줄도 오류 메시지에 실린다
    const source = real.original["collect.js"];
    const early = 'process.on("uncaughtException", fatal("치명적 오류"));';
    const late = 'process.on("unhandledRejection", fatal("처리되지 않은 거부"));';
    assert.ok(source.includes(early) && source.includes(late));
    const files = (collect) => new Map([
      ...["identity.js", "updater.js", "cli.js"].map((name) => [name, Buffer.from(real.original[name])]),
      ["collect.js", Buffer.from(collect)],
      ["package.json", Buffer.from(JSON.stringify({ name: "charge-connect", version: "0.2.1", files: ["collect.js", "identity.js", "updater.js", "cli.js"] }))],
    ]);
    for (const [label, collect] of [
      ["before the crash handlers", source.replace(early, `require("node:fs").apiMissingOnThisNode(LOG_FILE);\n  ${early}`)],
      ["after the crash handlers", source.replace(late, `${late}\n  require("node:fs").apiMissingOnThisNode(LOG_FILE);`)],
    ]) {
      await assert.rejects(
        U.stageRelease(files(collect), real.chargeHome, { version: "0.2.1" }),
        /자체 점검 실패: TypeError: .*apiMissingOnThisNode is not a function/,
        label
      );
      assert.deepEqual(leftovers(real.chargeHome), [], label);
    }
  } finally {
    real.cleanup();
  }
});

test("U20 a post-install self-test that times out, is killed or cannot start rolls back without blacklisting the release", async () => {
  for (const [label, failure] of [
    // execFile의 timeout으로 죽은 자식과 같은 모양 (깨어난 직후의 느린 시작, 새 파일을 검사하는 백신)
    ["timeout", () => Object.assign(new Error("Command failed: node collect.js --self-test"), { killed: true, signal: "SIGTERM", code: null, stderr: "" })],
    ["killed by a signal", () => Object.assign(new Error("Command failed: node collect.js --self-test"), { killed: false, signal: "SIGKILL", code: null, stderr: "" })],
    ["temporary folder not created", () => Object.assign(new Error("ENOSPC: no space left on device, mkdtemp"), { code: "ENOSPC" })],
  ]) {
    const install = setupInstall();
    try {
      const before = install.snapshot();
      const tgz = buildTgz(releaseEntries("0.2.1"));
      const manifest = manifestFor("0.2.1", tgz);
      let appRuns = 0;
      const selfTest = async (dir, version) => {
        if (path.basename(dir) === "app" && appRuns++ === 0) throw failure();
        return U.nodeSelfTest(dir, version);
      };
      const first = await runUpdate(install, fakeServer({ manifest, tgz }), { selfTest });
      assert.equal(first.result.updated, false, label);
      assert.equal(first.errors.length, 1, `${label}: ${first.errors.join("\n")}`);
      assert.match(first.errors[0], /설치 후 자체 점검 실패: .*app\.prev로 되돌렸습니다/, label);
      assert.deepEqual(install.snapshot(), before, label);
      const stateFile = path.join(install.appDir, ".update-check.json");
      assert.deepEqual(U.readUpdateState(stateFile).failed, [], `${label}: a transient failure does not blacklist the release`);

      // 다음 확인 창에 같은 릴리스를 다시 설치한다
      const again = await runUpdate(install, fakeServer({ manifest, tgz }), { selfTest, now: NOW + U.CHECK_INTERVAL_MS + U.CHECK_JITTER_MS });
      assert.deepEqual(again.errors, [], label);
      assert.equal(again.result.updated, true, label);
      assert.equal(JSON.parse(fs.readFileSync(path.join(install.appDir, "package.json"), "utf8")).version, "0.2.1", label);
    } finally {
      install.cleanup();
    }
  }
});

test("U21 an uncaught exception or unhandled rejection outside main still reaches the update check, with and without --log", () => {
  const { spawnSync } = require("node:child_process");
  for (const [label, crash] of [
    ["uncaught exception in a timer", 'setImmediate(() => { throw new Error("async crash for test"); });'],
    ["unhandled rejection", 'Promise.reject(new Error("async crash for test"));'],
  ]) {
    for (const withLog of [false, true]) {
      const install = setupRealRuntime("charge-update-async-crash-");
      const name = `${label}, ${withLog ? "--log" : "no --log"}`;
      try {
        const { root, chargeHome, appDir } = install;
        fs.writeFileSync(path.join(chargeHome, "config.json"), JSON.stringify(MODE));
        const { preload, callsFile } = crashBeforeUploadPreload(root);
        // 설정을 처음 읽는 순간 main의 프라미스 밖에서 터질 예외를 걸어 둔다. 수집은 외부 명령(ccusage, npx, security)을 띄우지 못한다
        fs.appendFileSync(preload, [
          "",
          'const cp = require("node:child_process");',
          'cp.execFile = (...args) => { const done = args.pop(); setImmediate(() => done(Object.assign(new Error("spawn blocked in test"), { code: "ENOENT" }))); };',
          "const parseBeforeCrash = JSON.parse;",
          "let armed = true;",
          "JSON.parse = function (...args) {",
          "  const value = parseBeforeCrash.apply(this, args);",
          `  if (armed && value && value.token === ${JSON.stringify(MODE.token)}) { armed = false; ${crash} }`,
          "  return value;",
          "};",
        ].join(String.fromCharCode(10)));
        const logFile = path.join(root, "collector.log");
        const run = spawnSync(process.execPath, ["-r", preload, path.join(appDir, "collect.js"), ...(withLog ? ["--log", logFile] : [])], {
          encoding: "utf8", env: install.env, timeout: 60_000,
        });
        const output = withLog ? (fs.existsSync(logFile) ? fs.readFileSync(logFile, "utf8") : "") : run.stderr;
        assert.equal(run.status, 1, `${name}: ${output}`);
        assert.match(output, /async crash for test/, name);
        const calls = fs.existsSync(callsFile) ? fs.readFileSync(callsFile, "utf8").trim().split(String.fromCharCode(10)) : [];
        assert.equal(calls.filter((url) => url === `${MODE.url}/rest/v1/rpc/charge_latest_collector`).length, 1, `${name}: ${calls.join(", ")}`);
        assert.ok(fs.existsSync(path.join(appDir, ".update-check.json")), `${name}: the update window was recorded`);
      } finally {
        install.cleanup();
      }
    }
  }
});

test("U22 a rename that reached the disk but still reported an error is rolled back too, for a backed-up file and for a new one", async () => {
  const install = setupInstall();
  const realRename = fs.promises.rename;
  try {
    const before = install.snapshot();
    const stagingDir = fs.mkdtempSync(path.join(install.root, "staging-"));
    for (const name of ["cli.js", "new-module.js", "collect.js"]) fs.writeFileSync(path.join(stagingDir, name), `module.exports = "${name} 0.2.1";`);
    fs.writeFileSync(path.join(stagingDir, "package.json"), JSON.stringify({ name: "charge-connect", version: "0.2.1", files: ["cli.js", "collect.js", "new-module.js"] }));
    const args = { stagingDir, names: ["cli.js", "new-module.js", "collect.js", "package.json"], appDir: install.appDir, backupDir: path.join(install.chargeHome, "app.prev"), retryDelayMs: 1 };
    // 첫 파일(cli.js, 백업 있음)과 둘째 파일(new-module.js, 새로 더하는 파일)에서 각각: 이름은 바뀌었는데 오류가 돌아온다 (입출력 오류).
    // 바꾸던 파일을 빼고 되돌리면 새 파일 하나가 옛 파일들 사이에 남는다
    for (const failAt of [1, 2]) {
      let count = 0;
      fs.promises.rename = async (from, to) => {
        await realRename(from, to);
        if (++count === failAt) throw Object.assign(new Error("disk gone"), { code: "EIO" });
      };
      await assert.rejects(U.installStaged(args), /disk gone/);
      fs.promises.rename = realRename;
      assert.equal(count, failAt, "EIO is not retried");
      assert.deepEqual(install.snapshot(), before, `rollback after the rename ${failAt} failure`);
      assert.equal(fs.existsSync(path.join(install.appDir, U.UPDATE_MARKER)), false);
      assert.equal(fs.readdirSync(install.appDir).some((n) => n.endsWith(".new")), false);
    }
  } finally {
    fs.promises.rename = realRename;
    install.cleanup();
  }
});

test("U23 stale update lock takeover is serialized: a lock another process just renewed is kept, a takeover in progress blocks, an abandoned one is swept", async () => {
  const { spawnSync } = require("node:child_process");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "charge-lock-"));
  const realWrite = fs.writeFileSync;
  try {
    const lock = path.join(root, "update.lock");
    const takeover = `${lock}.takeover`;
    const deadPid = spawnSync(process.execPath, ["-e", ""]).pid;
    const OTHER = 424242;
    const alive = (pid) => pid === OTHER || pid === process.pid;

    // 1. 낡은 잠금(죽은 pid)을 본 두 프로세스: 이 프로세스가 넘겨받기 표시를 만들기 직전에 다른 프로세스가 먼저 넘겨받았다.
    //    지우고 다시 만들면 그 새 잠금을 지우고 둘 다 앱 폴더를 바꾼다. 잠금이 바뀐 것을 보고 물러나야 한다
    fs.writeFileSync(lock, String(deadPid));
    let interleaved = 0;
    fs.writeFileSync = (file, data, options) => {
      if (file === takeover && interleaved++ === 0) {
        fs.rmSync(lock, { force: true });
        realWrite(lock, String(OTHER), { flag: "wx" });
      }
      return realWrite(file, data, options);
    };
    try {
      assert.equal(U.acquireUpdateLock(lock, Date.now(), { isAlive: alive }), false);
    } finally {
      fs.writeFileSync = realWrite;
    }
    assert.equal(interleaved, 1);
    assert.equal(fs.readFileSync(lock, "utf8"), String(OTHER), "the other process's fresh lock is kept");
    assert.equal(fs.existsSync(takeover), false);

    // 2. 다른 프로세스가 넘겨받는 중(방금 만든 표시)이면 잡지 못한다, 낡은 잠금과 표시는 그대로
    fs.writeFileSync(lock, String(deadPid));
    fs.writeFileSync(takeover, String(OTHER));
    assert.equal(U.acquireUpdateLock(lock, Date.now(), { isAlive: alive }), false);
    assert.equal(fs.readFileSync(lock, "utf8"), String(deadPid));
    assert.equal(fs.readFileSync(takeover, "utf8"), String(OTHER));
    // 3. 넘겨받다가 죽은 프로세스의 표시(10분 넘게 오래됐다)는 지우고 넘겨받는다
    const old = new Date(Date.now() - 11 * 60_000);
    fs.utimesSync(takeover, old, old);
    assert.equal(U.acquireUpdateLock(lock, Date.now(), { isAlive: alive }), true);
    assert.equal(fs.readFileSync(lock, "utf8"), String(process.pid));
    assert.equal(fs.existsSync(takeover), false);
    U.releaseUpdateLock(lock);
    assert.equal(fs.existsSync(lock), false);

    // 4. 넘겨받기 도구 자체: 지문이 다르면 지우지 않고 false, 잠금이 사라졌으면 create를 부른다, 표시를 만들 수 없으면 그 오류
    fs.writeFileSync(lock, "1");
    const seen = U.lockFingerprint(lock);
    assert.deepEqual([seen.content, typeof seen.key, typeof seen.mtimeMs], ["1", "string", "number"]);
    fs.writeFileSync(lock, "2");
    let created = 0;
    assert.equal(U.takeOverStaleLock(lock, seen.key, () => { created += 1; return true; }, 60_000), false);
    assert.deepEqual([created, fs.readFileSync(lock, "utf8"), fs.existsSync(takeover)], [0, "2", false]);
    assert.equal(U.takeOverStaleLock(lock, U.lockFingerprint(lock).key, () => { created += 1; return true; }, 60_000), true);
    assert.deepEqual([created, fs.existsSync(lock)], [1, false], "the stale lock is removed before create");
    assert.equal(U.takeOverStaleLock(lock, seen.key, () => { created += 1; return true; }, 60_000), true, "a lock that is already gone only needs create");
    assert.equal(created, 2);
    assert.equal(U.lockFingerprint(lock), null);
    const missing = path.join(root, "missing", "update.lock");
    assert.equal(U.takeOverStaleLock(missing, "x", () => true, 60_000)?.code, "ENOENT");
  } finally {
    fs.writeFileSync = realWrite;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("U24 recovery also removes the .new copy of a file the interrupted update was adding", () => {
  const install = setupInstall();
  try {
    const { appDir, chargeHome } = install;
    const backupDir = path.join(chargeHome, "app.prev");
    fs.mkdirSync(backupDir);
    for (const name of ["collect.js", "package.json"]) fs.copyFileSync(path.join(appDir, name), path.join(backupDir, name));
    const before = install.snapshot();
    // install.ps1을 더하는 업데이트가 install.ps1.new를 쓴 뒤 이름을 바꾸기 전에 죽었다, collect.js.new도 쓰다 말았다
    fs.writeFileSync(path.join(appDir, "install.ps1.new"), "new script");
    fs.writeFileSync(path.join(appDir, "collect.js.new"), "half written");
    fs.writeFileSync(path.join(appDir, "collect.js"), "module.exports = 'collect new';\n");
    fs.writeFileSync(path.join(appDir, U.UPDATE_MARKER), JSON.stringify({
      backup: backupDir, files: ["collect.js", "install.ps1", "package.json"], added: ["install.ps1"], from: "0.2.0", to: "0.2.1",
    }));
    assert.equal(U.recoverInterruptedUpdate({ appDir }), true);
    assert.deepEqual(install.snapshot(), before);
    assert.deepEqual(fs.readdirSync(appDir).filter((n) => n.endsWith(".new")), []);
    assert.equal(fs.existsSync(path.join(appDir, U.UPDATE_MARKER)), false);
  } finally {
    install.cleanup();
  }
});
