/**
 * team-agent-models — dynamically discover models from the team-agent proxy.
 *
 * Fetches GET {baseUrl}/models at startup and registers them as provider
 * "team-agent". Per-model parameters (contextWindow, thinkingLevelMap, etc.)
 * are loaded from team-agent-models.config.json (same directory).
 *
 * Override the endpoint/key with env vars:
 *   TEAM_AGENT_BASE_URL (default https://api-gpt2.team-agent.net/v1)
 *   TEAM_AGENT_API_KEY
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const BASE_URL = process.env.TEAM_AGENT_BASE_URL ?? "https://api-gpt2.team-agent.net/v1";
const API_KEY =
  process.env.TEAM_AGENT_API_KEY ?? undefined;

const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

// --- Config loading ---

type ThinkingLevelMap = Record<string, string | null>;

interface ModelOverride {
  name?: string;
  contextWindow?: number;
  maxTokens?: number;
  image?: ("text" | "image")[];
  reasoning?: boolean;
  thinkingLevelMap?: ThinkingLevelMap;
}

interface Config {
  defaults: {
    contextWindow: number;
    maxTokens: number;
    thinkingLevelMap: ThinkingLevelMap;
  };
  models: Record<string, ModelOverride>;
}

function loadConfig(): Config {
  const dir = dirname(fileURLToPath(import.meta.url));
  const raw = readFileSync(join(dir, "team-agent-models.config.json"), "utf-8");
  return JSON.parse(raw) as Config;
}

// --- Heuristics for capabilities not set in config ---

function detectImageSupport(id: string): boolean {
  const lower = id.toLowerCase();
  return /^(gpt-(5|6|image)|claude|gemini|qwen)/.test(lower);
}

function detectReasoning(id: string): boolean {
  const lower = id.toLowerCase();
  return (
    /^gpt-(5|6)\b/.test(lower) ||
    lower.includes("thinking") ||
    /^claude/.test(lower) ||
    /^gemini[ -]3/.test(lower) ||
    /^deepseek-v4/.test(lower) ||
    /^qwen3\.8/.test(lower)
  );
}

function detectContextWindow(id: string): number | undefined {
  const lower = id.toLowerCase();
  if (lower === "gemini-3.8-flash-high" || /^gemini[ -]3\.8[ -]flash/.test(lower)) {
    return 1000000;
  }
  return undefined;
}

// --- Model construction ---

type ModelDef = {
  id: string;
  name: string;
  api: "openai-completions";
  reasoning: boolean;
  input: ("text" | "image")[];
  cost: typeof ZERO_COST;
  contextWindow: number;
  maxTokens: number;
  thinkingLevelMap?: ThinkingLevelMap;
  compat?: { supportsReasoningEffort?: boolean };
};

function toModel(id: string, config: Config): ModelDef {
  // Proxy returns mixed-case ids (e.g. "Gemini 3.8 Flash"); config keys are
  // matched case-insensitively against the lowercased id.
  const override = config.models[id.toLowerCase()] ?? {};

  const model: ModelDef = {
    id,
    name: override.name ?? id,
    api: "openai-completions",
    reasoning: override.reasoning ?? detectReasoning(id),
    input: override.image ?? (detectImageSupport(id) ? ["text", "image"] : ["text"]),
    cost: ZERO_COST,
    contextWindow: override.contextWindow ?? detectContextWindow(id) ?? config.defaults.contextWindow,
    maxTokens: override.maxTokens ?? (detectContextWindow(id) ? 65536 : undefined) ?? config.defaults.maxTokens,
    compat: { supportsReasoningEffort: true },
  };

  model.thinkingLevelMap = override.thinkingLevelMap ?? config.defaults.thinkingLevelMap;

  return model;
}

// --- Entry point ---

export default async function (pi: ExtensionAPI) {
  let config: Config;
  try {
    config = loadConfig();
  } catch (e) {
    console.error("[team-agent-models] failed to load config, using fallback:", e);
    config = {
      defaults: {
        contextWindow: 200000,
        maxTokens: 32768,
        thinkingLevelMap: {
          off: "none", minimal: "low", low: "low", medium: "medium",
          high: "high", xhigh: "high", max: "high",
        },
      },
      models: {
        "gemini-3.8-flash-high": {
          contextWindow: 1000000,
          maxTokens: 65536,
        },
      },
    };
  }

  let ids: string[] = [];
  try {
    const res = await fetch(`${BASE_URL}/models`, {
      headers: { Authorization: `Bearer ${API_KEY}` },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const payload = (await res.json()) as { data: Array<{ id: string }> };
    ids = [...new Set(payload.data.map((m) => m.id))];
  } catch {
    ids = [];
  }

  const models = ids.length ? ids.map((id) => toModel(id, config)) : [toModel("qwen3.8-27b", config)];

  pi.registerProvider("team-agent", {
    name: "Team Agent Proxy",
    baseUrl: BASE_URL,
    apiKey: API_KEY,
    api: "openai-completions",
    compat: {
      supportsDeveloperRole: false,
      supportsReasoningEffort: true,
    },
    models,
  });
}
