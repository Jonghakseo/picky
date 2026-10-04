// Applies review parameters before first paint:
//   ?theme=light|dark  forces an appearance (default follows the system)
//   ?scale=1.3         sets the app font scale, like the Mac app's global font scale
// Inside the review board iframe, it also reports the page height so the board can
// size the frame to its content (file:// frames cannot be measured from the parent).
(() => {
  const params = new URLSearchParams(window.location.search);
  const theme = params.get("theme");
  if (theme === "light" || theme === "dark") {
    document.documentElement.dataset.theme = theme;
  }
  const scale = Number(params.get("scale"));
  if (Number.isFinite(scale) && scale > 0) {
    document.documentElement.style.setProperty("--hud-font-scale", String(scale));
  }

  if (window.parent === window) return;
  let lastHeight = 0;
  // Measure the body, not documentElement.scrollHeight: inside an iframe the latter
  // never drops below the frame's current height, so a frame could only grow.
  const report = () => {
    if (!document.body) return;
    const height = Math.ceil(document.body.getBoundingClientRect().height);
    if (height === lastHeight) return;
    lastHeight = height;
    window.parent.postMessage({ type: "picky-proto-height", height }, "*");
  };
  window.addEventListener("load", report);
  document.addEventListener("DOMContentLoaded", () => {
    new ResizeObserver(report).observe(document.body);
    report();
  });
})();
