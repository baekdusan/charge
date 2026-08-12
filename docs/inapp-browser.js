// 인앱 브라우저 탈출 — 인스타그램/페이스북 웹뷰에서 App Store 링크가 먹통이 되는 문제를 우회한다.
// 사용법: <script src="inapp-browser.js" defer></script>
//   자동으로 a[href^="https://apps.apple.com"]와 [data-inapp-escape]에 붙는다.
//   수동 배선: ChargeInAppBrowser.bind(element) 또는 ChargeInAppBrowser.openExternal(url)
//
// 원칙 두 가지
//   1. 일반 브라우저에서는 아무것도 하지 않는다. 링크는 진짜 <a href>로 남아 App Store로 바로 간다.
//   2. 인앱 브라우저에서는 클릭 핸들러 안에서 "동기적으로" 탈출을 쏜다.
//      setTimeout이나 await 뒤로 미루면 iOS가 사용자 제스처와의 연결을 끊어 조용히 무시한다.
(function (global) {
  "use strict";

  const DEFAULT_URL = "https://apps.apple.com/app/id6796766465";
  const AUTO_SELECTOR = 'a[href^="https://apps.apple.com"], [data-inapp-escape]';
  // 탈출에 성공하면 앱이 백그라운드로 내려가며 visibilitychange/pagehide/blur가 뜬다.
  // 1.5초 안에 아무 신호도 없으면 웹뷰가 스킴을 삼킨 것으로 보고 수동 안내를 띄운다.
  const ESCAPE_TIMEOUT_MS = 1500;

  const KO = /^ko/i.test((global.navigator && global.navigator.language) || "");

  const TEXT = KO
    ? {
        title: "기본 브라우저에서 열어주세요",
        body: "인스타그램·페이스북 앱 안의 브라우저는 App Store 링크를 열지 못하게 막고 있습니다. 아래 버튼을 누르거나, 직접 기본 브라우저로 열어주세요.",
        retry: "기본 브라우저에서 열기",
        retried: "열리지 않았다면 아래 방법으로 열어주세요.",
        copy: "링크 복사",
        copied: "복사했습니다",
        copyFail: "길게 눌러 복사해 주세요",
        close: "닫기",
        stepsIOS: "화면 오른쪽 위 ••• 을 누르고 <strong>“외부 브라우저에서 열기”</strong>(또는 Safari에서 열기)를 선택하세요.",
        stepsAndroid: "화면 오른쪽 위 ⋮ 를 누르고 <strong>“다른 브라우저로 열기”</strong>를 선택하세요.",
      }
    : {
        title: "Open this in your browser",
        body: "The in-app browser in Instagram and Facebook blocks App Store links. Tap the button below, or open the link in your native browser.",
        retry: "Open in my native browser",
        retried: "Still not opening? Use the steps below.",
        copy: "Copy link",
        copied: "Copied",
        copyFail: "Press and hold to copy",
        close: "Close",
        stepsIOS: "Tap ••• at the top right, then choose <strong>“Open in external browser”</strong> (or Open in Safari).",
        stepsAndroid: "Tap ⋮ at the top right, then choose <strong>“Open in browser”</strong>.",
      };

  // ── 감지 ────────────────────────────────────────────────────────────────
  // navigator를 인자로 받게 해서 테스트에서 UA 문자열을 갈아끼울 수 있게 한다.
  function detect(nav) {
    const source = nav || global.navigator || {};
    const ua = source.userAgent || "";
    // iPadOS 13+는 자신을 데스크톱 Mac이라고 소개하므로 터치 포인트로 갈라낸다.
    const isIOS =
      /iPad|iPhone|iPod/.test(ua) ||
      (/Mac OS X|Macintosh/.test(ua) && (source.maxTouchPoints || 0) > 1);
    const isAndroid = /Android/.test(ua);
    // Threads 웹뷰는 Barcelona로 표기되지만 탈출 스킴은 인스타그램과 같다.
    const isInstagram = /Instagram|Barcelona/i.test(ua);
    const isMessenger = /Messenger/i.test(ua);
    const isFacebook = /FBAN|FBAV|FB_IAB|FB4A|FBIOS/i.test(ua) || isMessenger;
    // 메타 계열은 아니지만 같은 안내가 필요한 웹뷰들 (카카오톡·라인·네이버 등)
    const isOtherInApp = /KAKAOTALK|Line\/|NAVER|DaumApps|wv\)/i.test(ua);

    return {
      ua,
      isIOS,
      isAndroid,
      isInstagram,
      isFacebook,
      isMessenger,
      isMeta: isInstagram || isFacebook,
      isInApp: isInstagram || isFacebook || isOtherInApp,
    };
  }

  function isInAppBrowser(nav) {
    return detect(nav).isInApp;
  }

  // ── 탈출 ────────────────────────────────────────────────────────────────
  // 반드시 클릭 핸들러 안에서 동기적으로 불러야 한다. 사용한 전략 이름을 돌려주고,
  // 쏠 방법이 없으면 null을 준다 (호출부가 곧장 안내 모달을 띄운다).
  function fireEscape(url, info) {
    if (info.isIOS && info.isInstagram) {
      // 핵심. 인스타그램 앱이 이 스킴을 가로채 Safari로 넘겨준다.
      // x-safari-는 location.href로 쏘면 IG 웹뷰가 소리 없이 막아버려 여기서는 쓰지 않는다.
      global.location.href = "instagram://extbrowser/?url=" + encodeURIComponent(url);
      return "instagram-extbrowser";
    }
    if (info.isIOS && info.isFacebook) {
      global.open("x-safari-" + url, "_blank");
      return "x-safari";
    }
    if (info.isAndroid) {
      global.location.href =
        "intent://" + url.replace(/^https?:\/\//, "") + "#Intent;scheme=https;end";
      return "android-intent";
    }
    if (info.isIOS) {
      // 정체 불명의 iOS 웹뷰. 일단 x-safari-를 시도하고 실패하면 모달로 넘긴다.
      global.open("x-safari-" + url, "_blank");
      return "x-safari";
    }
    return null;
  }

  // 탈출 성공 여부를 감시한다. 앱 전환 신호가 하나라도 오면 성공, 아니면 onFail.
  function watchForExit(onFail) {
    let settled = false;

    function finish(succeeded) {
      if (settled) return;
      settled = true;
      global.clearTimeout(timer);
      global.removeEventListener("pagehide", onLeave);
      global.removeEventListener("blur", onLeave);
      global.document.removeEventListener("visibilitychange", onVisibility);
      if (!succeeded) onFail();
    }

    function onLeave() {
      finish(true);
    }
    function onVisibility() {
      if (global.document.hidden) finish(true);
    }

    const timer = global.setTimeout(function () {
      finish(false);
    }, ESCAPE_TIMEOUT_MS);

    global.addEventListener("pagehide", onLeave);
    global.addEventListener("blur", onLeave);
    global.document.addEventListener("visibilitychange", onVisibility);
  }

  // 외부에서 쓰는 진입점. 인앱이면 탈출을 쏘고 true, 일반 브라우저면 false를 준다.
  function openExternal(url) {
    const target = url || DEFAULT_URL;
    const info = detect();
    if (!info.isInApp) return false;

    const strategy = fireEscape(target, info);
    if (!strategy) {
      showModal(target, info);
      return true;
    }
    watchForExit(function () {
      showModal(target, info);
    });
    return true;
  }

  // ── 안내 모달 ───────────────────────────────────────────────────────────
  let modal = null;

  function injectStyle() {
    if (global.document.getElementById("charge-inapp-style")) return;
    const style = global.document.createElement("style");
    style.id = "charge-inapp-style";
    style.textContent = [
      ".charge-inapp{position:fixed;inset:0;z-index:2147483000;display:flex;align-items:flex-end;",
      "justify-content:center;background:rgba(0,0,0,.45);font-family:-apple-system,BlinkMacSystemFont,",
      '"Apple SD Gothic Neo",sans-serif;-webkit-tap-highlight-color:transparent}',
      ".charge-inapp[hidden]{display:none}",
      ".charge-inapp__sheet{width:100%;max-width:420px;margin:12px;padding:22px 20px 18px;border-radius:18px;",
      "background:#fff;color:#1c1c1e;box-shadow:0 18px 48px rgba(0,0,0,.28);animation:charge-inapp-up .22s ease-out}",
      "@keyframes charge-inapp-up{from{transform:translateY(16px);opacity:0}to{transform:none;opacity:1}}",
      ".charge-inapp__title{margin:0 0 8px;font-size:1.05rem;font-weight:700}",
      ".charge-inapp__body{margin:0 0 16px;font-size:.9rem;line-height:1.6;color:#3a3a3c}",
      ".charge-inapp__retry{display:block;width:100%;padding:14px;border:0;border-radius:12px;",
      "background:#b4830a;color:#fff;font-size:1rem;font-weight:600;cursor:pointer}",
      ".charge-inapp__hint{margin:12px 0 0;font-size:.82rem;color:#8e8e93}",
      ".charge-inapp__steps{margin:14px 0 0;padding:12px 14px;border-radius:12px;",
      "background:rgba(120,120,128,.12);font-size:.85rem;line-height:1.6;color:#3a3a3c}",
      ".charge-inapp__link{display:flex;gap:8px;align-items:center;margin-top:12px}",
      ".charge-inapp__url{flex:1;min-width:0;padding:10px;border:1px solid rgba(120,120,128,.3);",
      "border-radius:10px;background:transparent;color:#3a3a3c;font-size:.8rem;overflow:hidden;text-overflow:ellipsis}",
      ".charge-inapp__copy{flex:none;padding:10px 14px;border:0;border-radius:10px;",
      "background:rgba(120,120,128,.16);color:#1c1c1e;font-size:.85rem;font-weight:600;cursor:pointer}",
      ".charge-inapp__close{display:block;width:100%;margin-top:10px;padding:10px;border:0;",
      "background:none;color:#8e8e93;font-size:.85rem;cursor:pointer}",
      "@media (prefers-color-scheme:dark){",
      ".charge-inapp__sheet{background:#1c1d21;color:#f2f2f7}",
      ".charge-inapp__body,.charge-inapp__steps,.charge-inapp__url{color:#d1d1d6}",
      ".charge-inapp__retry{background:#e0b13e;color:#1c1c1e}",
      ".charge-inapp__copy{color:#f2f2f7}}",
    ].join("");
    global.document.head.appendChild(style);
  }

  function buildModal() {
    injectStyle();
    const root = global.document.createElement("div");
    root.className = "charge-inapp";
    root.setAttribute("role", "dialog");
    root.setAttribute("aria-modal", "true");
    root.hidden = true;
    root.innerHTML = [
      '<div class="charge-inapp__sheet">',
      '<h2 class="charge-inapp__title"></h2>',
      '<p class="charge-inapp__body"></p>',
      '<button type="button" class="charge-inapp__retry"></button>',
      '<p class="charge-inapp__hint" hidden></p>',
      '<div class="charge-inapp__steps"></div>',
      '<div class="charge-inapp__link">',
      '<div class="charge-inapp__url"></div>',
      '<button type="button" class="charge-inapp__copy"></button>',
      "</div>",
      '<button type="button" class="charge-inapp__close"></button>',
      "</div>",
    ].join("");

    const parts = {
      root: root,
      title: root.querySelector(".charge-inapp__title"),
      body: root.querySelector(".charge-inapp__body"),
      retry: root.querySelector(".charge-inapp__retry"),
      hint: root.querySelector(".charge-inapp__hint"),
      steps: root.querySelector(".charge-inapp__steps"),
      url: root.querySelector(".charge-inapp__url"),
      copy: root.querySelector(".charge-inapp__copy"),
      close: root.querySelector(".charge-inapp__close"),
    };

    parts.title.textContent = TEXT.title;
    parts.body.textContent = TEXT.body;
    parts.retry.textContent = TEXT.retry;
    parts.hint.textContent = TEXT.retried;
    parts.copy.textContent = TEXT.copy;
    parts.close.textContent = TEXT.close;

    parts.close.addEventListener("click", hideModal);
    root.addEventListener("click", function (event) {
      if (event.target === root) hideModal();
    });
    global.document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && !root.hidden) hideModal();
    });

    global.document.body.appendChild(root);
    return parts;
  }

  function copyToClipboard(text, button) {
    function done(ok) {
      button.textContent = ok ? TEXT.copied : TEXT.copyFail;
      global.setTimeout(function () {
        button.textContent = TEXT.copy;
      }, 1600);
    }
    if (global.navigator.clipboard && global.navigator.clipboard.writeText) {
      global.navigator.clipboard.writeText(text).then(
        function () {
          done(true);
        },
        function () {
          done(legacyCopy(text));
        }
      );
      return;
    }
    done(legacyCopy(text));
  }

  // clipboard API가 없거나 막힌 웹뷰용 폴백
  function legacyCopy(text) {
    const field = global.document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.cssText = "position:fixed;top:0;left:0;opacity:0";
    global.document.body.appendChild(field);
    field.select();
    field.setSelectionRange(0, text.length);
    let ok = false;
    try {
      ok = global.document.execCommand("copy");
    } catch (error) {
      ok = false;
    }
    global.document.body.removeChild(field);
    return ok;
  }

  function showModal(url, info) {
    if (!modal) modal = buildModal();
    modal.steps.innerHTML = info.isAndroid ? TEXT.stepsAndroid : TEXT.stepsIOS;
    modal.url.textContent = url;
    modal.hint.hidden = true;

    modal.retry.onclick = function () {
      // 재시도도 사용자 제스처 안에서 동기로 쏴야 iOS가 받아준다.
      const strategy = fireEscape(url, info);
      if (!strategy) {
        modal.hint.hidden = false;
        return;
      }
      watchForExit(function () {
        modal.hint.hidden = false;
      });
    };
    modal.copy.onclick = function () {
      copyToClipboard(url, modal.copy);
    };

    modal.root.hidden = false;
    modal.retry.focus();
  }

  function hideModal() {
    if (modal) modal.root.hidden = true;
  }

  // ── 배선 ────────────────────────────────────────────────────────────────
  function bind(element) {
    if (!element || element.dataset.inappBound === "1") return;
    element.dataset.inappBound = "1";
    element.addEventListener("click", function (event) {
      if (event.defaultPrevented) return;
      const url =
        element.dataset.inappUrl || element.getAttribute("href") || DEFAULT_URL;
      // 일반 브라우저면 여기서 손을 떼고 <a href> 기본 동작에 맡긴다.
      if (!detect().isInApp) return;
      event.preventDefault();
      openExternal(url);
    });
  }

  function init(options) {
    const selector = (options && options.selector) || AUTO_SELECTOR;
    const nodes = global.document.querySelectorAll(selector);
    for (let i = 0; i < nodes.length; i += 1) bind(nodes[i]);
  }

  const api = {
    APP_STORE_URL: DEFAULT_URL,
    detect: detect,
    isInAppBrowser: isInAppBrowser,
    openExternal: openExternal,
    bind: bind,
    init: init,
  };

  global.ChargeInAppBrowser = api;
  if (typeof module === "object" && module.exports) module.exports = api;

  if (global.document.readyState === "loading") {
    global.document.addEventListener("DOMContentLoaded", function () {
      init();
    });
  } else {
    init();
  }
})(typeof window !== "undefined" ? window : this);
