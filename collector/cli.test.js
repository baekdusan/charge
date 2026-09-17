const test = require("node:test");
const assert = require("node:assert/strict");

const CLI = require("./cli");

// 설치 원본 패키지. cloud.json은 gitignore라 새로 받은 저장소와 CI에는 없으므로, 런타임 파일을 임시 폴더에 복사하고
// cloud.json이 없을 때만 가짜 주소를 넣는다. 패키지 폴더(__dirname)에는 절대 쓰지 않는다: 테스트가 죽어 가짜가 남은 채로
// 발행되면 모든 설치의 페어링이 깨진다.
let testPackageDir = null;
function testPackage() {
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  if (testPackageDir) return testPackageDir;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "charge-cli-package-"));
  for (const name of CLI.runtimeFiles()) {
    const from = path.join(__dirname, name);
    if (fs.existsSync(from)) fs.copyFileSync(from, path.join(dir, name));
    else if (name === "cloud.json") fs.writeFileSync(path.join(dir, name), JSON.stringify({ url: "https://example.invalid", anon: "test-anon" }));
  }
  process.on("exit", () => fs.rmSync(dir, { recursive: true, force: true }));
  testPackageDir = dir;
  return dir;
}

test("Pairing saves only Claude location settings for the scheduler, including an empty override", () => {
  const fs = require("node:fs");
  const path = require("node:path");
  const { execFileSync } = require("node:child_process");
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "charge-pair-env-"));
  try {
    execFileSync(process.execPath, ["-e", `
      global.fetch = async () => ({ ok: true, json: async () => 'test-device-token' });
      require('./cli').pair('test-code').catch(() => process.exit(1));
    `], {
      cwd: __dirname,
      env: { ...process.env, CHARGE_HOME: dir, CHARGE_URL: "https://example.invalid", CHARGE_ANON: "test-anon",
        CLAUDE_CONFIG_DIR: path.join(dir, "work account"), CLAUDE_SECURESTORAGE_CONFIG_DIR: "",
        CLAUDE_CODE_OAUTH_TOKEN: "must-not-be-saved", ANTHROPIC_API_KEY: "must-not-be-saved" },
      stdio: "pipe",
    });
    const raw = fs.readFileSync(path.join(dir, "config.json"), "utf8");
    assert.deepEqual(JSON.parse(raw).claude_environment, {
      CLAUDE_CONFIG_DIR: path.join(dir, "work account"), CLAUDE_SECURESTORAGE_CONFIG_DIR: "",
    });
    assert.ok(!raw.includes("must-not-be-saved"));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("CLI update version comparison handles newer, older, and stable releases", () => {
  assert.equal(CLI.isNewerVersion("0.1.7", "0.1.8"), true);
  assert.equal(CLI.isNewerVersion("0.2.0", "0.1.9"), false);
  assert.equal(CLI.isNewerVersion("1.0.0-beta.1", "1.0.0"), true);
  assert.equal(CLI.isNewerVersion("1.0.0", "not-a-version"), false);
});

test("CLI update accepts ok and hands the untouched pairing invocation to the new version", async () => {
  let launched = null;
  const logs = [];
  const handedOff = await CLI.maybeUpdateBeforePairing({
    currentVersion: "0.1.7",
    fetchFn: async () => ({ ok: true, json: async () => ({ version: "0.1.8" }) }),
    interactive: true,
    ask: async () => "ok",
    launch: (version) => { launched = version; },
    env: {},
    log: (message) => logs.push(message),
  });
  assert.equal(handedOff, true);
  assert.equal(launched, "0.1.8");
  assert.match(logs.join("\n"), /업데이트한 뒤 연동/);
});

test("CLI update never interrupts pairing when the registry check fails", async () => {
  let launched = false;
  const handedOff = await CLI.maybeUpdateBeforePairing({
    currentVersion: "0.1.7",
    fetchFn: async () => { throw new Error("offline"); },
    interactive: true,
    ask: async () => "yes",
    launch: () => { launched = true; },
    env: {},
    log: () => {},
  });
  assert.equal(handedOff, false);
  assert.equal(launched, false);
});

test("CLI runtime file list follows package.json files and always carries package.json", () => {
  const files = CLI.runtimeFiles();
  const pkg = require("./package.json");
  for (const f of pkg.files) assert.ok(files.includes(f), f);
  assert.ok(files.includes("updater.js"));
  assert.ok(files.includes("package.json"));
  assert.equal(files.some((f) => f.includes("/") || f.endsWith(".test.js")), false);
});

test("CLI update needs a pairing, reinstalls the runtime and only re-registers safe schedules", async () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "charge-cli-update-"));
  const saved = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE, CHARGE_HOME: process.env.CHARGE_HOME };
  process.env.HOME = root;
  process.env.USERPROFILE = root;
  const confDir = path.join(root, ".charge");
  process.env.CHARGE_HOME = confDir;
  const quiet = { log: () => {}, logError: () => {} };
  try {
    const unpaired = await CLI.update({
      confDir, home: root, platform: "linux", ...quiet,
      install: () => { throw new Error("must not install without a pairing"); },
      schedule: () => { throw new Error("must not schedule"); },
      runCollect: () => { throw new Error("must not collect"); },
    });
    assert.deepEqual(unpaired, { installed: false, collected: false, version: null });
    assert.equal(fs.existsSync(path.join(confDir, "app")), false);

    fs.mkdirSync(confDir, { recursive: true });
    const config = JSON.stringify({ url: "https://example.invalid", anon: "a", token: "t", auto_update: false });
    fs.writeFileSync(path.join(confDir, "config.json"), config);
    const appDir = path.join(confDir, "app");
    const run = async (platform, extra = {}) => {
      const calls = [];
      const logs = [];
      const result = await CLI.update({
        confDir, home: root, platform,
        install: (dir) => CLI.installRuntime(dir, { source: testPackage(), log: () => {} }),
        schedule: (dir) => calls.push(["schedule", dir]),
        runCollect: (dir) => calls.push(["collect", dir]),
        log: (m) => logs.push(m), logError: (m) => logs.push(m),
        ...extra,
      });
      return { result, calls, logs };
    };

    const linux = await run("linux");
    assert.deepEqual(linux.result, { installed: true, collected: true, version: require("./package.json").version });
    assert.deepEqual(linux.calls, [["schedule", appDir], ["collect", appDir]]);
    for (const f of ["collect.js", "cli.js", "identity.js", "updater.js", "package.json"]) {
      assert.ok(fs.existsSync(path.join(appDir, f)), f);
    }
    assert.equal(fs.readFileSync(path.join(confDir, "config.json"), "utf8"), config);
    assert.match(linux.logs.join("\n"), new RegExp(`charge-connect ${require("./package.json").version.replace(/\./g, "\\.")} 설치 완료`));
    // 앱 폴더가 없던 첫 설치: 백업할 것이 없으니 app.prev도, 진행 표시도, 잠금도 남기지 않는다
    assert.equal(fs.existsSync(path.join(confDir, "app.prev")), false, "a first install leaves no empty app.prev");
    assert.equal(fs.existsSync(path.join(appDir, ".update-in-progress.json")), false);
    assert.equal(fs.existsSync(path.join(confDir, "update.lock")), false);

    // Windows: install.ps1은 권한에 따라 등록 방식을 바꾸므로 부르지 않고 안내만 한다
    const win = await run("win32");
    assert.deepEqual(win.calls, [["collect", appDir]]);
    assert.match(win.logs.join("\n"), /install\.ps1/);
    // 두 번째 설치부터는 지금 파일을 app.prev에 백업한다
    assert.equal(fs.readFileSync(path.join(confDir, "app.prev", "collect.js"), "utf8"), fs.readFileSync(path.join(testPackage(), "collect.js"), "utf8"));

    // macOS: 등록이 이미 이 런타임을 가리키면 launchd를 다시 건드리지 않는다
    const macMissing = await run("darwin");
    assert.deepEqual(macMissing.calls, [["schedule", appDir], ["collect", appDir]]);
    const agents = path.join(root, "Library", "LaunchAgents");
    fs.mkdirSync(agents, { recursive: true });
    fs.writeFileSync(path.join(agents, "com.charge.connect.plist"), `<string>exec node "${path.join(appDir, "collect.js")}"</string>`);
    const macRegistered = await run("darwin");
    assert.deepEqual(macRegistered.calls, [["collect", appDir]]);

    // 설치 스크립트가 수동 안내(종료 코드 3)를 냈거나 수집이 실패해도 설치 자체는 끝난 것이다
    const guided = await run("linux", {
      schedule: () => { throw Object.assign(new Error("exit 3"), { status: 3 }); },
      runCollect: () => { throw new Error("offline"); },
    });
    assert.deepEqual(guided.result, { installed: true, collected: false, version: require("./package.json").version });

    // 자동 업데이트로 이미 더 새 버전이 깔렸으면 실행한 옛 패키지로 되돌리지 않는다 (스케줄 확인과 수집은 그대로)
    fs.writeFileSync(path.join(appDir, "package.json"), JSON.stringify({ name: "charge-connect", version: "9.9.9", files: ["collect.js"] }));
    fs.writeFileSync(path.join(appDir, "collect.js"), "// newer runtime\n");
    const newer = await run("linux");
    assert.deepEqual(newer.result, { installed: true, collected: true, version: "9.9.9" });
    assert.equal(fs.readFileSync(path.join(appDir, "collect.js"), "utf8"), "// newer runtime\n");
    assert.deepEqual(newer.calls, [["schedule", appDir], ["collect", appDir]]);
    assert.match(newer.logs.join("\n"), /9\.9\.9/);
    // 더 오래된 설치는 평소처럼 덮는다
    fs.writeFileSync(path.join(appDir, "package.json"), JSON.stringify({ name: "charge-connect", version: "0.1.9", files: ["collect.js"] }));
    const older = await run("linux");
    assert.equal(older.result.version, require("./package.json").version);
    assert.notEqual(fs.readFileSync(path.join(appDir, "collect.js"), "utf8"), "// newer runtime\n");
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// 옛 런타임(작업 트리 파일에 표시를 붙인 것, 버전 0.1.9)이 설치된 ~/.charge와 그 옆의 설정, 상태 파일
function setupOldRuntime(prefix) {
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const confDir = path.join(root, ".charge");
  const appDir = path.join(confDir, "app");
  const old = {};
  for (const name of ["collect.js", "identity.js", "updater.js", "cli.js"]) {
    old[name] = `${fs.readFileSync(path.join(__dirname, name), "utf8")}\n// old runtime\n`;
  }
  old["package.json"] = JSON.stringify({ name: "charge-connect", version: "0.1.9", files: ["cli.js", "collect.js", "identity.js", "updater.js", "install.sh"] });
  old["install.sh"] = "#!/bin/bash\necho old\n";
  const state = JSON.stringify({ gate: null, lastRequestAt: 1, lastStatus: "ok" });
  const reset = () => {
    fs.rmSync(appDir, { recursive: true, force: true });
    fs.mkdirSync(appDir, { recursive: true });
    for (const [name, body] of Object.entries(old)) fs.writeFileSync(path.join(appDir, name), body);
    fs.writeFileSync(path.join(appDir, ".claude-rate-limit.json"), state);
  };
  reset();
  fs.writeFileSync(path.join(confDir, "config.json"), JSON.stringify({ url: "https://example.invalid", anon: "a", token: "t", auto_update: false }));
  const env = { ...process.env, HOME: root, USERPROFILE: root, CHARGE_HOME: confDir, NODE_OPTIONS: "" };
  for (const key of ["CHARGE_TOKEN", "CHARGE_URL", "CHARGE_ANON", "CHARGE_SKIP_UPDATE", "CHARGE_INSTALL_ID"]) delete env[key];
  const snapshot = () => Object.fromEntries(
    fs.readdirSync(appDir).filter((n) => !n.startsWith(".update-check")).sort().map((n) => [n, fs.readFileSync(path.join(appDir, n), "utf8")])
  );
  return { root, confDir, appDir, old, state, env, reset, snapshot, cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

// 수집을 시작하기 전에 collect.js의 main이 예외로 끝나게 하는 preload (updater.test.js와 같다). 네트워크는 모두 가짜다.
function crashBeforeUploadPreload(root) {
  const fs = require("node:fs");
  const path = require("node:path");
  const preload = path.join(root, "preload.js");
  fs.writeFileSync(preload, [
    "const parse = JSON.parse;",
    "JSON.parse = function (...args) {",
    "  const value = parse.apply(this, args);",
    "  if (value && value.crash_for_test === true) {",
    '    Object.defineProperty(value, "claude_environment", { get() { throw new Error("crash before upload"); } });',
    "  }",
    "  return value;",
    "};",
    'globalThis.fetch = async () => new Response("[]", { status: 200, headers: { "content-type": "application/json" } });',
  ].join("\n"));
  return preload;
}

const INSTALL_ORDER = ["cli.js", "identity.js", "updater.js", "install.sh", "install.linux.sh", "install.ps1", "cloud.json", "collect.js", "package.json"];

test("CLI installRuntime holds the update lock: a live holder blocks (update fails, pairing waits once), dead or old locks are taken over", async () => {
  const fs = require("node:fs");
  const path = require("node:path");
  const { spawnSync } = require("node:child_process");
  const install = setupOldRuntime("charge-cli-lock-");
  try {
    const { confDir, appDir } = install;
    const lockFile = path.join(confDir, "update.lock");
    const before = install.snapshot();
    // 살아 있는 프로세스(이 테스트)의 잠금: 아무것도 바꾸지 않고 LOCKED로 끝난다, 남의 잠금은 지우지 않는다
    fs.writeFileSync(lockFile, String(process.pid));
    await assert.rejects(CLI.installRuntime(confDir, { source: testPackage() }), (e) => e.code === "LOCKED" && /교체하는 중이라 지금은 설치하지 않습니다/.test(e.message));
    assert.deepEqual(install.snapshot(), before);
    assert.equal(fs.readFileSync(lockFile, "utf8"), String(process.pid));
    assert.equal(fs.existsSync(path.join(confDir, "app.prev")), false);
    // `charge-connect update`: 설치 실패로 끝나고 스케줄과 수집은 건드리지 않는다 (main이 0이 아닌 코드로 끝낸다)
    const calls = [];
    const logs = [];
    const result = await CLI.update({
      confDir, home: install.root, platform: "linux",
      install: (dir) => CLI.installRuntime(dir, { source: testPackage(), log: () => {} }),
      schedule: (dir) => calls.push(["schedule", dir]), runCollect: (dir) => calls.push(["collect", dir]),
      log: (m) => logs.push(m), logError: (m) => logs.push(m),
    });
    assert.deepEqual(result, { installed: false, collected: false, version: null });
    assert.deepEqual(calls, []);
    assert.match(logs.join("\n"), /교체하는 중이라 지금은 설치하지 않습니다/);
    assert.deepEqual(install.snapshot(), before);
    // 페어링은 잠깐 기다렸다가 한 번 더 잡는다
    setTimeout(() => fs.rmSync(lockFile, { force: true }), 100);
    const waited = [];
    assert.equal(await CLI.installRuntime(confDir, { source: testPackage(), waitMs: 500, log: (m) => waited.push(m) }), appDir);
    assert.match(waited.join("\n"), /다시 시도합니다/);
    assert.equal(fs.readFileSync(path.join(appDir, "collect.js"), "utf8"), fs.readFileSync(path.join(testPackage(), "collect.js"), "utf8"));
    assert.equal(fs.existsSync(lockFile), false, "released after the install");
    // 기다려도 풀리지 않으면 실패한다
    fs.writeFileSync(lockFile, String(process.pid));
    await assert.rejects(CLI.installRuntime(confDir, { source: testPackage(), waitMs: 50, log: () => {} }), { code: "LOCKED" });
    // 만든 프로세스가 죽은 잠금과 10분이 지난 잠금은 넘겨받는다. 그 죽은 설치가 남긴 점검, 스테이징 폴더도 치운다
    const exited = spawnSync(process.execPath, ["-e", ""]);
    fs.writeFileSync(lockFile, String(exited.pid));
    for (const name of ["app.self-test-dead", "app.staging-dead"]) fs.mkdirSync(path.join(confDir, name));
    await CLI.installRuntime(confDir, { source: testPackage(), log: () => {} });
    assert.equal(fs.existsSync(lockFile), false);
    assert.deepEqual(fs.readdirSync(confDir).filter((n) => /^app\.(self-test|staging)-/.test(n)), []);
    fs.writeFileSync(lockFile, String(process.pid));
    const old = new Date(Date.now() - 11 * 60_000);
    fs.utimesSync(lockFile, old, old);
    await CLI.installRuntime(confDir, { source: testPackage(), log: () => {} });
    assert.equal(fs.existsSync(lockFile), false);
  } finally {
    install.cleanup();
  }
});

test("CLI installRuntime backs up to app.prev and swaps through .new with collect.js second to last; an interrupted swap is rolled back or recovered", async () => {
  const fs = require("node:fs");
  const path = require("node:path");
  const { spawnSync } = require("node:child_process");
  const U = require("./updater");
  const realRename = fs.promises.rename;
  const install = setupOldRuntime("charge-cli-swap-");
  try {
    const { confDir, appDir, old, state } = install;
    const backupDir = path.join(confDir, "app.prev");
    const before = install.snapshot();

    // 1. 파일마다 <파일>.new를 쓰고 이름을 바꾼다, collect.js는 package.json 바로 앞이다. 옛 파일은 app.prev에, 상태 파일은 그대로
    const renames = [];
    fs.promises.rename = async (from, to) => {
      renames.push([path.basename(from), path.basename(to)]);
      return realRename(from, to);
    };
    await CLI.installRuntime(confDir, { source: testPackage(), log: () => {} });
    fs.promises.rename = realRename;
    assert.deepEqual(renames.map(([, to]) => to), INSTALL_ORDER);
    assert.ok(renames.every(([from, to]) => from === `${to}.new`), JSON.stringify(renames));
    for (const name of CLI.runtimeFiles()) {
      assert.equal(fs.readFileSync(path.join(appDir, name), "utf8"), fs.readFileSync(path.join(testPackage(), name), "utf8"), name);
    }
    assert.equal(fs.readFileSync(path.join(appDir, ".claude-rate-limit.json"), "utf8"), state, "collector state files are kept");
    assert.equal(fs.existsSync(path.join(appDir, U.UPDATE_MARKER)), false);
    assert.equal(fs.readdirSync(appDir).some((n) => n.endsWith(".new")), false);
    for (const [name, body] of Object.entries(old)) assert.equal(fs.readFileSync(path.join(backupDir, name), "utf8"), body, `backup ${name}`);
    if (process.platform !== "win32") assert.equal(fs.statSync(path.join(appDir, "install.sh")).mode & 0o777, 0o755);
    assert.equal(fs.existsSync(path.join(confDir, "update.lock")), false);

    // 2. 첫 rename 뒤에 던지면 그 자리에서 되돌린다: 옛 런타임 그대로, 표시도 .new도 잠금도 없다
    install.reset();
    let count = 0;
    fs.promises.rename = async (from, to) => {
      await realRename(from, to);
      if (++count === 1) throw Object.assign(new Error("disk gone"), { code: "EIO" });
    };
    await assert.rejects(CLI.installRuntime(confDir, { source: testPackage(), log: () => {} }), /disk gone/);
    fs.promises.rename = realRename;
    assert.equal(count, 1);
    assert.deepEqual(install.snapshot(), before);
    assert.equal(fs.existsSync(path.join(confDir, "update.lock")), false);

    // 3. 첫 rename 직후 강제 종료(전원 차단, Ctrl+C): 표시가 남고 옛 collect.js는 아직 그대로다
    install.reset();
    const killer = path.join(install.root, "killer.js");
    fs.writeFileSync(killer, [
      'const fs = require("node:fs");',
      "const rename = fs.promises.rename;",
      "let count = 0;",
      'fs.promises.rename = async (from, to) => { await rename(from, to); if (++count === 1) process.kill(process.pid, "SIGKILL"); };',
      `require(${JSON.stringify(path.join(__dirname, "cli.js"))}).installRuntime(${JSON.stringify(confDir)}, { source: ${JSON.stringify(testPackage())}, log: () => {} })`,
      "  .catch((e) => { console.error(e); process.exit(2); });",
    ].join("\n"));
    const killed = spawnSync(process.execPath, [killer], { encoding: "utf8", env: install.env, timeout: 60_000 });
    assert.equal(killed.status, null, killed.stderr);
    const { id, startedAt, ...marker } = JSON.parse(fs.readFileSync(path.join(appDir, U.UPDATE_MARKER), "utf8"));
    assert.deepEqual(marker, {
      backup: backupDir, files: INSTALL_ORDER, added: ["install.linux.sh", "install.ps1", "cloud.json"],
      from: "0.1.9", to: require("./package.json").version, pid: killed.pid,
    });
    assert.match(id, /^[0-9a-f-]{36}$/);
    assert.ok(Math.abs(Date.now() - startedAt) < 60_000);
    assert.equal(U.updateInProgress({ appDir }), false, "the killed installer is not running");
    assert.equal(fs.readFileSync(path.join(appDir, "cli.js"), "utf8"), fs.readFileSync(path.join(testPackage(), "cli.js"), "utf8"), "the first file is new");
    assert.equal(fs.readFileSync(path.join(appDir, "collect.js"), "utf8"), old["collect.js"], "collect.js is still the old one");
    assert.equal(fs.readFileSync(path.join(appDir, "package.json"), "utf8"), old["package.json"]);
    assert.equal(fs.readFileSync(path.join(confDir, "update.lock"), "utf8"), String(killed.pid), "the killed installer left its lock");

    // 다음 수집: 옛 collect.js가 다른 모듈을 불러오기 전에 표시를 보고 app.prev로 되돌린다 (수집 전에 main이 예외로 끝나게 한다)
    fs.writeFileSync(path.join(confDir, "config.json"), JSON.stringify({ url: "https://example.invalid", anon: "a", token: "t", crash_for_test: true }));
    const next = spawnSync(process.execPath, ["-r", crashBeforeUploadPreload(install.root), path.join(appDir, "collect.js")], { encoding: "utf8", env: install.env, timeout: 60_000 });
    assert.equal(next.status, 1, next.stderr);
    assert.match(next.stderr, /교체 도중 끊긴 자동 업데이트를 app\.prev 백업으로 되돌렸습니다/);
    assert.match(next.stderr, /crash before upload/);
    assert.deepEqual(install.snapshot(), before, "every file is the old one again");
    assert.equal(fs.existsSync(path.join(appDir, U.UPDATE_MARKER)), false);
    // 죽은 설치의 잠금은 다음 설치가 넘겨받는다
    await CLI.installRuntime(confDir, { source: testPackage(), log: () => {} });
    assert.equal(fs.readFileSync(path.join(appDir, "collect.js"), "utf8"), fs.readFileSync(path.join(testPackage(), "collect.js"), "utf8"));
    assert.equal(fs.existsSync(path.join(confDir, "update.lock")), false);

    // 4. 되돌리기까지 실패한 표시가 남아 있으면(백업이 사라졌다) 표시를 지우고 런타임 전체를 새로 설치한다
    install.reset();
    fs.writeFileSync(path.join(appDir, U.UPDATE_MARKER), JSON.stringify({ backup: path.join(confDir, "missing-backup"), files: ["cli.js"], added: [] }));
    const logs = [];
    await CLI.installRuntime(confDir, { source: testPackage(), log: (m) => logs.push(m) });
    assert.match(logs.join("\n"), /되돌리지 못했습니다.*런타임 전체를 새로 설치합니다/);
    assert.equal(fs.existsSync(path.join(appDir, U.UPDATE_MARKER)), false);
    assert.equal(fs.readFileSync(path.join(appDir, "collect.js"), "utf8"), fs.readFileSync(path.join(testPackage(), "collect.js"), "utf8"));
  } finally {
    fs.promises.rename = realRename;
    install.cleanup();
  }
});

test("CLI installRuntime refuses a package that fails node --check or its self-test and leaves the installed runtime alone", async () => {
  const fs = require("node:fs");
  const path = require("node:path");
  const U = require("./updater");
  const install = setupOldRuntime("charge-cli-verify-");
  try {
    const { confDir, appDir, root } = install;
    const before = install.snapshot();
    const source = path.join(root, "package");
    fs.mkdirSync(source);
    for (const name of CLI.runtimeFiles()) fs.copyFileSync(path.join(testPackage(), name), path.join(source, name));
    // 파일이 빠진 패키지(청소되다 만 npx 캐시): 남은 파일만 깔면 옛 파일 하나가 새 파일들 사이에 남고 자체 점검은 그것을 못 잡는다
    for (const missing of ["collect.js", "package.json", "install.linux.sh"]) {
      fs.renameSync(path.join(source, missing), path.join(root, missing));
      await assert.rejects(CLI.installRuntime(confDir, { source, log: () => {} }), new RegExp(`설치할 패키지에 없는 파일: ${missing.replace(".", "\\.")}`));
      fs.renameSync(path.join(root, missing), path.join(source, missing));
      assert.deepEqual(install.snapshot(), before, missing);
    }
    // 해석할 수 없는 .json도 자동 업데이트처럼 거부한다
    const cloud = fs.readFileSync(path.join(source, "cloud.json"));
    fs.writeFileSync(path.join(source, "cloud.json"), "{broken");
    await assert.rejects(CLI.installRuntime(confDir, { source, log: () => {} }), /cloud\.json 파일을 해석할 수 없습니다/);
    fs.writeFileSync(path.join(source, "cloud.json"), cloud);
    assert.deepEqual(install.snapshot(), before);
    assert.equal(fs.existsSync(path.join(confDir, "app.prev")), false);
    // 문법이 깨진 파일: 교체는커녕 백업도 시작하지 않는다
    fs.writeFileSync(path.join(source, "identity.js"), "module.exports = {\n");
    await assert.rejects(CLI.installRuntime(confDir, { source, log: () => {} }), /identity\.js 문법 검사 실패/);
    assert.deepEqual(install.snapshot(), before);
    assert.equal(fs.existsSync(path.join(confDir, "app.prev")), false);
    // 불러오는 순간 죽는 파일: 교체한 뒤 자체 점검에서 걸려 app.prev로 되돌린다
    fs.writeFileSync(path.join(source, "identity.js"), 'throw new Error("broken identity");\n');
    await assert.rejects(CLI.installRuntime(confDir, { source, log: () => {} }), /자체 점검 실패.*broken identity.*app\.prev로 되돌렸습니다/);
    assert.deepEqual(install.snapshot(), before);
    assert.equal(fs.existsSync(path.join(appDir, U.UPDATE_MARKER)), false);
    assert.equal(fs.existsSync(path.join(confDir, "update.lock")), false);
    assert.deepEqual(fs.readdirSync(confDir).filter((n) => n.startsWith("app.self-test-")), []);
  } finally {
    install.cleanup();
  }
});

test("CLI run executes the installed runtime, so a manual run shares the scheduled run's state and spacing lock", () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  const { spawnSync } = require("node:child_process");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "charge-cli-run-"));
  try {
    const confDir = path.join(root, ".charge");
    // 설치 전(앱 폴더 없음)에는 이 패키지의 collect.js다
    assert.equal(CLI.installedRuntimeDir(confDir), __dirname);
    fs.mkdirSync(path.join(confDir, "app"), { recursive: true });
    assert.equal(CLI.installedRuntimeDir(confDir), __dirname, "an app folder without collect.js is not a runtime");
    const marker = path.join(root, "ran.txt");
    fs.writeFileSync(path.join(confDir, "app", "collect.js"), `require("node:fs").writeFileSync(${JSON.stringify(marker)}, __filename);\n`);
    assert.equal(CLI.installedRuntimeDir(confDir), path.join(confDir, "app"));
    const env = { ...process.env, HOME: root, USERPROFILE: root, CHARGE_HOME: confDir, NODE_OPTIONS: "" };
    const run = spawnSync(process.execPath, [path.join(__dirname, "cli.js"), "run"], { encoding: "utf8", env, timeout: 60_000 });
    assert.equal(run.status, 0, run.stderr);
    // 임시 폴더가 심볼릭 링크(macOS의 /var)나 8.3 짧은 이름(Windows의 RUNNER~1) 아래일 수 있어 양쪽 모두 실제 경로로 비교한다
    assert.equal(fs.realpathSync.native(fs.readFileSync(marker, "utf8")), fs.realpathSync.native(path.join(confDir, "app", "collect.js")));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("CLI update does not trust the installed version while an interrupted update's marker is pending", async () => {
  const fs = require("node:fs");
  const path = require("node:path");
  const { spawnSync } = require("node:child_process");
  const U = require("./updater");
  const install = setupOldRuntime("charge-cli-marker-");
  try {
    const { confDir, appDir, old, root } = install;
    // 자동 업데이트가 0.9.9를 깔다가 package.json까지 바꾼 뒤(자체 점검 전) 죽었다: 표시가 남고 백업은 0.1.9다
    const backupDir = path.join(confDir, "app.prev");
    fs.mkdirSync(backupDir);
    for (const [name, body] of Object.entries(old)) fs.writeFileSync(path.join(backupDir, name), body);
    fs.writeFileSync(path.join(appDir, "collect.js"), "// half installed 0.9.9\n");
    fs.writeFileSync(path.join(appDir, "package.json"), JSON.stringify({ name: "charge-connect", version: "0.9.9", files: ["collect.js"] }));
    const exited = spawnSync(process.execPath, ["-e", ""]);
    fs.writeFileSync(path.join(appDir, U.UPDATE_MARKER), JSON.stringify({
      backup: backupDir, files: ["collect.js", "package.json"], added: [], from: "0.1.9", to: "0.9.9", id: "x", pid: exited.pid, startedAt: Date.now() - 60_000,
    }));
    const calls = [];
    const logs = [];
    const result = await CLI.update({
      confDir, home: root, platform: "linux",
      install: (dir) => CLI.installRuntime(dir, { source: testPackage(), log: (m) => logs.push(m) }),
      schedule: (dir) => calls.push(["schedule", dir]), runCollect: (dir) => calls.push(["collect", dir]),
      log: (m) => logs.push(m), logError: (m) => logs.push(m),
    });
    // 0.9.9가 깔린 것처럼 보고하지 않는다: 잠금 아래에서 되돌린 뒤 이 패키지를 설치하고 그 버전을 보고한다
    const version = require("./package.json").version;
    assert.deepEqual(result, { installed: true, collected: true, version });
    assert.deepEqual(calls, [["schedule", appDir], ["collect", appDir]]);
    assert.match(logs.join("\n"), /되돌린 뒤 설치합니다/);
    assert.equal(logs.some((line) => /더 새 버전.*그대로 둡니다/.test(line)), false, logs.join("\n"));
    assert.equal(fs.existsSync(path.join(appDir, U.UPDATE_MARKER)), false);
    assert.equal(fs.readFileSync(path.join(appDir, "collect.js"), "utf8"), fs.readFileSync(path.join(testPackage(), "collect.js"), "utf8"));
    assert.equal(JSON.parse(fs.readFileSync(path.join(appDir, "package.json"), "utf8")).version, version);
  } finally {
    install.cleanup();
  }
});
