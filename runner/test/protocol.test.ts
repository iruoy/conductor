import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type FauxResponseStep, fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentTools } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { type JsonObject, MemoryStorage, type Storage } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { afterEach, describe, expect, it, vi } from "vitest";
import { waves } from "../src/agent.ts";
import type { Live } from "../src/conversation-feed.ts";
import { levelForEffort } from "../src/defaults.ts";
import { type Event, parseVerdict, Runner } from "../src/runner.ts";

const head = { provider: "faux", modelId: "faux-1" };

type Options = {
	storage?: Storage;
	github?: { baseUrl: string; token: string };
	faux?: Parameters<typeof fauxProvider>[0];
	retry?: { maxRetries: number };
};
const open: Runner[] = [];
const dirs: string[] = [];

async function setup(responses: FauxResponseStep[], { storage = new MemoryStorage(), github, faux: fauxOptions, retry }: Options = {}) {
	const faux = fauxProvider(fauxOptions);
	faux.setResponses(responses);
	const models = createModels();
	models.setProvider(faux.provider);
	const events: Event[] = [];
	const runner = await Runner.open({ storage, models, emit: (e) => events.push(e), github, retry });
	open.push(runner);
	return { runner, events, faux };
}

async function close(runner: Runner) {
	await runner.close();
	open.splice(open.indexOf(runner), 1);
}

async function sqliteFile() {
	const dir = await mkdtemp(join(tmpdir(), "conductor-runner-"));
	dirs.push(dir);
	return join(dir, "runner.sqlite");
}

async function until<T>(find: () => T | undefined, ms = 5_000): Promise<T> {
	const deadline = Date.now() + ms;
	for (;;) {
		const value = find();
		if (value !== undefined) return value;
		if (Date.now() > deadline) throw new Error("timed out");
		await new Promise((r) => setTimeout(r, 10));
	}
}

type Entry = { id: number; kind: string; model?: { role?: string; content?: { type: string; text?: string }[]; [key: string]: unknown }[] };
type Feed = { type: "snapshot" | "update"; entries?: Entry[]; live?: Live };

/** The feed events Phoenix got, of one role's conversation when given. */
const feed = (events: Event[], role?: string): Feed[] =>
	events.flatMap((e) => (e.type === "agent_event" && (role === undefined || e.role === role) ? [e.event as Feed] : []));
const entriesOf = (events: Event[], role?: string): Entry[] => feed(events, role).flatMap((f) => f.entries ?? []);
const livesOf = (events: Event[]): Live[] => feed(events).flatMap((f) => (f.live ? [f.live] : []));

/** The run's prompt reached Phoenix: in the attach snapshot, or appended after it. */
const promptStreamed = (events: Event[]) => until(() => entriesOf(events).find((entry) => entry.kind === "pi.user"));

/** The `nth` settlement of a run (a resumed run settles again). */
const settledEvent = (events: Event[], runId: string, nth = 1) =>
	until(() => events.filter((e) => e.type === "run_settled" && e.run_id === runId)[nth - 1]);

const waitingForInput = (events: Event[]) => until(() => events.find((e) => e.type === "run_state" && e.status === "waiting_for_input"));

const start = (runner: Runner, runId: string, extra: Record<string, unknown> = {}) =>
	runner.handle({ type: "start_run", run_id: runId, cwd: process.cwd(), prompt: "Do the thing", models: { head }, ...extra });

const askHuman = (question: string) => fauxAssistantMessage([fauxToolCall("ask_human", { question }, { id: "ask" })], { stopReason: "toolUse" });

afterEach(async () => {
	for (const runner of open.splice(0)) await runner.close().catch(() => {});
	for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true });
});

describe("runner protocol", () => {
	it("ends the session as closed on shutdown, and as failed once when storage fails", async () => {
		const closed = await setup([]);
		await closed.runner.close();
		expect(await closed.runner.sessionEnd).toEqual({ kind: "closed" });
		expect(closed.events.some((event) => event.type === "log")).toBe(false);

		const storage = new MemoryStorage();
		const { runner, events } = await setup([], { storage });
		vi.spyOn(storage, "commit").mockRejectedValueOnce(new Error("disk failed"));
		await expect(start(runner, "STORAGE-1-1")).rejects.toThrow();
		expect(await runner.sessionEnd).toMatchObject({ kind: "failed" });
		await expect(start(runner, "STORAGE-2-1")).rejects.toThrow();
		const restart = "Runner storage failed; restarting from durable state.";
		expect(events.filter((event) => event.type === "log" && event.message === restart)).toHaveLength(1);
	});

	it("streams the conversation feed and settles a run", async () => {
		const { runner, events } = await setup([fauxAssistantMessage("Implemented it.\n\nDONE")]);
		await start(runner, "PROJ-1-1");

		expect(await settledEvent(events, "PROJ-1-1")).toMatchObject({ outcome: "completed", error: null, summary: "Implemented it.\n\nDONE" });
		const [snapshot, ...updates] = feed(events, "head");
		expect(snapshot!.type).toBe("snapshot");
		expect(updates.every((update) => update.type === "update")).toBe(true);
		expect(entriesOf(events).map((entry) => entry.kind)).toEqual(expect.arrayContaining(["pi.user", "pi.assistant"]));
		expect(livesOf(events).at(-1)).toMatchObject({ busy: false, message: null, tools: [] });
	});

	it("treats a duplicate start_run as a no-op and takes no message for a settled run", async () => {
		const { runner, events, faux } = await setup([fauxAssistantMessage("DONE")]);
		const first = (await start(runner, "PROJ-2-1")) as { conversation_id: number };
		await settledEvent(events, "PROJ-2-1");
		expect(await start(runner, "PROJ-2-1")).toEqual({ conversation_id: first.conversation_id, status: "settled" });
		expect(faux.state.callCount).toBe(1);
		await expect(runner.handle({ type: "message", run_id: "PROJ-2-1", text: "hello" })).rejects.toThrow("is not running");
	});

	it("discovers deferred tools and streams nested codemode calls", async () => {
		const seen: string[][] = [];
		const { runner, events } = await setup([
			(context) => {
				seen.push(getCurrentTools(context.messages).map((tool) => tool.name));
				return fauxAssistantMessage([fauxToolCall("tool_search", { query: "GitHub issue status" }, { id: "discover" })], { stopReason: "toolUse" });
			},
			(context) => {
				seen.push(getCurrentTools(context.messages).map((tool) => tool.name));
				const code = 'const result = await tools.bash({command: "printf codemode-output"}); text(result.output);';
				return fauxAssistantMessage([fauxToolCall("codemode", { code }, { id: "script" })], { stopReason: "toolUse" });
			},
			(context) => {
				expect(JSON.stringify(context.messages)).toContain("codemode-output");
				return fauxAssistantMessage("DONE");
			},
		]);
		await start(runner, "CODE-1-1");
		expect(await settledEvent(events, "CODE-1-1")).toMatchObject({ outcome: "completed" });
		expect(seen[0]).toEqual(expect.arrayContaining(["codemode", "tool_search"]));
		expect(seen[0]).not.toContain("set_issue_status");
		expect(seen[1]).toContain("set_issue_status");
		const nested = livesOf(events).flatMap((live) => live.tools).find((tool) => tool.parentCallId === "script");
		expect(nested).toMatchObject({ name: "bash", args: { command: "printf codemode-output" } });
	});

	it("streams answer text as deltas and starts model-issued tools with their arguments", async () => {
		const answer = "Ran the checks one by one and they all passed.\n\nDONE";
		const { runner, events } = await setup(
			[fauxAssistantMessage([fauxToolCall("bash", { command: "printf ok" }, { id: "c1" })], { stopReason: "toolUse" }), fauxAssistantMessage(answer)],
			{ faux: { tokensPerSecond: 40, tokenSize: { min: 1, max: 2 } } },
		);
		await start(runner, "STREAM-1-1");
		expect(await settledEvent(events, "STREAM-1-1")).toMatchObject({ outcome: "completed", summary: answer });

		const lives = livesOf(events);
		expect(lives.flatMap((live) => live.tools).find((tool) => tool.callId === "c1")).toMatchObject({
			name: "bash",
			args: { command: "printf ok" },
			parentCallId: null,
		});
		// Each live state holds the answer so far; the one that comes with the answer's entry no longer does.
		const streamed = lives.flatMap((live) => (live.message?.text ? [live.message.text] : []));
		expect(new Set(streamed).size).toBeGreaterThan(1);
		for (const text of streamed) expect(answer.startsWith(text)).toBe(true);
		const last = entriesOf(events).at(-1)!;
		const done = feed(events).find((f) => f.entries?.some((entry) => entry.id === last.id));
		expect(done?.live?.message ?? null).toBeNull();
	});

	it("waits for a human answer and continues the same run", async () => {
		let seen: { role: string; content?: unknown }[] = [];
		const { runner, events } = await setup([
			askHuman("Which colour?"),
			(context) => {
				seen = context.messages as typeof seen;
				return fauxAssistantMessage("Painted it blue.\nDONE");
			},
		]);
		await start(runner, "PROJ-4-1");
		const question = await until(() => events.find((e) => e.type === "question"));
		expect(question).toMatchObject({ run_id: "PROJ-4-1", text: "Which colour?" });
		await waitingForInput(events);

		await runner.handle({ type: "answer", run_id: "PROJ-4-1", qid: question.qid, text: "blue" });
		expect(await settledEvent(events, "PROJ-4-1")).toMatchObject({ outcome: "completed" });
		const sync = (await runner.handle({ type: "sync" })) as { runs: { questions: unknown[] }[] };
		expect(sync.runs[0]!.questions).toMatchObject([{ qid: question.qid, text: "Which colour?", answered: true }]);
		// The answer is the result of the agent's ask_human call, in the same run: no new message from a human.
		expect(seen.at(-1)).toMatchObject({ role: "toolResult", content: [{ type: "text", text: "blue" }] });
		expect(seen.filter((message) => message.role === "user")).toHaveLength(1);
	});

	it("asks a human when the agent ends without a verdict", async () => {
		const { runner, events } = await setup([fauxAssistantMessage("I am not sure what to do."), fauxAssistantMessage("DONE")]);
		await start(runner, "PROJ-5-1");
		const question = await until(() => events.find((e) => e.type === "question"));
		expect(question.text).toContain("I am not sure what to do.");
		await runner.handle({ type: "answer", run_id: "PROJ-5-1", qid: question.qid, text: "carry on" });
		expect(await settledEvent(events, "PROJ-5-1")).toMatchObject({ outcome: "completed" });
	});

	it("aborts a run waiting for input", async () => {
		const { runner, events } = await setup([askHuman("?")]);
		await start(runner, "PROJ-9-1");
		await waitingForInput(events);
		await runner.handle({ type: "abort", run_id: "PROJ-9-1" });
		expect(await settledEvent(events, "PROJ-9-1")).toMatchObject({ outcome: "failed", error: "aborted" });
	});

	it("runs subagents in dependency order on their own models and streams them", async () => {
		const tasks: JsonObject[] = [
			{ key: "PROJ-7", title: "Second", instructions: "do B", dependsOn: ["PROJ-6"] },
			{ key: "PROJ-6", title: "First", complexity: "low", instructions: "do A" },
		];
		const { runner, events } = await setup([
			fauxAssistantMessage([fauxToolCall("run_subagents", { tasks }, { id: "c1" })], { stopReason: "toolUse" }),
			fauxAssistantMessage("A is done"),
			fauxAssistantMessage("B is done"),
			fauxAssistantMessage("Both subtasks done.\nDONE"),
		]);
		await start(runner, "PROJ-8-1", { models: { head, low: { ...head, reasoning: "low" } } });
		expect(await settledEvent(events, "PROJ-8-1")).toMatchObject({ outcome: "completed" });

		const text = entriesOf(events, "head").find((entry) => entry.kind === "pi.tool-result")!.model![0]!.content![0]!.text!;
		expect(text).toContain("## PROJ-7: done\n\nB is done");
		expect(text.indexOf("PROJ-7")).toBeLessThan(text.indexOf("PROJ-6")); // in the order the head gave them

		// Phoenix reads the model a conversation ran on from its assistant messages.
		const ranOn = (role: string) => entriesOf(events, role).find((entry) => entry.kind === "pi.assistant")?.model?.[0];
		expect(ranOn("head")).toMatchObject({ provider: "faux", model: "faux-1" });
		expect(ranOn("sub:PROJ-6")).toMatchObject({ provider: "faux", model: "faux-1", thinkingLevel: "low" });
		expect(ranOn("sub:PROJ-7")).toMatchObject({ provider: "faux", model: "faux-1" });
	});

	it("lets a subagent move its subtask through the project's statuses", async () => {
		const requests: unknown[] = [];
		const server = createServer((request, response) => {
			let body = "";
			request.on("data", (chunk) => (body += chunk));
			request.on("end", () => {
				requests.push({ url: request.url, body: JSON.parse(body) });
				response.setHeader("Content-Type", "application/json").end("{}");
			});
		});
		await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
		const { port } = server.address() as { port: number };
		try {
			const call = (name: string, args: JsonObject) => fauxAssistantMessage([fauxToolCall(name, args, { id: name })], { stopReason: "toolUse" });
			const { runner, events } = await setup(
				[
					call("run_subagents", { tasks: [{ key: "#2", title: "Sub", instructions: "do it" }] }),
					call("tool_search", { query: "GitHub issue status" }),
					call("set_issue_status", { number: 2, status: "in progress" }),
					fauxAssistantMessage("Sub is done"),
					fauxAssistantMessage("Done.\nDONE"),
				],
				{ github: { baseUrl: `http://127.0.0.1:${port}`, token: "t" } },
			);
			const github = {
				repo: "acme/shop",
				project_id: "project-1",
				status_field_id: "status-field",
				statuses: { "In progress": "option-progress", Done: "option-done" },
				done_status: "Done",
				items: { "2": "item-2" },
			};
			await start(runner, "PROJ-12-1", { github });
			expect(await settledEvent(events, "PROJ-12-1")).toMatchObject({ outcome: "completed" });
			expect(requests).toMatchObject([{ url: "/graphql", body: { variables: { item: "item-2", option: "option-progress" } } }]);
		} finally {
			server.close();
		}
	});

	it("passes a message to the agent while it works", async () => {
		let release!: () => void;
		const gate = new Promise<void>((resolve) => (release = resolve));
		let seen = "";
		const { runner, events } = await setup([
			async () => {
				await gate;
				return fauxAssistantMessage([fauxToolCall("bash", { command: "true" }, { id: "c1" })], { stopReason: "toolUse" });
			},
			(context) => {
				seen = JSON.stringify(context.messages);
				return fauxAssistantMessage("Used tabs.\nDONE");
			},
		]);
		await start(runner, "PROJ-21-1");
		await promptStreamed(events);
		const reply = (await runner.handle({ type: "message", run_id: "PROJ-21-1", text: "Use tabs" })) as { submission_id: number };
		const queued = await until(() => livesOf(events).find((live) => live.inbox.length > 0));
		expect(queued.inbox).toEqual([{ id: reply.submission_id, mode: "steer" }]);
		release();

		expect(await settledEvent(events, "PROJ-21-1")).toMatchObject({ outcome: "completed", summary: "Used tabs.\nDONE" });
		expect(seen).toContain("Use tabs");
		expect(events.filter((e) => e.type === "run_settled")).toHaveLength(1);
	});

	it("goes on with a message that came as the agent finished", async () => {
		let release!: () => void;
		const gate = new Promise<void>((resolve) => (release = resolve));
		const { runner, events } = await setup([
			async () => {
				await gate;
				return fauxAssistantMessage("First.\nDONE");
			},
			fauxAssistantMessage("Second.\nDONE"),
		]);
		await start(runner, "PROJ-22-1");
		await promptStreamed(events);
		await runner.handle({ type: "message", run_id: "PROJ-22-1", text: "One more thing" });
		release();

		expect(await settledEvent(events, "PROJ-22-1")).toMatchObject({ outcome: "completed", summary: "Second.\nDONE" });
		expect(events.filter((e) => e.type === "run_settled")).toHaveLength(1);
	});

	it("resumes review feedback in the same conversation, retaining prior context", async () => {
		let seen = "";
		const { runner, events } = await setup([
			fauxAssistantMessage("Original implementation.\nDONE"),
			(context) => {
				seen = JSON.stringify(context.messages);
				return fauxAssistantMessage("Review addressed.\nDONE");
			},
		]);
		const original = (await start(runner, "REVIEW-1-1")) as { conversation_id: number };
		await settledEvent(events, "REVIEW-1-1");
		await expect(runner.handle({ type: "resume_run", run_id: "REVIEW-1-1", text: "" })).rejects.toThrow("empty review feedback");
		const reply = (await runner.handle({ type: "resume_run", run_id: "REVIEW-1-1", text: "Fix the review findings" })) as { conversation_id: number };
		expect(reply.conversation_id).toBe(original.conversation_id);
		expect(await settledEvent(events, "REVIEW-1-1", 2)).toMatchObject({ outcome: "completed", summary: "Review addressed.\nDONE" });
		expect(seen).toContain("Original implementation.");
		expect(seen).toContain("Fix the review findings");
	});

	it("continues a failed run where it stopped, in the same conversation", async () => {
		let seen = "";
		const { runner, events } = await setup(
			[
				fauxAssistantMessage("", { stopReason: "error", errorMessage: "provider overloaded" }),
				(context) => {
					seen = JSON.stringify(context.messages);
					return fauxAssistantMessage("Picked it up again.\nDONE");
				},
			],
			{ retry: { maxRetries: 0 } },
		);
		const { conversation_id } = (await start(runner, "CONT-1-1")) as { conversation_id: number };
		expect(await settledEvent(events, "CONT-1-1")).toMatchObject({ outcome: "failed", error: expect.stringContaining("provider overloaded") });

		const reply = (await runner.handle({ type: "resume_run", run_id: "CONT-1-1", text: "" })) as { conversation_id: number };
		expect(reply.conversation_id).toBe(conversation_id);
		expect(await settledEvent(events, "CONT-1-1", 2)).toMatchObject({ outcome: "completed" });
		// Nothing new from a human: the model answers the original prompt again.
		expect(seen).toContain("Do the thing");
		const prompts = entriesOf(events, "head").filter((entry) => entry.kind === "pi.user");
		expect(new Set(prompts.map((entry) => entry.id)).size).toBe(1);
	});

	it("needs a message to go on with a run the agent failed itself", async () => {
		const { runner, events } = await setup([fauxAssistantMessage("Tests do not pass.\nFAILED: flaky database"), fauxAssistantMessage("Fixed it.\nDONE")]);
		await start(runner, "REVIEW-2-1");
		expect(await settledEvent(events, "REVIEW-2-1")).toMatchObject({ outcome: "failed", error: "flaky database" });
		await expect(runner.handle({ type: "resume_run", run_id: "REVIEW-2-1", text: " " })).rejects.toThrow("tell it how to go on");
		await runner.handle({ type: "resume_run", run_id: "REVIEW-2-1", text: "The database is back, try again" });
		expect(await settledEvent(events, "REVIEW-2-1", 2)).toMatchObject({ outcome: "completed" });
	});

	it("keeps runs, questions and conversations across a restart", async () => {
		const file = await sqliteFile();
		const first = await setup([askHuman("Go?")], { storage: await openNodeSqliteStorage(file) });
		const { conversation_id } = (await start(first.runner, "PROJ-10-1")) as { conversation_id: number };
		await waitingForInput(first.events);
		await close(first.runner);

		const second = await setup([fauxAssistantMessage("Went.\nDONE"), fauxAssistantMessage("Review addressed.\nDONE")], {
			storage: await openNodeSqliteStorage(file),
		});
		const sync = (await second.runner.handle({ type: "sync" })) as { runs: { run_id: string; status: string; questions: { qid: string }[] }[] };
		expect(sync.runs).toMatchObject([{ run_id: "PROJ-10-1", status: "waiting_for_input" }]);
		await second.runner.handle({ type: "answer", run_id: "PROJ-10-1", qid: sync.runs[0]!.questions[0]!.qid, text: "yes" });
		expect(await settledEvent(second.events, "PROJ-10-1")).toMatchObject({ outcome: "completed" });

		const resumed = (await second.runner.handle({ type: "resume_run", run_id: "PROJ-10-1", text: "Address feedback" })) as { conversation_id: number };
		expect(resumed.conversation_id).toBe(conversation_id);
		expect(await settledEvent(second.events, "PROJ-10-1", 2)).toMatchObject({ outcome: "completed", summary: "Review addressed.\nDONE" });
	});

	it("lists the models with the thinking levels pi supports for each", async () => {
		const { runner } = await setup([]);
		const models = (await runner.handle({ type: "models" })) as { provider: string; id: string; levels: string[] }[];
		expect(models.length).toBeGreaterThan(0);
		for (const model of models) expect(model.levels.length).toBeGreaterThan(0);
		// Only a provider that echoes its effective effort has a default to report.
		const { provider, id } = models[0]!;
		expect(await runner.handle({ type: "model_default", provider, model_id: id })).toBeNull();
	});

	it("replies with errors for bad commands", async () => {
		const { runner, events } = await setup([]);
		await runner.dispatch({ id: 7, type: "nope" });
		await runner.dispatch({ id: 8, type: "answer", run_id: "X-1", qid: "q", text: "t" });
		await runner.dispatch({ id: 9, type: "start_run", run_id: "X-1", cwd: "repo", prompt: "p", models: { head } });
		expect(events.filter((e) => e.type === "reply")).toEqual([
			{ type: "reply", id: 7, ok: false, error: "unknown command nope" },
			{ type: "reply", id: 8, ok: false, error: "unknown run X-1" },
			{ type: "reply", id: 9, ok: false, error: "start_run: cwd must be absolute, got repo" },
		]);
	});
});

describe("helpers", () => {
	it("parses verdicts from the last marker line", () => {
		expect(parseVerdict("work\n**DONE**")).toEqual({ outcome: "completed", error: null });
		expect(parseVerdict("FAILED: no tests\n")).toEqual({ outcome: "failed", error: "no tests" });
		expect(parseVerdict("DONE with A\nFAILED: B broke")).toEqual({ outcome: "failed", error: "B broke" });
		expect(parseVerdict("almost there")).toBeUndefined();
	});

	it("orders subtasks in dependency waves", () => {
		const t = (key: string, dependsOn?: string[]) => ({ key, title: key, instructions: "", dependsOn });
		const result = waves([t("C", ["A", "B"]), t("A"), t("B", ["A"]), t("D", ["MISSING"])]).map((w) => w.map((x) => x.key));
		expect(result).toEqual([["A", "D"], ["B"], ["C"]]);
	});

	it("maps a provider's effort back to the pi level of the model", () => {
		const model = { reasoning: true, thinkingLevelMap: { off: null, minimal: null, xhigh: "xhigh" } } as never;
		expect(levelForEffort(model, "medium")).toBe("medium");
		expect(levelForEffort(model, "xhigh")).toBe("xhigh");
		expect(levelForEffort(model, "none")).toBeNull();
		expect(levelForEffort({ reasoning: true } as never, "none")).toBe("off");
	});
});
