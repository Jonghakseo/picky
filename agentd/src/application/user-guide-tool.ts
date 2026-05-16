import { access, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { sliceUtf16Safe } from "../domain/safe-truncate.js";

export const READ_PICKY_USER_GUIDE_TOOL_NAME = "read_picky_user_guide";

const USER_GUIDE_RELATIVE_PATH = "docs/user-manual.md";
const QUERY_EXCERPT_CHAR_LIMIT = 12_000;
const FALLBACK_EXCERPT_CHAR_LIMIT = 6_000;

export const PICKY_USER_GUIDE_SECTIONS = [
  "1. First launch and prerequisites",
  "2. Menu bar companion panel",
  "3. Global shortcuts",
  "4. Push-to-Talk voice input",
  "5. Quick Input text input",
  "6. Drawing screen highlights",
  "7. Pickle HUD and dock",
  "8. Pickle conversation card",
  "9. Pickle menus",
  "10. HUD keyboard shortcuts",
  "11. Pi terminal overlay and inline terminal",
  "12. Report viewer",
  "13. Settings reference",
  "14. Common workflows",
] as const;

const USER_GUIDE_SECTIONS_DESCRIPTION = `Available sections: ${PICKY_USER_GUIDE_SECTIONS.join("; ")}.`;

/**
 * Deep-link routes the Picky app understands when it sees a `picky://...` URL
 * inside an assistant message. The path after the scheme is matched exactly,
 * so keep these in sync with `PickyDeepLink` on the Swift side. Each entry is
 * `[path, human-friendly description]` — the description is only used to
 * teach the LLM which screen each route opens.
 */
export const PICKY_DEEP_LINK_ROUTES: ReadonlyArray<readonly [string, string]> = [
  ["picky://panel/status", "Menu bar panel → Status tab (permissions, prerequisites, feedback entry)."],
  ["picky://panel/messages", "Menu bar panel → Messages tab (main-agent chat with Picky)."],
  ["picky://panel/settings", "Menu bar panel → Settings tab index."],
  ["picky://settings/general", "Settings → General (language, appearance, default cwd)."],
  ["picky://settings/mainAgent", "Settings → Picky main agent (runtime, model, screen context)."],
  ["picky://settings/pickle", "Settings → Pickle agent (model, reasoning level, HUD dock size)."],
  ["picky://settings/notification", "Settings → Notifications."],
  ["picky://settings/cursorBubbles", "Settings → Cursor & speech bubbles."],
  ["picky://settings/voice", "Settings → Voice (speech provider, Realtime)."],
  ["picky://settings/shortcuts", "Settings → Global shortcuts (Push-to-Talk, Quick Input)."],
  ["picky://settings/onboarding", "Settings → Onboarding replay (hidden index entry)."],
] as const;

const PICKY_DEEP_LINK_GUIDANCE = [
  "picky:// auto-open links: Picky auto-opens the panel for the FIRST `[label](picky://...)` markdown link in your reply the moment it is shown — no click. Treat the link as a side-effect, never as a UI affordance: do not write 'click here', 'go here', or any equivalent CTA in any language.",
  "Routes (do not invent others):",
  ...PICKY_DEEP_LINK_ROUTES.map(([path]) => `  - \`${path}\``),
  "Rules: (1) embed inline on the screen name, never as a trailing line; (2) at most one link per response — only the first opens, mention other screens in plain prose; (3) when the user asks where a setting lives, how to configure something, or whether a setting exists, include exactly one matching settings/panel link whenever a registered route applies; (4) TTS strips `(picky://...)`, so make the bracketed label the natural screen name.",
  "Example: Pick your provider under [Voice, STT and TTS](picky://settings/voice) and swap the matching model field.",
].join("\n");

export interface PickyUserGuideRequest {
  section?: string;
  query?: string;
}

export interface PickyUserGuideResult {
  section?: string;
  query?: string;
  path: string;
  content: string;
  totalChars: number;
  excerpted: boolean;
}

interface ReadUserGuideOptions {
  env?: NodeJS.ProcessEnv;
  cwd?: string;
  moduleUrl?: string;
}

export function createReadPickyUserGuideTool(onRead: (request: PickyUserGuideRequest) => Promise<PickyUserGuideResult> = readPickyUserGuide): ToolDefinition {
  return defineTool({
    name: READ_PICKY_USER_GUIDE_TOOL_NAME,
    label: "Read Picky user guide",
    description: `Read Picky's bundled user manual so you can answer questions about Picky usage, menus, shortcuts, settings, Push-to-Talk, Quick Input, HUD, and Pickles. ${USER_GUIDE_SECTIONS_DESCRIPTION}\n\n${PICKY_DEEP_LINK_GUIDANCE}`,
    promptSnippet: `${READ_PICKY_USER_GUIDE_TOOL_NAME}: read Picky's bundled user manual before answering questions about how to use Picky. Sections: ${PICKY_USER_GUIDE_SECTIONS.join("; ")}. When the user asks where a setting lives, how to configure something, or whether a setting exists, weave exactly one matching \`[label](picky://...)\` link from the registry INLINE on the screen's name whenever a registered route applies — Picky auto-opens that panel as soon as the reply is shown, so never write 'click', 'tap', 'go here', or any other CTA (in any language) around the link.`,
    promptGuidelines: [
      `Call ${READ_PICKY_USER_GUIDE_TOOL_NAME} before answering any Picky usage question.`,
      "Prefer exact `section` title when it maps to a listed section.",
      "Use `query` for fuzzy/cross-section questions; combine with `section` when both apply.",
      "Answer from returned content; if not covered, say the manual does not specify it.",
    ],
    parameters: Type.Object({
      section: Type.Optional(Type.String({ description: `Optional exact manual section title or number to read. ${USER_GUIDE_SECTIONS_DESCRIPTION}` })),
      query: Type.Optional(Type.String({ description: "The user's Picky usage question or topic, e.g. Push-to-Talk, Quick Input, settings, Pickle controls. Used for relevant excerpts when section is omitted, or as context when section is provided." })),
    }),
    execute: async (_toolCallId, params) => {
      const result = await onRead({ section: normalizeOptionalString(params.section), query: normalizeOptionalString(params.query) });
      return {
        content: [{ type: "text", text: formatUserGuideToolOutput(result) }],
        details: {
          section: result.section,
          query: result.query,
          path: result.path,
          totalChars: result.totalChars,
          excerpted: result.excerpted,
        },
      };
    },
  });
}

export async function readPickyUserGuide(request: PickyUserGuideRequest = {}, options: ReadUserGuideOptions = {}): Promise<PickyUserGuideResult> {
  const guidePath = await resolvePickyUserGuidePath(options);
  const fullContent = await readFile(guidePath, "utf8");
  const requestedSection = normalizeOptionalString(request.section);
  const query = normalizeOptionalString(request.query);
  const sectionResult = requestedSection ? extractGuideSection(fullContent, requestedSection) : undefined;
  const content = sectionResult?.content ?? (query ? excerptGuideForQuery(fullContent, query) : fullContent);
  return {
    section: sectionResult?.section,
    query,
    path: guidePath,
    content,
    totalChars: fullContent.length,
    excerpted: content.length < fullContent.length,
  };
}

async function resolvePickyUserGuidePath(options: ReadUserGuideOptions): Promise<string> {
  const candidates = userGuidePathCandidates(options);
  for (const candidate of candidates) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next candidate.
    }
  }
  throw new Error(`Picky user guide not found. Checked: ${candidates.join(", ")}`);
}

function userGuidePathCandidates(options: ReadUserGuideOptions): string[] {
  const env = options.env ?? process.env;
  const cwd = options.cwd ?? process.cwd();
  const moduleDir = dirname(fileURLToPath(options.moduleUrl ?? import.meta.url));
  const candidates = [
    env.PICKY_USER_GUIDE_PATH,
    // Packaged runtime: Picky.app/Contents/Resources/agentd/docs/user-manual.md
    join(cwd, USER_GUIDE_RELATIVE_PATH),
    // Development source runtime: repo/agentd -> repo/docs/user-manual.md
    join(cwd, "..", USER_GUIDE_RELATIVE_PATH),
    // Compiled runtime relative to dist/application/user-guide-tool.js.
    join(moduleDir, "..", "..", USER_GUIDE_RELATIVE_PATH),
    // tsx development runtime relative to src/application/user-guide-tool.ts.
    join(moduleDir, "..", "..", "..", USER_GUIDE_RELATIVE_PATH),
  ].filter((value): value is string => Boolean(value && value.trim()));
  return Array.from(new Set(candidates.map((candidate) => resolve(candidate))));
}

function extractGuideSection(content: string, requestedSection: string): { section: string; content: string } {
  const sections = splitTopLevelSections(content);
  const requested = normalizeSectionKey(requestedSection);
  const match = sections.find((section) => {
    const key = normalizeSectionKey(section.title);
    const number = section.title.match(/^(\d+)\./)?.[1];
    return key === requested || number === requested || key.includes(requested);
  });
  if (!match) {
    throw new Error(`Unknown Picky user guide section: ${requestedSection}. ${USER_GUIDE_SECTIONS_DESCRIPTION}`);
  }
  return { section: match.title, content: match.text.trim() };
}

interface TopLevelSection {
  title: string;
  text: string;
}

function splitTopLevelSections(content: string): TopLevelSection[] {
  const lines = content.split(/\r?\n/);
  const sections: TopLevelSection[] = [];
  let title = "";
  let current: string[] = [];

  const flush = () => {
    if (!title || current.length === 0) return;
    sections.push({ title, text: current.join("\n") });
  };

  for (const line of lines) {
    const match = line.match(/^##\s+(.+)$/);
    if (match) {
      flush();
      title = match[1].trim();
      current = [line];
    } else if (title) {
      current.push(line);
    }
  }
  flush();
  return sections;
}

function normalizeSectionKey(value: string): string {
  return value.toLocaleLowerCase().replace(/^##\s+/, "").replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

function excerptGuideForQuery(content: string, query: string): string {
  const sections = splitMarkdownSections(content);
  const tokens = queryTokens(query);
  const scored = sections
    .map((section, index) => ({ section, index, score: scoreSection(section, query, tokens) }))
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score || a.index - b.index);

  const title = sections[0]?.heading === "# Picky User Manual" ? sections[0].text.trim() : "# Picky User Manual";
  const selected: string[] = [title, `> Excerpts matching query: ${query}`];
  let chars = selected.join("\n\n").length;

  const entries = scored.length > 0 ? scored : sections.slice(1, 4).map((section, index) => ({ section, index, score: 0 }));
  for (const { section } of entries) {
    const text = section.text.trim();
    if (!text || selected.includes(text)) continue;
    const projected = chars + text.length + 2;
    if (projected > QUERY_EXCERPT_CHAR_LIMIT) {
      const remaining = QUERY_EXCERPT_CHAR_LIMIT - chars - 80;
      if (remaining > 500) selected.push(`${sliceUtf16Safe(text, remaining)}\n…`);
      break;
    }
    selected.push(text);
    chars = projected;
  }

  if (scored.length === 0) {
    selected.splice(1, 1, `> No exact guide section matched query: ${query}. Showing the opening sections instead.`);
  }

  const excerpt = selected.join("\n\n").trim();
  return excerpt || sliceUtf16Safe(content, FALLBACK_EXCERPT_CHAR_LIMIT);
}

interface MarkdownSection {
  heading: string;
  text: string;
}

function splitMarkdownSections(content: string): MarkdownSection[] {
  const lines = content.split(/\r?\n/);
  const sections: MarkdownSection[] = [];
  let currentHeading = "";
  let currentLines: string[] = [];

  const flush = () => {
    if (currentLines.length === 0) return;
    sections.push({ heading: currentHeading, text: currentLines.join("\n") });
  };

  for (const line of lines) {
    if (/^#{1,3}\s+/.test(line) && currentLines.length > 0) {
      flush();
      currentHeading = line.trim();
      currentLines = [line];
    } else {
      if (!currentHeading && /^#{1,3}\s+/.test(line)) currentHeading = line.trim();
      currentLines.push(line);
    }
  }
  flush();
  return sections;
}

function scoreSection(section: MarkdownSection, query: string, tokens: string[]): number {
  const haystack = section.text.toLocaleLowerCase();
  const heading = section.heading.toLocaleLowerCase();
  const normalizedQuery = query.toLocaleLowerCase();
  let score = 0;
  if (haystack.includes(normalizedQuery)) score += 20;
  if (heading.includes(normalizedQuery)) score += 30;
  for (const token of tokens) {
    if (token.length < 2) continue;
    if (heading.includes(token)) score += 6;
    if (haystack.includes(token)) score += 2;
  }
  return score;
}

function queryTokens(query: string): string[] {
  return Array.from(new Set(query.toLocaleLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}_-]*/gu) ?? []));
}

function formatUserGuideToolOutput(result: PickyUserGuideResult): string {
  const scope = result.section ? `section: ${result.section}` : result.excerpted ? "excerpt" : "full guide";
  const query = result.query ? ` for query: ${result.query}` : "";
  return [
    `Picky user manual ${scope}${query}`,
    `Path: ${result.path}`,
    `Total guide chars: ${result.totalChars}`,
    "",
    result.content,
  ].join("\n");
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}
