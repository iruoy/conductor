// The reasoning level a model uses when a request names none. Neither pi-ai nor the models endpoint knows it, but
// OpenAI echoes the effective effort on every response, so one request that stops at its first event tells.
import { type Api, getSupportedThinkingLevels, type Model, type Models, type ModelThinkingLevel } from "@earendil-works/pi-ai";

const PROBE_TIMEOUT_MS = 10_000;

/** The pi level a provider's effort value stands for on this model. */
export function levelForEffort(model: Model<Api>, effort: string): ModelThinkingLevel | null {
	const native = (level: ModelThinkingLevel) => model.thinkingLevelMap?.[level] ?? (level === "off" ? "none" : level);
	return getSupportedThinkingLevels(model).find((level) => native(level) === effort) ?? null;
}

/** Null when the provider does not tell: not a reasoning model, not the Responses API, no auth, or a failed request. */
export async function probeDefaultLevel(models: Models, model: Model<Api>): Promise<ModelThinkingLevel | null> {
	if (!model.reasoning || model.api !== "openai-responses") return null;
	// The resolved auth, not the model's static metadata: a provider may derive its endpoint and headers at login.
	const auth = (await models.getAuth(model))?.auth;
	if (auth === undefined) return null;
	const headers: Record<string, string> = { "Content-Type": "application/json" };
	if (auth.apiKey !== undefined) headers.Authorization = `Bearer ${auth.apiKey}`;
	for (const [name, value] of Object.entries(auth.headers ?? {})) if (typeof value === "string") headers[name] = value;

	const abort = new AbortController();
	const timeout = setTimeout(() => abort.abort(), PROBE_TIMEOUT_MS);
	try {
		const response = await fetch(`${auth.baseUrl ?? model.baseUrl}/responses`, {
			method: "POST",
			signal: abort.signal,
			headers,
			body: JSON.stringify({
				model: model.id,
				input: [{ role: "user", content: [{ type: "input_text", text: "hi" }] }],
				stream: true,
				store: false,
			}),
		});
		if (!response.ok || response.body === null) return null;

		// The first event, `response.created`, already carries the response with its effective reasoning.
		const decoder = new TextDecoder();
		let text = "";
		for await (const chunk of response.body) {
			text += decoder.decode(chunk, { stream: true });
			const end = text.indexOf("\n\n");
			if (end === -1) continue;
			const data = text.slice(0, end).split("\n").find((line) => line.startsWith("data:"));
			const effort = data === undefined ? undefined : JSON.parse(data.slice(5)).response?.reasoning?.effort;
			return typeof effort === "string" ? levelForEffort(model, effort) : null;
		}
		return null;
	} finally {
		clearTimeout(timeout);
		abort.abort();
	}
}
