import type { Api, Model } from "@earendil-works/pi-ai";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import type { RealtimeSummarizerCompleter } from "./realtime-output-summarizer.js";

/** Resolves the apiKey for a given pi-ai provider just-in-time, so the
 *  summarizer can pick up a freshly minted Codex OAuth access token (the
 *  realtime runtime rotates it) or whichever apiKey the user typed into
 *  Picky settings on the previous turn. Returning undefined falls back to
 *  the env-var chain inside pi-ai. */
export type RealtimeSummarizerApiKeyResolver = (provider: string) => Promise<string | undefined> | string | undefined;

const models = builtinModels();

/** Wire a pi-ai backed completer for the realtime output summarizer.
 *  The function parses `provider/modelId`, resolves credentials, and asks
 *  pi-ai for a single non-streaming assistant text turn. */
export function createPiAiCompleter(options?: { resolveApiKey?: RealtimeSummarizerApiKeyResolver }): RealtimeSummarizerCompleter {
  return async ({ model, systemPrompt, userPrompt, signal }) => {
    const parsed = parseProviderModel(model);
    if (!parsed) throw new Error(`Invalid summarizer model id: ${model}`);
    const resolvedModel = resolveModel(parsed.provider, parsed.modelId);
    const apiKey = await resolveApiKey(parsed.provider, options?.resolveApiKey);
    const assistant = await models.completeSimple(
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
  const model = models.getModel(provider, modelId);
  if (!model) throw new Error(`Unknown summarizer model id: ${provider}/${modelId}`);
  return model;
}

async function resolveApiKey(provider: string, resolver?: RealtimeSummarizerApiKeyResolver): Promise<string | undefined> {
  if (resolver) {
    const fromResolver = await resolver(provider);
    if (fromResolver?.trim()) return fromResolver.trim();
  }
  return undefined;
}
