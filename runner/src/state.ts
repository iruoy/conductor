// The runner's own durable state, stored in the pi-durable session next to the conversations, so creating a run's
// conversation and recording it happen in one commit.
import { defineDoc } from "@earendil-works/pi-durable";

export type Complexity = "low" | "medium" | "high";
export type ModelChoice = { provider: string; modelId: string; reasoning?: string };
export type ModelMap = { head: ModelChoice } & Partial<Record<Complexity, ModelChoice>>;

export type Question = { text: string; answered: boolean };
export type Child = { key: string; title: string; conversationId: number };
export type Settled = { outcome: "completed" | "failed"; summary: string; error: string | null };

export type RunRecord = {
	conversationId: number;
	cwd: string;
	models: ModelMap;
	/** The newest submission to the head conversation; the run is idle once it settles. */
	submissionId: number | null;
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

export function findRunByConversation(state: Readonly<RunsState>, conversationId: number): string | undefined {
	return Object.keys(state.runs).find((id) => state.runs[id]!.conversationId === conversationId);
}
