import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type FauxResponseStep, fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { MemoryStorage, type Storage } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { afterEach, describe, expect, it } from "vitest";
import { waves } from "../src/agent.ts";
import { type Event, parseVerdict, Runner } from "../src/runner.ts";

const head = { provider: "faux", modelId: "faux-1" };

type Setup = { runner: Runner; events: Event[]; faux: ReturnType<typeof fauxProvider> };
const open: Runner[] = [];
const dirs: string[] = [];

async function setup(responses: FauxResponseStep[], storage: Storage = new MemoryStorage()): Promise<Setup> {
	const faux = fauxProvider();
	faux.setResponses(responses);
	const models = createModels();
	models.setProvider(faux.provider);
	const events: Event[] = [];
	const runner = await Runner.open({ storage, models, emit: (e) => events.push(e) });
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
