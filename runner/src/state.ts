// The runner's own durable state, stored in the pi-durable session next to the conversations, so creating a run's
// conversation and recording it happen in one commit.
import { defineDoc } from "@earendil-works/pi-durable";

export type Complexity = "low" | "medium" | "high";
export type ModelChoice = { provider: string; modelId: string; reasoning?: string };
export type ModelMap = { head: ModelChoice } & Partial<Record<Complexity, ModelChoice>>;

export type Question = { text: string; answered: boolean };
export type Child = { key: string; title: string; conversationId: number };
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
	messages?: number[];
	status: "running" | "waiting_for_input" | "settled";
	aborted: boolean;
	questions: Record<string, Question>;
	/** Subagent conversations, keyed by `<tool task id>/<subtask key>`. */
	children: Record<string, Child>;
	settled: Settled | null;
};

export type RunsState = { runs: Record<string, RunRecord> };

export const RunsDoc = defineDoc<RunsState>({
	kind: "conductor.runs",
	version: 1,
	scope: "session",
	initial: () => ({ runs: {} }),
});

/** The run of a head conversation or of one of its subagent conversations. */
export function findRunByConversation(state: Readonly<RunsState>, conversationId: number): string | undefined {
	return Object.keys(state.runs).find((id) => {
		const run = state.runs[id]!;
		return run.conversationId === conversationId || Object.values(run.children).some((c) => c.conversationId === conversationId);
	});
}
