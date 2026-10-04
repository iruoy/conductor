// The protocol core: commands from Phoenix in, replies and events out. Everything a restart needs lives in the
// pi-durable session (conversations, tasks, and RunsDoc), so `open()` on the same storage picks every run up again.
import { isAbsolute } from "node:path";
import type { Context } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Models } from "@earendil-works/pi-ai";
import {
	type AgentEvent,
	type AgentEventStream,
	type ConversationId,
	configure,
	type Extension,
	createRegistry,
	Harness,
	type SettledSubmissionRecord,
	type Storage,
	type SubmissionId,
	watchEvents,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { agentChoice, answerText, createConductorExtension, type GithubConfig, githubFromEnv, SubagentPrompt } from "./agent.ts";
import { type GithubRun, type ModelMap, type RunRecord, RunsDoc, type Settled } from "./state.ts";

export const VERSION = "0.1.0";

export type Event = Record<string, unknown> & { type: string };
export type Command = { id?: string | number; type: string; [key: string]: unknown };

export type RunnerOptions = {
	storage: Storage;
	models: Models;
	emit: (event: Event) => void;
	github?: GithubConfig;
	context?: Context;
};

export class ProtocolError extends Error {}

const ctx = BACKGROUND_CONTEXT;

export class Runner {
	private harness!: Harness;
	private conductor!: Extension;
	private readonly emitEvent: (event: Event) => void;
	private readonly models: Models;
	private seq = 0;
	private readonly locks = new Map<string, Promise<unknown>>();
	private readonly tracking = new Set<string>();
	private readonly streams = new Map<string, Map<number, AgentEventStream>>();
	private resumed: string[] = [];
	private closed = false;

	private constructor(options: RunnerOptions) {
		this.models = options.models;
		this.emitEvent = options.emit;
	}

	static async open(options: RunnerOptions): Promise<Runner> {
		const runner = new Runner(options);
		const conductor = createConductorExtension(
			{
				question: (runId, qid, text) => runner.emit({ type: "question", run_id: runId, qid, text }),
				child: (runId, key, conversationId) =>
					void runner.attach(runId, conversationId, `sub:${key}`).catch((error) =>
						runner.emit({ type: "log", level: "error", message: `attach ${runId} sub:${key}: ${error}` }),
					),
			},
			options.github ?? githubFromEnv(),
		);
		const registry = createRegistry();
		registry.install(CodingTools);
		registry.install(conductor);
		registry.install(SubagentPrompt);
		runner.harness = await Harness.open(
			options.storage,
			{
				models: options.models,
				registry,
				settings: { extensions: [CodingTools], retry: { maxRetries: 5 } },
				env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? process.cwd() }),
				onReport: (error) => runner.emit({ type: "log", level: "error", message: String(error) }),
			},
			options.context ?? ctx,
		);
		runner.conductor = conductor;
		runner.harness.resume();
		const state = await runner.state();
		runner.resumed = Object.keys(state.runs).filter((id) => state.runs[id]!.status === "running");
		for (const runId of runner.resumed) runner.track(runId);
		runner.emit({ type: "ready", version: VERSION, resumed: runner.resumed });
		return runner;
	}

	async handle(command: Command): Promise<unknown> {
		switch (command.type) {
			case "hello":
				return { version: VERSION, resumed: this.resumed };
			case "models":
				return this.listModels();
			case "start_run":
				return this.startRun(command);
			case "answer":
				return this.answer(command);
			case "abort":
				return this.abort(str(command, "run_id"));
			case "sync":
				return this.sync();
			default:
				throw new ProtocolError(`unknown command ${command.type}`);
		}
	}

	/** Runs a command and turns its outcome into a reply line. */
	async dispatch(command: Command): Promise<void> {
		try {
			const result = await this.handle(command);
			this.emitRaw({ type: "reply", id: command.id ?? null, ok: true, result: result ?? null });
		} catch (error) {
			this.emitRaw({ type: "reply", id: command.id ?? null, ok: false, error: (error as Error).message ?? String(error) });
		}
	}

	async close(): Promise<void> {
		this.closed = true;
		for (const streams of this.streams.values()) for (const stream of streams.values()) await stream.stop();
		await this.harness.close(ctx);
	}

	// ─── Commands ───────────────────────────────────────────────────────────

	private async listModels() {
		const available = await this.models.getAvailable();
		return available.map((m) => ({
			provider: m.provider,
			id: m.id,
			name: m.name,
			reasoning: m.reasoning,
			levels: m.reasoning
				? ["minimal", "low", "medium", "high", "xhigh"].filter((l) => (m.thinkingLevelMap as Record<string, unknown> | undefined)?.[l] !== null)
				: [],
		}));
	}

	private startRun(command: Command) {
		const runId = str(command, "run_id");
		const cwd = str(command, "cwd");
		if (!isAbsolute(cwd)) throw new ProtocolError(`start_run: cwd must be absolute, got ${cwd}`);
		const prompt = str(command, "prompt");
		const models = command.models as ModelMap | undefined;
		const github = command.github as GithubRun | undefined;
		if (models?.head?.provider === undefined) throw new ProtocolError("models.head is required");

		return this.serial(runId, async () => {
			const conversationId = await this.harness.commit(async (tx) => {
				const doc = await tx.doc(RunsDoc);
				const existing = doc.runs[runId];
				if (existing !== undefined) return existing.conversationId;
				const created = await tx.createConversation({ ownership: { kind: "ownerless" } });
				await configure(tx, created.id, { ...agentChoice(models.head), extensions: [CodingTools, this.conductor], cwd });
				doc.runs[runId] = {
					conversationId: created.id as number,
					cwd,
					models,
					...(github ? { github } : {}),
					submissionId: null,
					status: "running",
					aborted: false,
					questions: {},
					children: {},
					settled: null,
				};
				return created.id as number;
			}, ctx);
			const run = (await this.run(runId))!;
			if (run.submissionId === null) {
				const conversation = (await this.harness.conversation(conversationId as ConversationId, ctx))!;
				const submission = await conversation.submit({ type: "input", content: prompt, requestId: `start:${runId}` }, ctx);
				await this.update(runId, (r) => {
					r.submissionId ??= submission.id as number;
				});
			}
			if (run.status === "running") {
				this.emit({ type: "run_state", run_id: runId, status: "running" });
				this.track(runId);
			}
			return { conversation_id: conversationId, status: run.status };
		});
	}

	private answer(command: Command) {
		const runId = str(command, "run_id");
		const qid = str(command, "qid");
		const text = str(command, "text");
		return this.serial(runId, async () => {
			const run = await this.run(runId);
			if (run === undefined) throw new ProtocolError(`unknown run ${runId}`);
			if (run.status === "settled") throw new ProtocolError(`run ${runId} is settled`);
			const question = run.questions[qid];
			if (question === undefined) throw new ProtocolError(`unknown question ${qid}`);
			const conversation = (await this.harness.conversation(run.conversationId as ConversationId, ctx))!;
			const content = `A human answered your question.\n\nQuestion: ${question.text}\n\nAnswer: ${text}`;
			const submission = await conversation.submit({ type: "input", content, requestId: `answer:${qid}` }, ctx);
			await this.update(runId, (r) => {
				r.questions[qid]!.answered = true;
				r.submissionId = submission.id as number;
				r.status = "running";
			});
			this.emit({ type: "run_state", run_id: runId, status: "running" });
			this.track(runId);
			return { submission_id: submission.id };
		});
	}

	private abort(runId: string) {
		return this.serial(runId, async () => {
			const run = await this.run(runId);
			if (run === undefined) throw new ProtocolError(`unknown run ${runId}`);
			if (run.status === "settled") return { status: "settled" };
			await this.update(runId, (r) => {
				r.aborted = true;
			});
			const conversation = await this.harness.conversation(run.conversationId as ConversationId, ctx);
			await conversation?.abort(ctx);
			// A run waiting for input has no submission left to settle it.
			if (run.status === "waiting_for_input") await this.settle(runId, { outcome: "failed", summary: "", error: "aborted" });
			return { status: "aborting" };
		});
	}

	private async sync() {
		const state = await this.state();
		return {
			runs: Object.entries(state.runs).map(([runId, run]) => ({
				run_id: runId,
				conversation_id: run.conversationId,
				status: run.status,
				settled: run.settled,
				questions: Object.entries(run.questions).map(([qid, q]) => ({ qid, text: q.text, answered: q.answered })),
				children: Object.values(run.children),
			})),
		};
	}

	// ─── Run lifecycle ──────────────────────────────────────────────────────

	/** Follows a running run until its newest submission settles, then decides what that means. Idempotent. */
	private track(runId: string): void {
		if (this.tracking.has(runId)) return;
		this.tracking.add(runId);
		void (async () => {
			const run = await this.run(runId);
			if (run === undefined) return;
			await this.attach(runId, run.conversationId, "head");
			for (const child of Object.values(run.children)) await this.attach(runId, child.conversationId, `sub:${child.key}`);
			let settled: SettledSubmissionRecord | undefined;
			let waitedFor: number | null = null;
			for (;;) {
				const current = (await this.run(runId))!;
				if (current.submissionId === waitedFor || current.submissionId === null) break;
				waitedFor = current.submissionId;
				const submission = await this.harness.submission(waitedFor as SubmissionId, ctx);
				settled = await submission?.wait(ctx);
			}
			this.tracking.delete(runId);
			if (settled !== undefined && !this.closed) await this.serial(runId, () => this.evaluate(runId, settled!));
		})().catch((error) => {
			this.tracking.delete(runId);
			if (!this.closed) this.emit({ type: "log", level: "error", message: `track ${runId}: ${(error as Error).stack ?? error}` });
		});
	}

	private async evaluate(runId: string, settled: SettledSubmissionRecord): Promise<void> {
		const run = (await this.run(runId))!;
		// An answer submitted meanwhile started a newer submission; its own tracker decides.
		if (run.status !== "running" || run.submissionId !== (settled.id as number)) return;
		if (run.aborted) return this.settle(runId, { outcome: "failed", summary: "", error: "aborted" });
		if (settled.status !== "done" || settled.type !== "input") {
			const reason = [settled.reason, settled.detail].filter(Boolean).join(": ");
			return this.settle(runId, { outcome: "failed", summary: "", error: reason || "the run ended without an answer" });
		}
		const text = await answerText(this.harness, settled.answer, ctx);
		const open = Object.entries(run.questions).filter(([, q]) => !q.answered);
		if (open.length > 0) return this.wait(runId, open);

		const verdict = parseVerdict(text);
		if (verdict !== undefined) return this.settle(runId, { ...verdict, summary: text });
		// No verdict: hand the final message to a human, who can answer it or abort.
		const qid = `end${settled.id}`;
		const question = `The agent stopped without DONE or FAILED. Its last message:\n\n${text}`;
		await this.update(runId, (r) => {
			r.questions[qid] ??= { text: question, answered: false };
		});
		this.emit({ type: "question", run_id: runId, qid, text: question });
		return this.wait(runId, [[qid, { text: question }]]);
	}

	private async wait(runId: string, open: [string, { text: string }][]): Promise<void> {
		await this.update(runId, (r) => {
			r.status = "waiting_for_input";
		});
		for (const [qid, q] of open) this.emit({ type: "question", run_id: runId, qid, text: q.text });
		this.emit({ type: "run_state", run_id: runId, status: "waiting_for_input" });
	}

	private async settle(runId: string, settled: Settled): Promise<void> {
		await this.update(runId, (r) => {
			r.status = "settled";
			r.settled = settled;
		});
		this.emit({ type: "run_settled", run_id: runId, ...settled });
		const streams = this.streams.get(runId);
		this.streams.delete(runId);
		// Let the last event batches of the run reach Phoenix before detaching.
		setTimeout(() => {
			for (const stream of streams?.values() ?? []) void stream.stop();
		}, 50);
	}

	/** Streams one conversation's agent events, starting with a snapshot. Attaching twice is a no-op. */
	private async attach(runId: string, conversationId: number, role: string): Promise<void> {
		let streams = this.streams.get(runId);
		if (streams === undefined) this.streams.set(runId, (streams = new Map()));
		if (streams.has(conversationId)) return;
		const stream = await watchEvents(this.harness, conversationId as ConversationId, ctx);
		streams.set(conversationId, stream);
		const send = (event: AgentEvent) =>
			this.emit({ type: "agent_event", run_id: runId, conversation: conversationId, role, event });
		send(stream.snapshot);
		stream.start(async (events) => {
			for (const event of events) send(event);
		});
	}

	// ─── State helpers ──────────────────────────────────────────────────────

	private async state() {
		return (await this.harness.snapshot(RunsDoc, ctx)) ?? { runs: {} };
	}

	private async run(runId: string): Promise<Readonly<RunRecord> | undefined> {
		return (await this.state()).runs[runId];
	}

	private update(runId: string, change: (run: RunRecord) => void): Promise<void> {
		return this.harness.commit(async (tx) => {
			change((await tx.doc(RunsDoc)).runs[runId]!);
		}, ctx);
	}

	/** Serializes the commands and decisions of one run. */
	private serial<T>(key: string, fn: () => Promise<T>): Promise<T> {
		const previous = this.locks.get(key) ?? Promise.resolve();
		const next = previous.catch(() => {}).then(fn);
		this.locks.set(key, next);
		void next.finally(() => {
			if (this.locks.get(key) === next) this.locks.delete(key);
		}).catch(() => {});
		return next;
	}

	private emit(event: Event): void {
		this.emitRaw({ ...event, seq: ++this.seq });
	}

	private emitRaw(event: Event): void {
		this.emitEvent(event);
	}
}

/** The verdict in the agent's final message: its last `DONE` or `FAILED: reason` line. */
export function parseVerdict(text: string): Pick<Settled, "outcome" | "error"> | undefined {
	const lines = text.split("\n").map((l) => l.trim().replace(/^[*_`#\s]+|[*_`\s]+$/g, ""));
	for (let i = lines.length - 1; i >= 0; i--) {
		const line = lines[i]!;
		if (/^DONE\b/.test(line)) return { outcome: "completed", error: null };
		const failed = /^FAILED\b:?\s*(.*)$/.exec(line);
		if (failed) return { outcome: "failed", error: failed[1] || "the agent reported a failure" };
	}
	return undefined;
}

function str(command: Command, key: string): string {
	const value = command[key];
	if (typeof value !== "string" || value === "") throw new ProtocolError(`${command.type}: ${key} is required`);
	return value;
}
