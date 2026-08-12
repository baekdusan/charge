// 인앱 브라우저 탈출 단위 테스트 — 실행: node --test docs/inapp-browser.test.js
// 가짜 window/document 위에서 모듈을 돌려 감지·탈출 분기·클릭 배선을 검증한다 (브라우저 불필요).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SRC = fs.readFileSync(path.join(__dirname, "inapp-browser.js"), "utf8");
const URL = "https://apps.apple.com/app/id6796766465";
const IG_ESCAPE = `instagram://extbrowser/?url=${encodeURIComponent(URL)}`;
const SAFARI_ESCAPE = `x-safari-${URL}`;
const INTENT_ESCAPE = "intent://apps.apple.com/app/id6796766465#Intent;scheme=https;end";

const IOS = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
const UA = {
  igIOS: `${IOS} Instagram 320.0.0.0.0 (iPhone14,2; iOS 17_5)`,
  threadsIOS: `${IOS} Barcelona 350.0.0.0`,
  fbIOS: `${IOS} [FBAN/FBIOS;FBAV/460.0.0.32.107;FB_IAB/FB4A]`,
  messengerIOS: `${IOS} [FBAN/MessengerForiOS;FBAV/460.0;FB_IAB/MESSENGER]`,
  igAndroid: "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 Chrome/126 Mobile Safari/537.36 Instagram 320.0.0.0.0",
  fbAndroid: "Mozilla/5.0 (Linux; Android 14; SM-S918B; wv) AppleWebKit/537.36 Chrome/126 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/460.0.0.0;]",
  safariIOS: `${IOS} Version/17.5 Safari/604.1`,
  chromeAndroid: "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 Chrome/126.0.0.0 Mobile Safari/537.36",
  safariMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15",
};

function makeElement(tag) {
  return {
    tagName: tag,
    dataset: {},
    style: { cssText: "" },
    hidden: false,
    textContent: "",
    innerHTML: "",
    children: [],
    listeners: {},
    attrs: {},
    setAttribute(key, value) {
      this.attrs[key] = value;
    },
    getAttribute(key) {
      return key in this.attrs ? this.attrs[key] : null;
    },
    addEventListener(type, fn) {
      (this.listeners[type] = this.listeners[type] || []).push(fn);
    },
    removeEventListener() {},
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    removeChild() {},
    querySelector() {
      return makeElement("div");
    },
    focus() {},
    select() {},
    setSelectionRange() {},
    click(event) {
      (this.listeners.click || []).forEach((fn) => fn(event));
    },
  };
}

// 모듈을 새 컨텍스트에 로드하고, 발사된 스킴과 등록된 타이머를 기록해 돌려준다.
function load(userAgent, { maxTouchPoints = 0, elements = [] } = {}) {
  const fired = [];
  const timers = [];
  const document = {
    readyState: "complete",
    hidden: false,
    head: makeElement("head"),
    body: makeElement("body"),
    createElement: makeElement,
    getElementById: () => null,
    querySelectorAll: () => elements,
    addEventListener() {},
    removeEventListener() {},
    execCommand: () => true,
  };
  const window = {
    document,
    navigator: { userAgent, maxTouchPoints, language: "ko-KR" },
    location: {
      set href(value) {
        fired.push(["location.href", value]);
      },
      get href() {
        return "https://example.test/";
      },
    },
    open: (url, target) => fired.push(["window.open", url, target]),
    setTimeout: (fn, ms) => timers.push([fn, ms]),
    clearTimeout() {},
    addEventListener() {},
    removeEventListener() {},
  };
  vm.runInNewContext(SRC, { window, module: undefined });
  return { api: window.ChargeInAppBrowser, fired, timers, document };
}

const escapeOf = (userAgent, options) => {
  const ctx = load(userAgent, options);
  const handled = ctx.api.openExternal(URL);
  return Object.assign(ctx, { handled });
};

test("T01 detect: 메타 계열 웹뷰를 UA로 가려낸다", () => {
  const ig = load(UA.igIOS).api.detect();
  assert.deepEqual([ig.isInApp, ig.isInstagram, ig.isIOS, ig.isAndroid], [true, true, true, false]);

  const threads = load(UA.threadsIOS).api.detect();
  assert.deepEqual([threads.isInApp, threads.isInstagram], [true, true], "Threads(Barcelona)도 IG로 취급");

  const fb = load(UA.fbIOS).api.detect();
  assert.deepEqual([fb.isInApp, fb.isFacebook, fb.isInstagram], [true, true, false]);

  const messenger = load(UA.messengerIOS).api.detect();
  assert.deepEqual([messenger.isFacebook, messenger.isMessenger], [true, true]);

  const android = load(UA.igAndroid).api.detect();
  assert.deepEqual([android.isInApp, android.isAndroid, android.isIOS], [true, true, false]);
});

test("T02 detect: 일반 브라우저는 인앱으로 오인하지 않는다", () => {
  assert.equal(load(UA.safariIOS).api.isInAppBrowser(), false);
  assert.equal(load(UA.chromeAndroid).api.isInAppBrowser(), false);
  assert.equal(load(UA.safariMac).api.isInAppBrowser(), false);
});

test("T03 detect: iPadOS는 데스크톱 UA로 와도 터치 포인트로 iOS 판정", () => {
  assert.equal(load(UA.safariMac, { maxTouchPoints: 5 }).api.detect().isIOS, true);
  assert.equal(load(UA.safariMac).api.detect().isIOS, false);
});

test("T04 iOS 인스타그램/Threads는 instagram://extbrowser로 탈출한다", () => {
  const ig = escapeOf(UA.igIOS);
  assert.deepEqual(ig.fired[0], ["location.href", IG_ESCAPE]);
  assert.equal(ig.handled, true);
  assert.deepEqual(escapeOf(UA.threadsIOS).fired[0], ["location.href", IG_ESCAPE]);
});

test("T05 iOS 페이스북/메신저는 window.open('x-safari-')로 탈출한다", () => {
  assert.deepEqual(escapeOf(UA.fbIOS).fired[0], ["window.open", SAFARI_ESCAPE, "_blank"]);
  assert.deepEqual(escapeOf(UA.messengerIOS).fired[0], ["window.open", SAFARI_ESCAPE, "_blank"]);
});

test("T06 안드로이드는 intent:// 로 탈출한다", () => {
  assert.deepEqual(escapeOf(UA.igAndroid).fired[0], ["location.href", INTENT_ESCAPE]);
  assert.deepEqual(escapeOf(UA.fbAndroid).fired[0], ["location.href", INTENT_ESCAPE]);
});

test("T07 일반 브라우저에서는 스킴을 쏘지 않고 링크 기본 동작에 맡긴다", () => {
  const safari = escapeOf(UA.safariIOS);
  assert.deepEqual(safari.fired, []);
  assert.equal(safari.handled, false);
});

test("T08 탈출 후 1.5초 감시 타이머를 건다", () => {
  assert.equal(escapeOf(UA.igIOS).timers[0][1], 1500);
});

test("T09 클릭 배선: 인앱만 preventDefault, 일반 브라우저는 건드리지 않는다", () => {
  const clickOn = (userAgent) => {
    const anchor = makeElement("a");
    anchor.attrs.href = URL;
    const ctx = load(userAgent, { elements: [anchor] });
    let prevented = false;
    anchor.click({ defaultPrevented: false, preventDefault: () => (prevented = true) });
    return { prevented, fired: ctx.fired, bound: anchor.dataset.inappBound };
  };

  const normal = clickOn(UA.safariIOS);
  assert.equal(normal.prevented, false);
  assert.deepEqual(normal.fired, []);

  const inApp = clickOn(UA.igIOS);
  assert.equal(inApp.prevented, true);
  assert.deepEqual(inApp.fired[0], ["location.href", IG_ESCAPE]);
  assert.equal(inApp.bound, "1");
});

test("T10 앱 전환 신호가 없으면 안내 모달을 띄운다", () => {
  const ctx = load(UA.igIOS);
  ctx.api.openExternal(URL);
  ctx.timers[0][0](); // 1.5초 감시 타임아웃 발화
  assert.equal(ctx.document.body.children.length, 1, "모달이 body에 붙는다");
  assert.equal(ctx.document.body.children[0].hidden, false);
  assert.equal(ctx.document.head.children.length, 1, "스타일이 한 번 주입된다");
});
