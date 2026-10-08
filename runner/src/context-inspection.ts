// Inspection exports only reconstructed messages, never agent/provider configuration or raw entry payloads.
import type { ContextView } from "@earendil-works/pi-durable";

export const CONTEXT_PAGE_SIZE = 16_000;
export type ContextInspection = {
	conversation: number;
	entry: number;
	text: string;
	offset: number;
	total: number;
	next_offset: number | null;
	head: { id: number; kind: string; head: number | null } | null;
};

const sensitiveKey = /(?:api[_-]?key|token|secret|password|passwd|credential|authorization|cookie|private[_-]?key)/i;
const omittedKey = /^(?:thinking|reasoning|thinkingSignature|signature|provider|providerConfig|credentials)$/i;

/** No credential store reads (and consequently no OAuth refresh) are performed for inspection. */
export function environmentSecrets(): string[] {
	return Object.entries(process.env)
		.filter(([key, value]) => sensitiveKey.test(key) && Boolean(value))
		.map(([, value]) => value!);
}

export function contextPage(
	view: ContextView,
	conversation: number,
	entry: number,
	offset: number,
	secrets: readonly string[],
): ContextInspection {
	const known = [...new Set(secrets.filter(Boolean))].sort((a, b) => b.length - a.length);
	const redactText = (text: string): string => {
		for (const secret of known) text = text.split(secret).join("[REDACTED]");
		// Also cover common secrets embedded in tool output / plain text rather than structured arguments.
		text = text.replace(/\b(Bearer|Basic)\s+[A-Za-z0-9+/_.=:-]+/gi, "$1 [REDACTED]");
		return text.replace(
			/((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|authorization)\s*[=:]\s*)(?:"[^"\n]*"|'[^'\n]*'|[^\s,;}]+)/gi,
			"$1[REDACTED]",
		);
	};
	const sanitize = (value: unknown): unknown => {
		if (typeof value === "string") return redactText(value);
		if (Array.isArray(value)) return value.filter((v) => !hiddenBlock(v)).map(sanitize);
		if (value && typeof value === "object") {
			return Object.fromEntries(Object.entries(value).flatMap(([key, child]) => {
				if (omittedKey.test(key)) return [];
				return [[key, sensitiveKey.test(key) ? "[REDACTED]" : sanitize(child)]];
			}));
		}
		return value;
	};
	const messages = view.messages.map((message) => {
		// Allowlist outer fields: assistant messages also contain provider/model, usage and other internal metadata.
		const raw = message as unknown as Record<string, unknown>;
		return sanitize(Object.fromEntries(
			["role", "content", "toolCallId", "toolName", "isError"].filter((key) => key in raw).map((key) => [key, raw[key]]),
		));
	});
	// Offsets count Unicode characters, not bytes; redact before slicing so page boundaries cannot split a secret.
	const characters = Array.from(JSON.stringify(messages, null, 2));
	if (offset > characters.length) throw new Error("Invalid context offset");
	const end = Math.min(offset + CONTEXT_PAGE_SIZE, characters.length);
	return {
		conversation, entry, text: characters.slice(offset, end).join(""), offset, total: characters.length,
		next_offset: end < characters.length ? end : null,
		head: view.head ? { id: view.head.id as number, kind: redactText(view.head.kind), head: (view.head.head as number | undefined) ?? null } : null,
	};
}

function hiddenBlock(value: unknown): boolean {
	return Boolean(value && typeof value === "object" && /^(?:thinking|reasoning|redacted_thinking)$/i.test(String((value as { type?: unknown }).type)));
}
