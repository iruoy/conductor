// The runner's own durable state, stored in the pi-durable session next to the conversations, so creating a run's
// conversation and recording it happen in one commit.
import { defineDoc, defineSignal } from "@earendil-works/pi-durable";
import { obj, str } from "@earendil-works/pi-schema";

export type Complexity = "low" | "medium" | "high";
export type ModelChoice = { provider: string; modelId: string; reasoning?: string };
export type ModelMap = { head: ModelChoice } & Partial<Record<Complexity, ModelChoice>>;

/** `taskId` is the parked `ask_human` call that waits for the answer; a question the runner asked itself has none. */
type Question = { text: string; answered: boolean; taskId?: number };
type Child = { key: string; title: string; conversationId: number };
/** The GitHub Project of a run: what `set_issue_status` needs to move the run's issue and its subtasks. */
export type GithubRun = {
	/** owner/name */
	repo: string;
	project_id: string;
	status_field_id: string;
	/** Status option ids by name. */
	statuses: Record<string, string>;
	/** Moving an issue to this status also closes it. */
	done_status: string;
	/** Project item ids by issue number. */
	items: Record<string, string>;
};
export type Settled = { outcome: "completed" | "failed"; summary: string; error: string | null };

export type RunRecord = {
	conversationId: number;
	cwd: string;
	models: ModelMap;
	github?: GithubRun;
	/** The newest submission to the head conversation; the run is idle once it settles. */
	submissionId: number | null;
	/** What a human told the agent while it worked, as submissions to the head conversation, oldest first. */
	messages: number[];
	status: "running" | "waiting_for_input" | "settled";
	aborted: boolean;
	questions: Record<string, Question>;
	/** Subagent conversations, keyed by `<tool task id>/<subtask key>`. */
	children: Record<string, Child>;
	settled: Settled | null;
};

type RunsState = { runs: Record<string, RunRecord> };

export const RunsDoc = defineDoc<RunsState>({
	kind: "conductor.runs",
	version: 1,
	scope: "session",
	initial: () => ({ runs: {} }),
	// Changes are stored as deltas; nothing here needs a checkpoint.
	checkpointWhen: () => false,
});

/** The run of a head conversation or of one of its subagent conversations. */
export function findRunByConversation(state: Readonly<RunsState>, conversationId: number): string | undefined {
	return Object.keys(state.runs).find((id) => {
		const run = state.runs[id]!;
		return run.conversationId === conversationId || Object.values(run.children).some((c) => c.conversationId === conversationId);
	});
}

/** A human's answer to an `ask_human` question, delivered to the parked call under the question's id. */
export const HumanAnswer = defineSignal({ name: "conductor.answer", version: 1, schema: obj({ text: str() }) });
