import { describe, expect, it } from "vitest";
import { EdgeTTSService } from "./edge-tts-service.js";

// This reaches Microsoft's unofficial Edge Read Aloud endpoint. It is excluded
// from normal test runs and exists only as an operator-run compatibility smoke.
describe.skipIf(process.env.PICKY_EDGE_TTS_LIVE_TEST !== "1")("Edge TTS live smoke", () => {
  it("lists voices and synthesizes a generic Korean phrase", async () => {
    const service = new EdgeTTSService();
    const voices = await service.listVoices();
    expect(voices.some((voice) => voice.shortName === "ko-KR-SunHiNeural")).toBe(true);

    const audio = await service.synthesize("안녕하세요.", "ko-KR-SunHiNeural");
    expect(audio.length).toBeGreaterThan(0);
  }, 45_000);
});
