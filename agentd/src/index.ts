const minimumSupportedNodeVersion = "22.19.0";
const unsupportedNodeToken = "PICKY_UNSUPPORTED_NODE";

function parseNodeVersion(version: string): number[] {
  return version
    .trim()
    .replace(/^[vV]/, "")
    .split(".")
    .map((part) => {
      const digits = part.match(/^\d+/)?.[0];
      return digits ? Number.parseInt(digits, 10) : 0;
    });
}

function isNodeVersionAtLeast(candidate: string, required: string): boolean {
  const candidateParts = parseNodeVersion(candidate);
  const requiredParts = parseNodeVersion(required);
  const length = Math.max(candidateParts.length, requiredParts.length);
  for (let index = 0; index < length; index += 1) {
    const lhs = candidateParts[index] ?? 0;
    const rhs = requiredParts[index] ?? 0;
    if (lhs !== rhs) return lhs > rhs;
  }
  return true;
}

const currentNodeVersion = process.versions.node;
if (!isNodeVersionAtLeast(currentNodeVersion, minimumSupportedNodeVersion)) {
  process.stderr.write(
    `${unsupportedNodeToken}:${currentNodeVersion}:required=${minimumSupportedNodeVersion}\n`,
  );
  process.exit(2);
}

await import("./main.js");
