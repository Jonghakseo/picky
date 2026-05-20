import { completeSimple, getEnvApiKey, getModel } from "@earendil-works/pi-ai";
import type { Api, KnownProvider, Model } from "@earendil-works/pi-ai";
import type { RealtimeSummarizerCompleter } from "./realtime-output-summarizer.js";

/** Resolves the apiKey for a given pi-ai provider just-in-time, so the
 *  summarizer can pick up a freshly minted Codex OAuth access token (the
 *  realtime runtime rotates it) or whichever apiKey the user typed into
 *  Picky settings on the previous turn. Returning undefined falls back to
 *  the env-var chain inside pi-ai. */
export type RealtimeSummarizerApiKeyResolver = (provider: string) => Promise<string | undefined> | string | undefined;

/** Wire a pi-ai backed completer for the realtime output summarizer.
 *  The function parses `provider/modelId`, resolves credentials, and asks
 *  pi-ai for a single non-streaming assistant text turn. */
export function createPiAiCompleter(options?: { resolveApiKey?: RealtimeSummarizerApiKeyResolver }): RealtimeSummarizerCompleter {
  return async ({ model, systemPrompt, userPrompt, signal }) => {
    const parsed = parseProviderModel(model);
    if (!parsed) throw new Error(`Invalid summarizer model id: ${model}`);
    const resolvedModel = resolveModel(parsed.provider, parsed.modelId);
    const apiKey = await resolveApiKey(parsed.provider, options?.resolveApiKey);
    const assistant = await completeSimple(
      resolvedModel,
      {
        systemPrompt,
        messages: [
          {
            role: "user",
            content: [{ type: "text", text: userPrompt }],
            timestamp: Date.now(),
          },
        ],
      },
      {
        signal,
        apiKey,
        reasoning: "low",
        maxTokens: 256,
      },
    );
    const textParts = assistant.content.filter((c): c is { type: "text"; text: string } => c.type === "text");
    return textParts.map((c) => c.text).join("").trim();
  };
}

interface ParsedProviderModel {
  provider: string;
  modelId: string;
}

function parseProviderModel(input: string): ParsedProviderModel | undefined {
  const trimmed = input.trim();
  if (!trimmed) return undefined;
  const slashIndex = trimmed.indexOf("/");
  if (slashIndex <= 0 || slashIndex === trimmed.length - 1) return undefined;
  return {
    provider: trimmed.slice(0, slashIndex),
    modelId: trimmed.slice(slashIndex + 1),
  };
}

function resolveModel(provider: string, modelId: string): Model<Api> {
  // getModel is strongly typed over MODELS keys; we narrow at runtime.
  return getModel(provider as KnownProvider, modelId as never) as Model<Api>;
}

async function resolveApiKey(provider: string, resolver?: RealtimeSummarizerApiKeyResolver): Promise<string | undefined> {
  if (resolver) {
    const fromResolver = await resolver(provider);
    if (fromResolver?.trim()) return fromResolver.trim();
  }
  return getEnvApiKey(provider) || undefined;
}
