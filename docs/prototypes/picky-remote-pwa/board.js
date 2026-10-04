// Review board wiring:
// - keeps the prototype iframes and the HUD reference images on the same appearance,
// - shows 2x gallery PNGs at their logical (half) size,
// - sizes each iframe to its content (heights arrive by postMessage from theme.js),
// - shows an "in progress" note instead of a broken frame while a part file is missing,
// - ?part=<id> shows a single part, for focused review and screenshots.
(() => {
  const GALLERY = "../../../build/render-gallery/";
  const params = new URLSearchParams(window.location.search);
  const readyParts = new Set();

  const onlyPart = params.get("part");
  if (onlyPart) {
    for (const section of document.querySelectorAll(".board-part")) {
      section.hidden = section.id !== onlyPart;
    }
  }

  const currentTheme = () => {
    const forced = document.documentElement.dataset.theme;
    if (forced === "light" || forced === "dark") return forced;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  };

  const showAtLogicalSize = (img) => {
    img.addEventListener("load", () => {
      img.style.width = `${img.naturalWidth / 2}px`;
      img.closest("figure")?.classList.remove("is-missing");
    });
    img.addEventListener("error", () => {
      img.closest("figure")?.classList.add("is-missing");
    });
  };

  const loadFrame = (frame) => {
    frame.src = `${frame.dataset.part}.html?theme=${document.documentElement.dataset.theme}`;
  };

  // file:// pages cannot fetch sibling files, but a stylesheet that does not apply
  // (media="not all") still fires load or error, which tells whether <part>.css exists.
  const probePart = (frame) => {
    const pending = document.createElement("p");
    pending.className = "board-pending";
    pending.textContent = `작업 중: ${frame.dataset.part}.html이 아직 없습니다. 파일이 생기면 새로고침하세요.`;
    frame.hidden = true;
    frame.after(pending);

    const probe = document.createElement("link");
    probe.rel = "stylesheet";
    probe.media = "not all";
    probe.href = `${frame.dataset.part}.css`;
    probe.addEventListener("load", () => {
      readyParts.add(frame.dataset.part);
      pending.remove();
      frame.hidden = false;
      loadFrame(frame);
    });
    probe.addEventListener("error", () => probe.remove());
    document.head.appendChild(probe);
  };

  window.addEventListener("message", (event) => {
    if (event.data?.type !== "picky-proto-height") return;
    for (const frame of document.querySelectorAll("iframe[data-part]")) {
      if (frame.contentWindow === event.source) {
        frame.style.height = `${event.data.height}px`;
      }
    }
  });

  const apply = (theme) => {
    document.documentElement.dataset.theme = theme;
    for (const frame of document.querySelectorAll("iframe[data-part]")) {
      if (readyParts.has(frame.dataset.part)) loadFrame(frame);
    }
    for (const img of document.querySelectorAll("img[data-src-template]")) {
      img.src = GALLERY + img.dataset.srcTemplate.replace("{theme}", theme);
    }
    for (const img of document.querySelectorAll("img[data-src-fixed]")) {
      if (!img.getAttribute("src")) img.src = GALLERY + img.dataset.srcFixed;
    }
    for (const button of document.querySelectorAll("[data-theme-choice]")) {
      button.setAttribute("aria-pressed", String(button.dataset.themeChoice === theme));
    }
  };

  document.querySelectorAll(".board-refs img").forEach(showAtLogicalSize);
  document.querySelectorAll("[data-theme-choice]").forEach((button) => {
    button.addEventListener("click", () => apply(button.dataset.themeChoice));
  });
  apply(currentTheme());
  document.querySelectorAll("iframe[data-part]").forEach(probePart);
})();
