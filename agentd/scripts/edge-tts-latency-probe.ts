import { MsEdgeTTS, OUTPUT_FORMAT } from "msedge-tts";
import { performance } from "node:perf_hooks";
import { escapeSSMLText } from "../src/edge-tts-service.js";

// Splits Edge synthesis latency (time-to-first-audio-byte) from buffering
// latency (first byte -> last byte), and compares a fresh client per sentence
// (pre-#1 behavior) against one reused warm connection (post-#1 pooling).

const VOICE = process.env.PROBE_VOICE ?? "ko-KR-SunHiNeural";
const FORMAT = OUTPUT_FORMAT.AUDIO_24KHZ_48KBITRATE_MONO_MP3;

const sentences = [
  "오늘은 바깥 공기를 느끼며 가볍게 하루를 시작하기 좋은 날이에요.",
  "따뜻한 커피 한 잔으로 잠깐의 여유를 가져보세요.",
  "좋은 저녁 보내세요!",
];

interface Mark { connectMetaMs: number; ttfbMs: number; tailMs: number; totalMs: number; bytes: number; }

function collect(client: MsEdgeTTS, text: string, tStart: number, tMeta: number): Promise<Mark> {
  const { audioStream } = client.toStream(escapeSSMLText(text));
  return new Promise<Mark>((resolve, reject) => {
    let tFirst = -1;
    let bytes = 0;
    audioStream.on("data", (chunk: Buffer) => {
      if (tFirst < 0) tFirst = performance.now();
      bytes += Buffer.from(chunk).length;
    });
    audioStream.once("error", reject);
    audioStream.once("end", () => {
      const tEnd = performance.now();
      resolve({ connectMetaMs: tMeta - tStart, ttfbMs: tFirst - tMeta, tailMs: tEnd - tFirst, totalMs: tEnd - tStart, bytes });
    });
  });
}

// Fresh client per sentence: pays the WS handshake + metadata every time.
async function freshRun(): Promise<Mark[]> {
  const marks: Mark[] = [];
  for (const text of sentences) {
    const client = new MsEdgeTTS();
    const t0 = performance.now();
    await client.setMetadata(VOICE, FORMAT);
    const tMeta = performance.now();
    marks.push(await collect(client, text, t0, tMeta));
    client.close();
  }
  return marks;
}

// Pooled: one warm client reused for all sentences (mirrors EdgeTTSService pool).
// setMetadata runs once; reuse skips it (and msedge-tts throws on a 2nd call).
async function pooledRun(): Promise<Mark[]> {
  const marks: Mark[] = [];
  const client = new MsEdgeTTS();
  let configured = false;
  for (const text of sentences) {
    const t0 = performance.now();
    if (!configured) { await client.setMetadata(VOICE, FORMAT); configured = true; }
    const tMeta = performance.now();
    marks.push(await collect(client, text, t0, tMeta));
  }
  client.close();
  return marks;
}

function fmt(n: number): string { return n.toFixed(1).padStart(7); }
function sum(v: number[]): number { return v.reduce((a, b) => a + b, 0); }

async function main() {
  const runs = Number(process.env.PROBE_RUNS ?? "3");
  console.log(`voice=${VOICE} sentences=${sentences.length} runs=${runs}\n`);

  for (const [label, fn] of [["FRESH per sentence (pre-#1)", freshRun], ["POOLED reuse (post-#1)", pooledRun]] as const) {
    // median across runs of the aggregate metrics
    const totals: number[] = [];
    const firstTtfa: number[] = [];
    const connectSums: number[] = [];
    let lastMarks: Mark[] = [];
    for (let r = 0; r < runs; r++) {
      const marks = await fn();
      lastMarks = marks;
      totals.push(sum(marks.map((m) => m.totalMs)));
      firstTtfa.push(marks[0].connectMetaMs + marks[0].ttfbMs);
      connectSums.push(sum(marks.map((m) => m.connectMetaMs)));
    }
    const median = (v: number[]) => v.slice().sort((a, b) => a - b)[Math.floor(v.length / 2)];
    console.log(`== ${label} ==`);
    lastMarks.forEach((m, i) => {
      console.log(`   S${i + 1}: connect+meta=${fmt(m.connectMetaMs)}  synth=${fmt(m.ttfbMs)}  buffer=${fmt(m.tailMs)}  total=${fmt(m.totalMs)}`);
    });
    console.log(`   -> TTFA(S1)=${fmt(median(firstTtfa))}ms  handshake sum=${fmt(median(connectSums))}ms  wall(all 3)=${fmt(median(totals))}ms  (median of ${runs})\n`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
