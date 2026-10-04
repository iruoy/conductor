// The `conductor` extension the head conversation of every run selects: subagents per subtask, questions to a human,
// and moving GitHub issues through the project's statuses. Subagents select `conductor-subagent` instead, which brings only a prompt.
import type { Context } from "@earendil-works/chord";
import { type AssistantMessage, Type } from "@earendil-works/pi-ai";
import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import {
	AssistantEntry,
	type ConversationId,
	configure,
	defineExtension,
	defineTool,
	type EntryId,
	type Extension,
	section,
	type ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { type Complexity, findRunByConversation, type GithubRun, type ModelChoice, RunsDoc } from "./state.ts";

export type AgentHooks = {
	question(runId: string, qid: string, text: string): void;
	/** A subagent conversation was created or found again, so the host can stream it. */
	child(runId: string, key: string, conversationId: number): void;
};

export type GithubConfig = { baseUrl: string; token: string };

export function githubFromEnv(env: NodeJS.ProcessEnv = process.env): GithubConfig | undefined {
	const { GITHUB_TOKEN } = env;
	if (!GITHUB_TOKEN) return undefined;
	return { baseUrl: "https://api.github.com", token: GITHUB_TOKEN };
}

export function agentChoice(choice: ModelChoice): { model: { provider: string; modelId: string }; thinkingLevel?: ModelThinkingLevel } {
	const model = { provider: choice.provider, modelId: choice.modelId };
	return choice.reasoning ? { model, thinkingLevel: choice.reasoning as ModelThinkingLevel } : { model };
}

export async function answerText(api: Pick<ToolExecutionApi, "commit">, answer: EntryId, context: Context): Promise<string> {
	const entry = await api.commit((tx) => tx.entry(AssistantEntry, answer), context);
	const message = entry?.model?.[0] as AssistantMessage | undefined;
	return (message?.content ?? []).flatMap((c) => (c.type === "text" ? [c.text] : [])).join("");
}

const HEAD_PREAMBLE = `You are Conductor's autonomous software engineer. You work unattended on one GitHub issue in a git working tree.
Work carefully and verify your changes. Nobody watches your output live; the only ways to reach a human are the
ask_human tool and your final message. End your final message with a line \`DONE\` when the issue is implemented and
pushed, or \`FAILED: <reason>\` when you cannot complete it.`;

const SUBAGENT_PREAMBLE = `You are a subagent of Conductor's autonomous software engineer. You implement exactly one subtask in a git working
tree that other subagents may be editing at the same time: touch only what your subtask needs. When you need a
decision you cannot make yourself, stop and answer with a line starting \`NEEDS_INPUT:\` followed by the question.
Otherwise finish with a short summary of what you changed and how you verified it.`;

export const SubagentPrompt = defineExtension({
	name: "conductor-subagent",
	sections: [
		section("preamble", () => SUBAGENT_PREAMBLE, { tag: false }),
		section("cwd", (input) => input.env?.cwd),
	],
});

const SubtaskSchema = Type.Object({
	key: Type.String({ description: "Key of the subtask, e.g. #124" }),
	title: Type.String(),
	complexity: Type.Optional(
		Type.Union([Type.Literal("low"), Type.Literal("medium"), Type.Literal("high")], {
			description: "Picks the model; defaults to high",
		}),
	),
	instructions: Type.String({ description: "Everything the subagent needs: it cannot see this conversation" }),
	dependsOn: Type.Optional(Type.Array(Type.String(), { description: "Keys of subtasks that must finish first" })),
});

type Subtask = { key: string; title: string; complexity?: Complexity; instructions: string; dependsOn?: string[] };
type SubtaskResult = { key: string; status: "done" | "needs_input" | "failed" | "skipped"; text: string };

/** Orders subtasks in waves: each wave holds the tasks whose dependencies are all in earlier waves. */
export function waves(tasks: readonly Subtask[]): Subtask[][] {
	const keys = new Set(tasks.map((t) => t.key));
	const placed = new Set<string>();
	const remaining = [...tasks];
	const result: Subtask[][] = [];
	while (remaining.length > 0) {
		const ready = remaining.filter((t) => (t.dependsOn ?? []).every((d) => placed.has(d) || !keys.has(d)));
		// A cycle: run the rest together rather than never.
		const wave = ready.length > 0 ? ready : [...remaining];
		for (const t of wave) remaining.splice(remaining.indexOf(t), 1);
		for (const t of wave) placed.add(t.key);
		result.push(wave);
	}
	return result;
}

export function createConductorExtension(hooks: AgentHooks, github: GithubConfig | undefined = githubFromEnv()): Extension {
	const runIdOf = async (api: ToolExecutionApi, context: Context): Promise<string> => {
		const state = await api.snapshot(RunsDoc, context);
		const runId = state ? findRunByConversation(state, api.conversationId as number) : undefined;
		if (runId === undefined) throw new Error("This conversation does not belong to a Conductor run");
		return runId;
	};

	const runSubtask = async (
		api: ToolExecutionApi,
		runId: string,
		task: Subtask,
		context: Context,
	): Promise<SubtaskResult> => {
		const slot = `${api.taskId}/${task.key}`;
		const child = await api.commit(async (tx) => {
			const run = (await tx.doc(RunsDoc)).runs[runId]!;
			const existing = run.children[slot];
			if (existing !== undefined) return existing.conversationId;
			const created = await tx.createConversation({ ownership: { kind: "task", taskId: api.taskId } });
			const choice = run.models[task.complexity ?? "high"] ?? run.models.high ?? run.models.head;
			await configure(tx, created.id, {
				...agentChoice(choice),
				extensions: [CodingTools, SubagentPrompt],
				cwd: run.cwd,
				instructions: `Subtask ${task.key}: ${task.title}`,
			});
			run.children[slot] = { key: task.key, title: task.title, conversationId: created.id as number };
			return created.id as number;
		}, context);
		hooks.child(runId, task.key, child);

		const handle = (await api.conversation(child as ConversationId, context))!;
		const request = { type: "input", content: task.instructions, requestId: `subtask:${slot}` } as const;
		const settled = await (await handle.submit(request, context)).wait(context);
		if (settled.status !== "done" || settled.type !== "input") {
			return { key: task.key, status: "failed", text: `${settled.reason ?? "failed"} ${settled.detail ?? ""}`.trim() };
		}
		const text = await answerText(api, settled.answer, context);
		const needsInput = /^NEEDS_INPUT:/m.test(text);
		return { key: task.key, status: needsInput ? "needs_input" : "done", text };
	};

	const runSubagents = defineTool({
		name: "run_subagents",
		description:
			"Run subtasks with subagents, one fresh conversation per subtask in the same working tree. Subtasks without " +
			"unfinished dependencies run in parallel; dependents start once their dependencies are done and are skipped " +
			"when one did not finish. Returns each subagent's final answer. A subagent that needs a decision answers " +
			"with NEEDS_INPUT: decide yourself or ask a human, then run that subtask again with the answer included.",
		parameters: Type.Object({ tasks: Type.Array(SubtaskSchema, { minItems: 1 }) }),
		// A rerun after a crash finds the children and submissions it already made.
		replay: "safe",
		execute: async (args, api, context) => {
			const runId = await runIdOf(api, context);
			const results = new Map<string, SubtaskResult>();
			for (const wave of waves(args.tasks as Subtask[])) {
				const runnable: Subtask[] = [];
				for (const task of wave) {
					const blocker = (task.dependsOn ?? []).find((d) => results.has(d) && results.get(d)!.status !== "done");
					if (blocker === undefined) runnable.push(task);
					else results.set(task.key, { key: task.key, status: "skipped", text: `dependency ${blocker} did not finish` });
				}
				const settled = await Promise.allSettled(runnable.map((t) => runSubtask(api, runId, t, context)));
				settled.forEach((outcome, i) => {
					const key = runnable[i]!.key;
					results.set(
						key,
						outcome.status === "fulfilled"
							? outcome.value
							: { key, status: "failed", text: String((outcome.reason as Error)?.message ?? outcome.reason) },
					);
				});
				api.output(`${[...results.values()].map((r) => `${r.key}: ${r.status}`).join("\n")}\n`);
			}
			const text = (args.tasks as Subtask[])
				.map((t) => results.get(t.key)!)
				.map((r) => `## ${r.key}: ${r.status}\n\n${r.text}`)
				.join("\n\n");
			return { content: [{ type: "text", text }] };
		},
	});

	const askHuman = defineTool({
		name: "ask_human",
		description:
			"Ask a human a question you cannot answer from the issue or the code. Your turn ends; the answer arrives as " +
			"your next message, possibly much later.",
		parameters: Type.Object({ question: Type.String() }),
		replay: "safe",
		execute: async (args, api, context) => {
			const runId = await runIdOf(api, context);
			const qid = `q${api.taskId}`;
			await api.commit(async (tx) => {
				const run = (await tx.doc(RunsDoc)).runs[runId]!;
				run.questions[qid] ??= { text: args.question, answered: false };
			}, context);
			hooks.question(runId, qid, args.question);
			return {
				content: [{ type: "text", text: "The question was sent. Stop now; the answer will arrive as your next message." }],
				control: { terminate: true },
			};
		},
	});

	const setStatusTool = defineTool({
		name: "set_issue_status",
		description:
			"Move the issue of this run or one of its subtasks to the project status with this name. Moving a subtask to " +
			"the done status also closes its issue. Does nothing when it is already there.",
		parameters: Type.Object({
			number: Type.Integer({ description: "Issue number, without the #" }),
			status: Type.String({ description: "e.g. In progress, Done" }),
		}),
		replay: "safe",
		execute: async (args, api, context) => {
			if (github === undefined) throw new Error("GitHub is not configured for the runner");
			const runId = await runIdOf(api, context);
			const run = (await api.snapshot(RunsDoc, context))?.runs[runId]?.github;
			if (run === undefined) throw new Error("This run has no GitHub project");
			return { content: [{ type: "text", text: await setIssueStatus(github, run, args.number, args.status) }] };
		},
	});

	return defineExtension({
		name: "conductor",
		tools: [runSubagents, askHuman, setStatusTool],
		sections: [
			section("preamble", () => HEAD_PREAMBLE, { tag: false }),
			section("cwd", (input) => input.env?.cwd),
		],
	});
}

async function setIssueStatus(github: GithubConfig, run: GithubRun, number: number, status: string): Promise<string> {
	const same = (name: string) => name.toLowerCase() === status.toLowerCase();
	const name = Object.keys(run.statuses).find(same);
	if (name === undefined) {
		throw new Error(`The project has no status ${status}; options: ${Object.keys(run.statuses).join(", ")}`);
	}
	const headers = {
		Authorization: `Bearer ${github.token}`,
		Accept: "application/vnd.github+json",
		"Content-Type": "application/json",
		"X-GitHub-Api-Version": "2022-11-28",
	};
	const done: string[] = [];

	const item = run.items[String(number)];
	if (item === undefined) {
		done.push(`#${number} is not in the project, so it has no status`);
	} else {
		const query = `mutation SetStatus($project: ID!, $item: ID!, $field: ID!, $option: String!) {
			updateProjectV2ItemFieldValue(
				input: {projectId: $project, itemId: $item, fieldId: $field, value: {singleSelectOptionId: $option}}
			) { projectV2Item { id } }
		}`;
		const variables = { project: run.project_id, item, field: run.status_field_id, option: run.statuses[name] };
		const response = await fetch(`${github.baseUrl}/graphql`, { method: "POST", headers, body: JSON.stringify({ query, variables }) });
		if (!response.ok) throw new Error(`GitHub #${number} status: HTTP ${response.status}`);
		const { errors } = (await response.json()) as { errors?: { message: string }[] };
		if (errors?.length) throw new Error(`GitHub #${number} status: ${errors.map((e) => e.message).join("; ")}`);
		done.push(`#${number} moved to ${name}`);
	}

	// GitHub counts a sub-issue as done once it is closed, whatever its status says.
	if (name.toLowerCase() === run.done_status.toLowerCase()) {
		const response = await fetch(`${github.baseUrl}/repos/${run.repo}/issues/${number}`, {
			method: "PATCH",
			headers,
			body: JSON.stringify({ state: "closed", state_reason: "completed" }),
		});
		if (!response.ok) throw new Error(`GitHub #${number} close: HTTP ${response.status}`);
		done.push(`#${number} closed`);
	}
	return done.join("; ");
}
