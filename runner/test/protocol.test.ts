import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type FauxResponseStep, fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { MemoryStorage, type Storage } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { afterEach, describe, expect, it } from "vitest";
import { waves } from "../src/agent.ts";
import { levelForEffort } from "../src/defaults.ts";
import { type Event, parseVerdict, Runner } from "../src/runner.ts";

const head = { provider: "faux", modelId: "faux-1" };

type Setup = { runner: Runner; events: Event[]; faux: ReturnType<typeof fauxProvider> };
const open: Runner[] = [];
const dirs: string[] = [];

async function setup(
	responses: FauxResponseStep[],
	storage: Storage = new MemoryStorage(),
	github?: { baseUrl: string; token: string },
): Promise<Setup> {
	const faux = fauxProvider();
	faux.setResponses(responses);
	const models = createModels();
	models.setProvider(faux.provider);
	const events: Event[] = [];
	const runner = await Runner.open({ storage, models, emit: (e) => events.push(e), ...(github ? { github } : {}) });
	open.push(runner);
	return { runner, events, faux };
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

const settledEvent = (events: Event[], runId: string) =>
	until(() => events.find((e) => e.type === "run_settled" && e.run_id === runId));

const start = (runner: Runner, runId: string, extra: Record<string, unknown> = {}) =>
	runner.handle({ type: "start_run", run_id: runId, cwd: process.cwd(), prompt: "Do the thing", models: { head }, ...extra });

afterEach(async () => {
	for (const runner of open.splice(0)) await runner.close().catch(() => {});
	for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true });
});

describe("runner protocol", () => {
	it("emits ready, streams events, and settles a run", async () => {
		const { runner, events } = await setup([fauxAssistantMessage("Implemented it.\n\nDONE")]);
		expect(events[0]).toMatchObject({ type: "ready", resumed: [] });

		const reply = (await start(runner, "PROJ-1-1")) as { conversation_id: number };
		expect(reply.conversation_id).toBeTypeOf("number");

		const settled = await settledEvent(events, "PROJ-1-1");
		expect(settled).toMatchObject({ outcome: "completed", error: null, summary: "Implemented it.\n\nDONE" });
		const agentEvents = events.filter((e) => e.type === "agent_event");
		expect(agentEvents[0]).toMatchObject({ role: "head", event: { type: "snapshot" } });
		expect(agentEvents.some((e) => (e.event as { type: string }).type === "message_end")).toBe(true);
		const seqs = events.filter((e) => e.seq !== undefined).map((e) => e.seq as number);
		expect(seqs).toEqual([...seqs].sort((a, b) => a - b));
	});

	it("preserves bash ANSI and BEL-terminated OSC through live updates and durable results", async () => {
		const ansi = "\u001b[31mvitest output\u001b[0m";
		const osc = "\u001b]0;conductor title\u0007";
		const expected = `${ansi}${osc}`;
		const { runner, events } = await setup([
			fauxAssistantMessage(
				[
					fauxToolCall(
						"bash",
						{ command: "printf '\\033[31mvitest output\\033[0m\\033]0;conductor title\\007\\000'" },
						{ id: "ansi-call" },
					),
				],
				{ stopReason: "toolUse" },
			),
			fauxAssistantMessage("Done.\nDONE"),
		]);

		await start(runner, "ANSI-1-1");
		await settledEvent(events, "ANSI-1-1");

		const streamedOutput = events.flatMap((event) => {
			if (event.type !== "agent_event" || (event.event as { type?: string }).type !== "tool_execution_update") return [];
			const output = (event.event as { output?: { append?: string; set?: string } }).output;
			return [`${output?.append ?? ""}${output?.set ?? ""}`];
		});
		expect(streamedOutput.join("")).toContain(expected);
		expect(streamedOutput.join("")).not.toContain("\u0000");

		const toolResult = events.find(
			(event) =>
				event.type === "agent_event" &&
				(event.event as { type?: string; entry?: { kind?: string } }).type === "message_end" &&
				(event.event as { entry?: { kind?: string } }).entry?.kind === "pi.tool-result",
		) as { event: { entry: { model: { content: { text?: string }[] }[] } } } | undefined;
		const resultText = toolResult?.event.entry.model[0]?.content[0]?.text;
		expect(resultText).toBe(expected);
		expect(resultText).not.toContain("\u0000");
	});

	it("treats a duplicate start_run as a no-op", async () => {
		const { runner, events, faux } = await setup([fauxAssistantMessage("DONE")]);
		const first = (await start(runner, "PROJ-2-1")) as { conversation_id: number };
		await settledEvent(events, "PROJ-2-1");
		const again = (await start(runner, "PROJ-2-1")) as { conversation_id: number; status: string };
		expect(again).toEqual({ conversation_id: first.conversation_id, status: "settled" });
		expect(faux.state.callCount).toBe(1);
	});

	it("reports FAILED verdicts as failed runs", async () => {
		const { runner, events } = await setup([fauxAssistantMessage("Tests do not pass.\nFAILED: flaky database")]);
		await start(runner, "PROJ-3-1");
		expect(await settledEvent(events, "PROJ-3-1")).toMatchObject({ outcome: "failed", error: "flaky database" });
	});

	it("waits for a human answer and continues the same run", async () => {
		const { runner, events } = await setup([
			fauxAssistantMessage([fauxToolCall("ask_human", { question: "Which colour?" }, { id: "c1" })], { stopReason: "toolUse" }),
			fauxAssistantMessage("Painted it blue.\nDONE"),
		]);
		await start(runner, "PROJ-4-1");
		const question = await until(() => events.find((e) => e.type === "question"));
		expect(question).toMatchObject({ run_id: "PROJ-4-1", text: "Which colour?" });
		await until(() => events.find((e) => e.type === "run_state" && e.status === "waiting_for_input"));

		await runner.handle({ type: "answer", run_id: "PROJ-4-1", qid: question.qid, text: "blue" });
		expect(await settledEvent(events, "PROJ-4-1")).toMatchObject({ outcome: "completed" });
		const sync = (await runner.handle({ type: "sync" })) as { runs: { questions: { answered: boolean }[] }[] };
		expect(sync.runs[0]!.questions).toEqual([{ qid: question.qid, text: "Which colour?", answered: true }]);
	});

	it("asks a human when the agent ends without a verdict", async () => {
		const { runner, events } = await setup([fauxAssistantMessage("I am not sure what to do."), fauxAssistantMessage("DONE")]);
		await start(runner, "PROJ-5-1");
		const question = await until(() => events.find((e) => e.type === "question"));
		expect(question.text).toContain("I am not sure what to do.");
		await runner.handle({ type: "answer", run_id: "PROJ-5-1", qid: question.qid, text: "carry on" });
		expect(await settledEvent(events, "PROJ-5-1")).toMatchObject({ outcome: "completed" });
	});

	it("runs subagents in dependency order and streams them", async () => {
		const tasks = [
			{ key: "PROJ-7", title: "Second", instructions: "do B", dependsOn: ["PROJ-6"] },
			{ key: "PROJ-6", title: "First", complexity: "low", instructions: "do A" },
		];
		const { runner, events } = await setup([
			fauxAssistantMessage([fauxToolCall("run_subagents", { tasks }, { id: "c1" })], { stopReason: "toolUse" }),
			fauxAssistantMessage("A is done"),
			fauxAssistantMessage("B is done"),
			fauxAssistantMessage("Both subtasks done.\nDONE"),
		]);
		await start(runner, "PROJ-8-1", { models: { head, low: { provider: "faux", modelId: "faux-1", reasoning: "low" } } });
		expect(await settledEvent(events, "PROJ-8-1")).toMatchObject({ outcome: "completed" });

		const roles = new Set(events.filter((e) => e.type === "agent_event").map((e) => e.role));
		expect(roles).toEqual(new Set(["head", "sub:PROJ-6", "sub:PROJ-7"]));
		const toolResult = events.find(
			(e) => e.type === "agent_event" && (e.event as { type: string }).type === "tool_execution_end",
		)!.event as { entry: { model: { content: { text: string }[] }[] } };
		const text = toolResult.entry.model[0]!.content[0]!.text;
		expect(text).toContain("## PROJ-7: done\n\nB is done");
		expect(text.indexOf("PROJ-7")).toBeLessThan(text.indexOf("PROJ-6")); // in the order the head gave them

		// Conductor reads the model a conversation ran on from its assistant messages.
		const answers = events.flatMap((e) => {
			const event = e.event as { type: string; entry?: { kind: string; model: Record<string, unknown>[] } } | undefined;
			return e.type === "agent_event" && event?.type === "message_end" && event.entry?.kind === "pi.assistant"
				? [{ ...event.entry.model[0], conversation: e.role }]
				: [];
		});
		for (const role of ["head", "sub:PROJ-6", "sub:PROJ-7"]) {
			expect(answers.find((a) => a.conversation === role)).toMatchObject({ provider: "faux", model: "faux-1" });
		}
	});

	it("lets a subagent move its subtask through the project's statuses", async () => {
		const requests: { url: string; body: { variables?: Record<string, string> } }[] = [];
		const server = createServer((request, response) => {
			let body = "";
			request.on("data", (chunk) => (body += chunk));
			request.on("end", () => {
				requests.push({ url: request.url!, body: JSON.parse(body) });
				response.setHeader("Content-Type", "application/json").end("{}");
			});
		});
		await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
		const { port } = server.address() as { port: number };

		try {
			const tasks = [{ key: "#2", title: "Sub", instructions: "do it" }];
			const { runner, events } = await setup(
				[
					fauxAssistantMessage([fauxToolCall("run_subagents", { tasks }, { id: "c1" })], { stopReason: "toolUse" }),
					fauxAssistantMessage([fauxToolCall("set_issue_status", { number: 2, status: "in progress" }, { id: "c2" })], {
						stopReason: "toolUse",
					}),
					fauxAssistantMessage("Sub is done"),
					fauxAssistantMessage("Done.\nDONE"),
				],
				new MemoryStorage(),
				{ baseUrl: `http://127.0.0.1:${port}`, token: "t" },
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
			expect(requests).toMatchObject([
				{ url: "/graphql", body: { variables: { item: "item-2", option: "option-progress" } } },
			]);
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
		await until(() => events.find((e) => e.type === "agent_event" && (e.event as { type: string }).type === "message_start"));
		const reply = (await runner.handle({ type: "message", run_id: "PROJ-21-1", text: "Use tabs" })) as { submission_id: number };
		expect(reply.submission_id).toBeTypeOf("number");
		const queued = await until(() =>
			events.find((e) => e.type === "agent_event" && (e.event as { type: string }).type === "inbox_update"),
		);
		expect((queued.event as { items: unknown[] }).items).toEqual([{ id: reply.submission_id, mode: "steer" }]);
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
		await until(() => events.find((e) => e.type === "agent_event" && (e.event as { type: string }).type === "message_start"));
		await runner.handle({ type: "message", run_id: "PROJ-22-1", text: "One more thing" });
		release();

		expect(await settledEvent(events, "PROJ-22-1")).toMatchObject({ outcome: "completed", summary: "Second.\nDONE" });
		expect(events.filter((e) => e.type === "run_settled")).toHaveLength(1);
	});

	it("takes no message for a run that is not running", async () => {
		const { runner, events } = await setup([fauxAssistantMessage("DONE")]);
		await start(runner, "PROJ-23-1");
		await settledEvent(events, "PROJ-23-1");
		await expect(runner.handle({ type: "message", run_id: "PROJ-23-1", text: "hello" })).rejects.toThrow("is not running");
	});

	it("aborts a run waiting for input", async () => {
		const { runner, events } = await setup([
			fauxAssistantMessage([fauxToolCall("ask_human", { question: "?" }, { id: "c1" })], { stopReason: "toolUse" }),
		]);
		await start(runner, "PROJ-9-1");
		await until(() => events.find((e) => e.type === "run_state" && e.status === "waiting_for_input"));
		await runner.handle({ type: "abort", run_id: "PROJ-9-1" });
		expect(await settledEvent(events, "PROJ-9-1")).toMatchObject({ outcome: "failed", error: "aborted" });
	});

	it("keeps runs and questions across a restart", async () => {
		const dir = await mkdtemp(join(tmpdir(), "conductor-runner-"));
		dirs.push(dir);
		const file = join(dir, "durable.sqlite");
		const first = await setup(
			[fauxAssistantMessage([fauxToolCall("ask_human", { question: "Go?" }, { id: "c1" })], { stopReason: "toolUse" })],
			await openNodeSqliteStorage(file),
		);
		await start(first.runner, "PROJ-10-1");
		const question = await until(() => first.events.find((e) => e.type === "run_state" && e.status === "waiting_for_input"));
		expect(question).toBeDefined();
		await first.runner.close();
		open.splice(open.indexOf(first.runner), 1);

		const second = await setup([fauxAssistantMessage("Went.\nDONE")], await openNodeSqliteStorage(file));
		const sync = (await second.runner.handle({ type: "sync" })) as {
			runs: { run_id: string; status: string; questions: { qid: string }[] }[];
		};
		expect(sync.runs).toMatchObject([{ run_id: "PROJ-10-1", status: "waiting_for_input" }]);
		await second.runner.handle({ type: "answer", run_id: "PROJ-10-1", qid: sync.runs[0]!.questions[0]!.qid, text: "yes" });
		expect(await settledEvent(second.events, "PROJ-10-1")).toMatchObject({ outcome: "completed" });
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

	it("maps a provider's effort back to the pi level of the model", () => {
		const model = { reasoning: true, thinkingLevelMap: { off: null, minimal: null, xhigh: "xhigh" } } as never;
		expect(levelForEffort(model, "medium")).toBe("medium");
		expect(levelForEffort(model, "xhigh")).toBe("xhigh");
		expect(levelForEffort(model, "none")).toBeNull();
		expect(levelForEffort({ reasoning: true } as never, "none")).toBe("off");
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
});
