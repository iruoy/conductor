import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createModels } from "@earendil-works/pi-ai/models";
import { type Harness, MemoryStorage, type Storage } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { afterEach, expect, it, vi } from "vitest";
import type { Audit } from "../src/classifier.ts";
import { Runner } from "../src/runner.ts";

const runners: Runner[] = [];
afterEach(async () => {
	for (const runner of runners.splice(0)) await runner.close();
	vi.unstubAllEnvs();
});

async function setup(storage: Storage = new MemoryStorage()) {
	const models = createModels();
	const runner = await Runner.open({ storage, models, emit: () => {} });
	runners.push(runner);
	return { runner, models };
}

async function close(runner: Runner) {
	await runner.close();
	runners.splice(runners.indexOf(runner), 1);
}

type Issue = { key: string; summary?: string; description?: string; size: string; subtasks?: Issue[] };
const root: Issue = { key: "root", summary: "Implement", description: "Work", size: "", subtasks: [] };
const classify = (runner: Runner, issue: Issue = root, runId = "run") =>
	runner.handle({ type: "classify_issue", run_id: runId, issue }) as Promise<Record<string, Audit>>;

/** Enables the classifier with a model the credentials can use; returns the auth check to stub. */
function enable(models: ReturnType<typeof createModels>) {
	vi.stubEnv("CONDUCTOR_CLASSIFIER_PROVIDER", "openai");
	vi.stubEnv("CONDUCTOR_CLASSIFIER_MODEL", "test");
	const model = { id: "test", provider: "openai", api: "openai-decisions", type: "classifier" } as never;
	vi.spyOn(models, "getModelOfType").mockReturnValue(model);
	vi.spyOn(models, "getAvailableOfType").mockResolvedValue([model]);
	return vi.spyOn(models, "checkAuth");
}

const answer = { type: "choice" as const, choice: "medium", confidence: 1, probabilities: { low: 0, medium: 1, high: 0 } };
const response = { api: "openai-decisions", provider: "openai", model: "test", answers: { issue_0: answer }, stopReason: "stop" as const, timestamp: 0 };

it("takes an explicit Size as authoritative and falls back to high when disabled", async () => {
	vi.stubEnv("CONDUCTOR_CLASSIFIER_PROVIDER", "");
	vi.stubEnv("CONDUCTOR_CLASSIFIER_MODEL", "");
	const { runner, models } = await setup();
	const call = vi.spyOn(models, "classify");
	const sizes = { xs: "low", s: "low", tiny: "low", small: "low", low: "low", " (S) ": "low", m: "medium", medium: "medium", "m-2": "medium", XL: "high", "X-L": "high", "123": "high" };
	const result = await classify(runner, { ...root, subtasks: Object.keys(sizes).map((size) => ({ key: size, size })) });
	expect(result.root).toMatchObject({ status: "fallback", complexity: "high" });
	for (const [size, complexity] of Object.entries(sizes)) expect(result[size]).toMatchObject({ status: "explicit", complexity });
	expect(call).not.toHaveBeenCalled();
});

it("rejects missing credentials and subscription OAuth without classifying", async () => {
	for (const auth of [undefined, { type: "oauth" as const }]) {
		const { runner, models } = await setup();
		enable(models).mockResolvedValue(auth);
		const call = vi.spyOn(models, "classify");
		expect((await classify(runner)).root?.status).toBe("fallback");
		expect(call).not.toHaveBeenCalled();
	}
});

it("caches a provider failure without its error text", async () => {
	const { runner, models } = await setup();
	enable(models).mockResolvedValue({ type: "api_key" });
	const call = vi.spyOn(models, "classify").mockRejectedValue(new Error("secret provider response"));
	const first = await classify(runner);
	expect(first.root).toMatchObject({ status: "fallback", reason: "Classifier provider failed" });
	expect(await classify(runner)).toEqual(first);
	expect(call).toHaveBeenCalledTimes(1);
	expect(JSON.stringify(first)).not.toContain("secret provider response");
});

it("falls back safely on invalid answers", async () => {
	const { runner, models } = await setup();
	enable(models).mockResolvedValue({ type: "api_key" });
	const invalid = [
		undefined,
		{ ...answer, type: "bool" },
		{ ...answer, choice: "unknown" },
		...[NaN, 1.1, "1", undefined].map((confidence) => ({ ...answer, confidence })),
		...[-0.1, "0"].map((low) => ({ ...answer, probabilities: { low, medium: 1, high: 0 } })),
		{ ...answer, probabilities: { medium: 1 } },
		{ ...answer, probabilities: { low: 0, medium: 0, high: 0 } },
		{ ...answer, probabilities: null },
	];
	for (const [index, value] of invalid.entries()) {
		vi.spyOn(models, "classify").mockResolvedValueOnce({ ...response, answers: { issue_0: value } } as never);
		const audit = (await classify(runner, root, `invalid-${index}`)).root;
		expect(audit, `case ${index}`).toMatchObject({ status: "fallback", complexity: "high", reason: "Invalid classifier answer" });
		expect(audit).not.toHaveProperty("confidence");
	}
});

it.each([false, true])("never repeats a paid request after a restart (interrupted=%s)", async (interrupted) => {
	const dir = await mkdtemp(join(tmpdir(), "classifier-"));
	const path = join(dir, "cache.sqlite");
	try {
		const { runner, models } = await setup(await openNodeSqliteStorage(path));
		enable(models).mockResolvedValue({ type: "api_key" });
		const call = vi.spyOn(models, "classify").mockResolvedValue(response);
		let first: Record<string, Audit> | undefined;
		if (interrupted) {
			// A crash after the paid response but before its audit commits.
			const harness = (runner as unknown as { harness: Harness }).harness;
			const commit = harness.commit.bind(harness);
			vi.spyOn(harness, "commit").mockImplementationOnce(commit).mockRejectedValueOnce(new Error("simulated crash"));
			await expect(classify(runner)).rejects.toThrow("simulated crash");
		} else {
			first = await classify(runner);
			expect(first.root).toMatchObject({ status: "suggested", complexity: "medium", confidence: 1, probabilities: answer.probabilities });
		}
		expect(call).toHaveBeenCalledTimes(1);
		await close(runner);

		const reopened = await setup(await openNodeSqliteStorage(path));
		enable(reopened.models).mockResolvedValue({ type: "api_key" });
		const again = vi.spyOn(reopened.models, "classify");
		const restored = await classify(reopened.runner);
		if (first) expect(restored).toEqual(first);
		else expect(restored.root).toMatchObject({ status: "fallback", complexity: "high", reason: "Pending attempt; not retried after interruption" });
		expect(again).not.toHaveBeenCalled();
		await close(reopened.runner);
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
});

it("classifies a whole tree in one request that holds each description once", async () => {
	const { runner, models } = await setup();
	enable(models).mockResolvedValue({ type: "api_key" });
	const call = vi.spyOn(models, "classify").mockImplementation(async (_model, context) => {
		const issues = context.state.issues as { key: string; description: string }[];
		const targets = context.state.targets as string[];
		expect(issues).toMatchObject([
			{ key: "root", parentKey: null, subtaskKeys: ["child-0", "child-1", "child-2"] },
			...targets.slice(1).map((key) => ({ key, parentKey: "root", subtaskKeys: [] })),
		]);
		const payload = JSON.stringify(context);
		for (const issue of issues) expect(payload.split(issue.description)).toHaveLength(2);
		return { ...response, answers: Object.fromEntries(targets.map((_, index) => [`issue_${index}`, answer])) };
	});
	const subtasks = [0, 1, 2].map((index) => ({ key: `child-${index}`, description: `child-description-${index}`, size: "" }));
	const result = await classify(runner, { ...root, description: "root-description", subtasks });
	expect(Object.values(result).map((audit) => audit.status)).toEqual(["suggested", "suggested", "suggested", "suggested"]);
	expect(call).toHaveBeenCalledTimes(1);
});
