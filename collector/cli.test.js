const test = require("node:test");
const assert = require("node:assert/strict");

const CLI = require("./cli");

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
