/**
 * Answers the demo transport gives to queries and file requests.
 *
 * Demo mode runs with no Mac behind it, so anything the gateway would fetch
 * from the daemon is produced here: runtime options for the settings sheet, a
 * small diff for the work panel, and the bytes of a tool image.
 */
import type { RemoteQuery } from "../../../src/remote/protocol";

export const IMAGE_PATH = /\.(png|jpe?g|gif|webp)$/i;

const DEMO_DIFF = `@@ -18,7 +18,11 @@ export function schedule(at: Date): void {
-  queue.push({ at });
+  queue.push({ at, attempts: 0 });
+  if (queue.length > MAX_QUEUE) {
+    queue.shift();
+  }
   notify();
 }
`;

const DEMO_DIFF_SECOND = `@@ -4,3 +4,4 @@
 # 변경 기록
 
 - 재시도 간격을 지수형으로 바꿨어요
+- 큐 길이에 상한을 뒀어요
`;

/** `undefined` means "the demo cannot answer this", which the transport reports as unsupported. */
export function demoQueryResult(query: RemoteQuery): unknown {
  switch (query.type) {
    case "session.runtimeOptions":
      return {
        models: [
          { provider: "anthropic", modelId: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", fastModeSupported: true },
          { provider: "openai", modelId: "gpt-5-codex", displayName: "GPT-5 Codex" },
        ],
        thinkingLevels: ["off", "low", "medium", "high", "max"],
      };
    case "session.diff":
      return {
        sessionId: query.sessionId,
        view: query.view,
        isGitRepo: true,
        filesTruncated: false,
        files:
          query.view === "staged"
            ? [
                {
                  path: "CHANGELOG.md",
                  status: "modified",
                  additions: 1,
                  deletions: 0,
                  diff: DEMO_DIFF_SECOND,
                  truncated: false,
                },
              ]
            : [
                {
                  path: "agentd/src/queue/schedule.ts",
                  status: "modified",
                  additions: 4,
                  deletions: 1,
                  diff: DEMO_DIFF,
                  truncated: false,
                },
                {
                  path: "docs/release-notes.md",
                  status: "added",
                  additions: 1,
                  deletions: 0,
                  diff: DEMO_DIFF_SECOND,
                  truncated: false,
                },
              ],
      };
  }
}

/**
 * A placeholder picture for a tool image or a file preview. Drawn on a canvas
 * so the demo ships no binary assets; the caller caches the result per path.
 */
export function drawDemoImage(path: string): string {
  const width = 1200;
  const height = 750;
  const canvas = typeof document === "undefined" ? null : document.createElement("canvas");
  const context = canvas?.getContext("2d") ?? null;
  if (!canvas || !context) return `/api/files/raw?path=${encodeURIComponent(path)}`;
  canvas.width = width;
  canvas.height = height;

  const sky = context.createLinearGradient(0, 0, 0, height);
  sky.addColorStop(0, "#1d2a44");
  sky.addColorStop(1, "#4a6fa5");
  context.fillStyle = sky;
  context.fillRect(0, 0, width, height);

  context.fillStyle = "rgba(255, 255, 255, 0.85)";
  context.beginPath();
  context.arc(width * 0.78, height * 0.24, 54, 0, Math.PI * 2);
  context.fill();

  context.fillStyle = "#24364f";
  context.beginPath();
  context.moveTo(0, height * 0.72);
  context.lineTo(width * 0.28, height * 0.38);
  context.lineTo(width * 0.52, height * 0.72);
  context.closePath();
  context.fill();

  context.fillStyle = "#172536";
  context.beginPath();
  context.moveTo(width * 0.34, height * 0.74);
  context.lineTo(width * 0.64, height * 0.3);
  context.lineTo(width, height * 0.74);
  context.closePath();
  context.fill();

  context.fillStyle = "#0f1a27";
  context.fillRect(0, height * 0.72, width, height * 0.28);

  context.fillStyle = "rgba(255, 255, 255, 0.72)";
  context.font = "28px -apple-system, system-ui, sans-serif";
  context.fillText(path.split("/").pop() ?? path, 32, height - 36);

  return canvas.toDataURL("image/png");
}
