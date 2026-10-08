import { BACKGROUND_CONTEXT as ctx } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { type ConversationId, type Harness, MemoryStorage } from "@earendil-works/pi-durable";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CONTEXT_PAGE_SIZE, type ContextInspection } from "../src/context-inspection.ts";
import { Runner, type Command, type Event } from "../src/runner.ts";
import { RunsDoc } from "../src/state.ts";

const runners: Runner[] = [];
afterEach(async () => {
	for (const runner of runners.splice(0)) await runner.close();
	vi.unstubAllEnvs();
});

async function fixture() {
	const events: Event[] = [];
	const runner = await Runner.open({ storage: new MemoryStorage(), models: createModels(), emit: (e) => events.push(e), github: { baseUrl: "https://example.com", token: "configured-github-secret" } });
	runners.push(runner);
	const harness = (runner as unknown as { harness: Harness }).harness;
	const ids = await harness.commit(async (tx) => {
		const head = await tx.createConversation({ ownership: { kind: "ownerless" } });
		const sub = await tx.createConversation({ ownership: { kind: "ownerless" } });
		const other = await tx.createConversation({ ownership: { kind: "ownerless" } });
		(await tx.doc(RunsDoc)).runs.test = {
			conversationId: head.id, cwd: process.cwd(), models: { head: { provider: "unused", modelId: "unused" } },
			submissionId: null, status: "settled", aborted: false, questions: {}, settled: null,
			children: { child: { key: "child", title: "Child", conversationId: sub.id } },
		};
		const append = (id: ConversationId, text: string) => tx.appendEntry(id, { kind: "pi.user", model: [{ role: "user", content: text, timestamp: 1 }] });
		const first = await append(head.id, "original");
		const second = await append(head.id, "later");
		const child = await append(sub.id, "child-only");
		const unrelated = await append(other.id, "unrelated-secret");
		const compact = await tx.appendEntry(head.id, { kind: "pi.compaction", head: second.id, model: [{ role: "user", content: "summary", timestamp: 2 }], data: { secret: "head-data-secret" } });
		const reset = await tx.appendEntry(head.id, { kind: "pi.reset", head: "self", model: [{ role: "user", content: "reset handoff", timestamp: 3 }] });
		return { head: head.id, sub: sub.id, other: other.id, first: first.id, second: second.id, child: child.id, unrelated: unrelated.id, compact: compact.id, reset: reset.id };
	}, ctx);
	const inspect = (conversation: number, entry: number, offset = 0) => runner.handle({ type: "inspect_context", run_id: "test", conversation, entry, offset }) as Promise<ContextInspection>;
	return { runner, harness, ids, inspect, events };
}

describe("historical context inspection", () => {
	it("selects head and child, applies inclusive cutoffs, compaction and reset without mutation", async () => {
		const { harness, ids, inspect, runner } = await fixture();
		const state = await runner.handle({ type: "sync" });
		const before = await (await harness.conversation(ids.head, ctx))!.entries({}, 100, undefined, ctx);
		const commit = vi.spyOn(harness, "commit");
		const first = await inspect(ids.head, ids.first);
		expect(Object.keys(first).sort()).toEqual(["conversation", "entry", "head", "next_offset", "offset", "text", "total"]);
		expect(JSON.parse(first.text)).toEqual([{ role: "user", content: "original" }]);
		expect(first.head).toBeNull();
		expect((await inspect(ids.head, ids.second)).text).toContain("later");
		expect((await inspect(ids.sub, ids.child)).text).toContain("child-only");
		const compact = await inspect(ids.head, ids.compact);
		expect(compact.head).toEqual({ id: ids.compact, kind: "pi.compaction", head: ids.second });
		expect(compact.text).toContain("summary");
		expect(compact.text).toContain("later");
		expect(compact.text).not.toContain("original");
		expect(JSON.parse((await inspect(ids.head, ids.reset)).text)).toEqual([{ role: "user", content: "reset handoff" }]);
		expect(await runner.handle({ type: "sync" })).toEqual(state);
		expect(await (await harness.conversation(ids.head, ctx))!.entries({}, 100, undefined, ctx)).toEqual(before);
		expect(commit).not.toHaveBeenCalled();
	});

	it("includes tool results only at their inclusive cutoff without writes, forks or generation", async () => {
		const { harness, ids, inspect, runner } = await fixture();
		const toolCall = { type: "toolCall" as const, id: "cutoff-call", name: "lookup", arguments: { query: "cutoff" } };
		const toolResult = { role: "toolResult" as const, toolCallId: toolCall.id, toolName: toolCall.name,
			content: [{ type: "text" as const, text: "cutoff-tool-output" }], isError: false, timestamp: 5 };
		const entries = await harness.commit(async (tx) => {
			const call = await tx.appendEntry(ids.head, {
				kind: "pi.assistant", model: [{ role: "assistant", provider: "unused", model: "unused", api: "unused", timestamp: 4,
					content: [toolCall], usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
						cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "toolUse" }],
			});
			const result = await tx.appendEntry(ids.head, { kind: "pi.tool-result", model: [toolResult] });
			await tx.appendEntry(ids.head, { kind: "pi.user", model: [{ role: "user", content: "after-tool-result", timestamp: 6 }] });
			return { call: call.id, result: result.id };
		}, ctx);
		const conversation = (await harness.conversation(ids.head, ctx))!;
		const state = await runner.handle({ type: "sync" });
		const before = await conversation.entries({}, 100, undefined, ctx);
		// Route inspection through this handle so spies observe any attempted fork or submission.
		const lookup = vi.spyOn(harness, "conversation").mockResolvedValue(conversation);
		const fork = vi.spyOn(conversation, "fork");
		const submit = vi.spyOn(conversation, "submit");
		const resume = vi.spyOn(harness, "resume");
		const commit = vi.spyOn(harness, "commit");
		try {
			const earlier = await inspect(ids.head, entries.call);
			expect(JSON.parse(earlier.text)).toContainEqual({ role: "assistant", content: [toolCall] });
			expect(earlier.text).not.toContain("cutoff-tool-output");
			// Reconstruction may synthesize an unavailable-result placeholder, but never expose the actual result.
			expect(JSON.parse(earlier.text)).not.toContainEqual({ role: "toolResult", toolCallId: toolCall.id,
				toolName: toolCall.name, content: toolResult.content, isError: false });
			expect(earlier.text).not.toContain("after-tool-result");
			const inclusive = await inspect(ids.head, entries.result);
			expect(JSON.parse(inclusive.text)).toContainEqual({ role: "toolResult", toolCallId: toolCall.id,
				toolName: toolCall.name, content: toolResult.content, isError: false });
			expect(inclusive.text).not.toContain("after-tool-result");
			expect(await runner.handle({ type: "sync" })).toEqual(state);
			expect(await conversation.entries({}, 100, undefined, ctx)).toEqual(before);
			for (const spy of [commit, fork, submit, resume]) expect(spy).not.toHaveBeenCalled();
		} finally {
			for (const spy of [lookup, fork, submit, resume, commit]) spy.mockRestore();
		}
	});

	it("preserves system instruction sections and tool changes while redacting their secrets", async () => {
		const { harness, ids, inspect } = await fixture();
		const tool = {
			name: "lookup", description: "Look up records using configured-github-secret",
			parameters: { type: "object" as const, properties: { query: { type: "string" as const } }, required: ["query"] },
		};
		const entries = await harness.commit(async (tx) => {
			const baseline = await tx.appendEntry(ids.head, {
				kind: "pi.system", model: [{ role: "system", content: "", timestamp: 7,
					sections: { instructions: "Follow AGENTS.md; run mix precommit", access: "Bearer configured-github-secret" },
					toolsAdded: [tool] }],
			});
			const update = await tx.appendEntry(ids.head, {
				kind: "pi.system", model: [{ role: "system", content: "Additional instructions", timestamp: 8,
					sections: { instructions: "Run the runner tests too", access: null },
					toolsRemoved: [{ name: "lookup" }] }],
			});
			return { baseline: baseline.id, update: update.id };
		}, ctx);
		const baseline = JSON.parse((await inspect(ids.head, entries.baseline)).text);
		expect(baseline).toContainEqual({
			role: "system", content: "",
			sections: { instructions: "Follow AGENTS.md; run mix precommit", access: "Bearer [REDACTED]" },
			toolsAdded: [{ ...tool, description: "Look up records using [REDACTED]" }],
		});
		expect(baseline).not.toContainEqual(expect.objectContaining({ content: "Additional instructions" }));
		const updated = await inspect(ids.head, entries.update);
		expect(JSON.parse(updated.text)).toContainEqual({
			role: "system", content: "Additional instructions",
			sections: { instructions: "Run the runner tests too", access: null }, toolsRemoved: [{ name: "lookup" }],
		});
		expect(updated.text).not.toContain("configured-github-secret");
		expect(updated.text).not.toContain('"timestamp"');
	});

	it("returns generic errors for invalid ids, membership, cutoffs and offsets", async () => {
		const { runner, ids, events } = await fixture();
		const base: Command = { type: "inspect_context", run_id: "test", conversation: ids.head, entry: ids.first };
		for (const invalid of [
			{ run_id: "secret-run-name" }, { conversation: ids.other, entry: ids.unrelated },
			{ entry: ids.child }, { entry: 999999 }, { entry: 0 }, { entry: "1" },
			{ offset: -1 }, { offset: 0.5 }, { offset: 999999 }, { conversation: null },
		]) {
			await runner.dispatch({ ...base, ...invalid });
			expect(events.at(-1)).toEqual({ type: "reply", id: null, ok: false, error: "Unable to inspect context" });
		}
	});

	it("omits hidden reasoning and provider metadata, redacts before bounded character pagination", async () => {
		vi.stubEnv("INSPECTION_TEST_SECRET", "environment-secret");
		const { harness, ids, inspect } = await fixture();
		const entry = await harness.commit((tx) => tx.appendEntry(ids.head, {
			kind: "pi.assistant", model: [{ role: "assistant", provider: "private-provider", model: "private-model", api: "private-api", timestamp: 1,
				content: [
					{ type: "thinking", thinking: "hidden-reasoning", thinkingSignature: "hidden-signature" },
					{ type: "text", text: "😀".repeat(17000) + " configured-github-secret environment-secret password=unknown-secret" },
					{ type: "toolCall", id: "call", name: "tool", arguments: { api_key: "keyed-secret", nested: { refreshToken: "refresh-secret" } } },
				], usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop" }],
		}), ctx);
		let page = await inspect(ids.head, entry.id);
		expect(Array.from(page.text)).toHaveLength(CONTEXT_PAGE_SIZE);
		let text = page.text;
		while (page.next_offset !== null) {
			page = await inspect(ids.head, entry.id, page.next_offset);
			text += page.text;
		}
		expect(Array.from(text)).toHaveLength(page.total);
		expect(() => JSON.parse(text)).not.toThrow();
		for (const secret of ["hidden-reasoning", "hidden-signature", "private-provider", "private-model", "private-api", "configured-github-secret", "environment-secret", "unknown-secret", "keyed-secret", "refresh-secret"]) expect(text).not.toContain(secret);
		expect(text).toContain("[REDACTED]");
		expect((await inspect(ids.head, entry.id, page.total)).text).toBe("");
	});
});
