// VoiceBabel — i18n loader + fade-in observer + language picker. Vanilla JS, no deps.
(function () {
  "use strict";

  const SUPPORTED = [
    { code: "en", label: "English" },
    { code: "zh-CN", label: "\u7B80\u4F53\u4E2D\u6587" }
  ];
  const STORAGE_KEY = "voicebabel_lang";
  const DEFAULT_LANG = "en";

  function resolveLang() {
    const params = new URLSearchParams(window.location.search);
    const fromUrl = params.get("lang");
    if (fromUrl && SUPPORTED.some(l => l.code === fromUrl)) return fromUrl;

    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored && SUPPORTED.some(l => l.code === stored)) return stored;

    const navLang = (navigator.language || "").toLowerCase();
    for (const l of SUPPORTED) {
      if (navLang === l.code.toLowerCase()) return l.code;
    }
    const prefix = navLang.split("-")[0];
    for (const l of SUPPORTED) {
      if (l.code.toLowerCase().split("-")[0] === prefix) return l.code;
    }
    return DEFAULT_LANG;
  }

  function getByPath(obj, path) {
    if (!obj) return undefined;
    return path.split(".").reduce((acc, key) => (acc == null ? undefined : acc[key]), obj);
  }

  async function fetchPack(code) {
    try {
      const res = await fetch("i18n/" + code + ".json", { cache: "no-cache" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      return await res.json();
    } catch (err) {
      console.warn("[i18n] failed to load", code, err);
      return null;
    }
  }

  function applyPack(primary, fallback) {
    const lookup = (key) => {
      const v = getByPath(primary, key);
      if (v != null && v !== "") return v;
      return getByPath(fallback, key);
    };

    document.querySelectorAll("[data-i18n]").forEach(node => {
      const key = node.getAttribute("data-i18n");
      const value = lookup(key);
      if (value == null) return;
      const attrTarget = node.getAttribute("data-i18n-attr");
      if (attrTarget) { node.setAttribute(attrTarget, value); return; }
      if (node.hasAttribute("data-i18n-html")) { node.innerHTML = value; return; }
      node.textContent = value;
    });
  }

  function buildLangMenu(current) {
    const menu = document.getElementById("lang-menu");
    if (!menu) return;
    menu.innerHTML = "";
    SUPPORTED.forEach(l => {
      const li = document.createElement("li");
      const btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = l.label;
      btn.setAttribute("data-lang", l.code);
      if (l.code === current) btn.setAttribute("aria-current", "true");
      btn.addEventListener("click", () => {
        localStorage.setItem(STORAGE_KEY, l.code);
        const url = new URL(window.location.href);
        url.searchParams.set("lang", l.code);
        window.location.href = url.toString();
      });
      li.appendChild(btn);
      menu.appendChild(li);
    });
  }

  function wireLangPicker() {
    const btn = document.getElementById("lang-btn");
    const menu = document.getElementById("lang-menu");
    if (!btn || !menu) return;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const open = !menu.hasAttribute("hidden");
      if (open) { menu.setAttribute("hidden", ""); btn.setAttribute("aria-expanded", "false"); }
      else      { menu.removeAttribute("hidden");   btn.setAttribute("aria-expanded", "true"); }
    });
    document.addEventListener("click", (e) => {
      if (!menu.contains(e.target) && e.target !== btn) {
        menu.setAttribute("hidden", "");
        btn.setAttribute("aria-expanded", "false");
      }
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { menu.setAttribute("hidden", ""); btn.setAttribute("aria-expanded", "false"); }
    });
  }

  function setCurrentLangLabel(code) {
    const el = document.getElementById("lang-current");
    if (el) el.textContent = code.split("-")[0].toUpperCase();
  }

  function setupObserver() {
    if (!("IntersectionObserver" in window)) {
      document.querySelectorAll(".feature, .step").forEach(n => n.classList.add("in-view"));
      return;
    }
    const io = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.add("in-view");
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.15 });
    document.querySelectorAll(".feature, .step").forEach(n => io.observe(n));
  }

  async function init() {
    const lang = resolveLang();
    document.documentElement.lang = lang;
    setCurrentLangLabel(lang);
    buildLangMenu(lang);
    wireLangPicker();

    const [primary, fallback] = await Promise.all([
      fetchPack(lang),
      lang === DEFAULT_LANG ? Promise.resolve(null) : fetchPack(DEFAULT_LANG)
    ]);
    applyPack(primary || fallback, fallback || primary);
    setupObserver();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
