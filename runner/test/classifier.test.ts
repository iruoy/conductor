import { afterEach, expect, it, vi } from "vitest";
import { createModels } from "@earendil-works/pi-ai/models";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { MemoryStorage, type Harness, type Storage } from "@earendil-works/pi-durable";
import { Runner } from "../src/runner.ts";
import type { Audit } from "../src/classifier.ts";
const runners: Runner[] = [];
afterEach(async () => {
	for (const r of runners.splice(0)) await r.close();
	vi.unstubAllEnvs();
});
async function setup(storage: Storage = new MemoryStorage()) {
	const models = createModels();
	const runner = await Runner.open({ storage, models, emit: () => {} });
	runners.push(runner);
	return { runner, models, storage };
}
const command = {
	type: "classify_issue",
	run_id: "run",
	issue: { key: "root", summary: "Implement", description: "Work", size: "", subtasks: [] },
};
const classify = (runner: Runner, issue = command.issue) =>
	runner.handle({ ...command, issue }) as Promise<Record<string, Audit>>;
it("keeps all explicit Size mappings authoritative and defaults disabled to high", async () => {
	vi.stubEnv("CONDUCTOR_CLASSIFIER_PROVIDER", "");
	vi.stubEnv("CONDUCTOR_CLASSIFIER_MODEL", "");
	const { runner, models } = await setup();
	const call = vi.spyOn(models, "classify");
	const sizes = ["xs", "s", "tiny", "small", "low", "m", "medium", "XL"];
	const result = (await runner.handle({
		...command,
		issue: { ...command.issue, subtasks: sizes.map((size) => ({ key: size, size })) },
	})) as Record<string, Audit>;
	expect(result.root).toMatchObject({ status: "fallback", complexity: "high" });
	sizes.forEach((s, i) =>
		expect(result[s]).toMatchObject({ status: "explicit", complexity: i < 5 ? "low" : i < 7 ? "medium" : "high" }),
	);
	expect(call).not.toHaveBeenCalled();
});
function configure(models: ReturnType<typeof createModels>) {
	vi.stubEnv("CONDUCTOR_CLASSIFIER_PROVIDER", "openai");
	vi.stubEnv("CONDUCTOR_CLASSIFIER_MODEL", "test");
	const model = { id: "test", provider: "openai", api: "openai-decisions", type: "classifier" } as any;
	vi.spyOn(models, "getModelOfType").mockReturnValue(model);
	vi.spyOn(models, "getAvailableOfType").mockResolvedValue([model]);
	return vi.spyOn(models, "checkAuth");
}
it("rejects missing credentials and subscription OAuth without classifying", async () => {
	for (const auth of [undefined, { type: "oauth" as const }]) {
		const { runner, models } = await setup();
		configure(models).mockResolvedValue(auth);
		const call = vi.spyOn(models, "classify");
		expect((await classify(runner)).root?.status).toBe("fallback");
		expect(call).not.toHaveBeenCalled();
	}
});
it("caches invalid configuration across reopen", async () => {
	vi.stubEnv("CONDUCTOR_CLASSIFIER_PROVIDER", "invalid");
	vi.stubEnv("CONDUCTOR_CLASSIFIER_MODEL", "invalid");
	const dir = await mkdtemp(join(tmpdir(), "classifier-"));
	const path = join(dir, "cache.sqlite");
	const { runner } = await setup(await openNodeSqliteStorage(path));
	const first = await classify(runner);
	await runner.close();
	runners.splice(runners.indexOf(runner), 1);
	const reopened = await setup(await openNodeSqliteStorage(path));
	const check = vi.spyOn(reopened.models, "getModelOfType");
	expect(await classify(reopened.runner)).toEqual(first);
	expect(check).not.toHaveBeenCalled();
	await reopened.runner.close();
	runners.splice(runners.indexOf(reopened.runner), 1);
	await rm(dir, { recursive: true, force: true });
});
it("batches context, caches suggestions and provider failures", async () => {
	for (const fail of [false, true]) {
		const { runner, models } = await setup();
		configure(models).mockResolvedValue({ type: "api_key" });
		const call = vi.spyOn(models, "classify").mockImplementation(async (_model, context) => {
			expect(context.state.targets).toBeDefined();
			if (fail) throw new Error("secret provider response");
			return {
				api: "openai-decisions",
				provider: "openai",
				model: "test",
				answers: {
					issue_0: { type: "choice", choice: "medium", confidence: 1, probabilities: { low: 0, medium: 1, high: 0 } },
				},
				stopReason: "stop",
				timestamp: 0,
			};
		});
		const first = await classify(runner);
		expect(first.root?.status).toBe(fail ? "fallback" : "suggested");
		expect(await classify(runner)).toEqual(first);
		expect(call).toHaveBeenCalledTimes(1);
		expect(JSON.stringify(first)).not.toContain("secret provider response");
	}
});

it.each([
	[" (S) ", "low"],
	["m-2", "medium"],
	["X-L", "high"],
	["123", "high"],
])("normalizes explicit Size %s like Prompt.complexity", async (size, complexity) => {
	const { runner, models } = await setup();
	const call = vi.spyOn(models, "classify");
	expect((await classify(runner, { ...command.issue, size })).root).toMatchObject({ status: "explicit", complexity });
	expect(call).not.toHaveBeenCalled();
});
const answer = {
	type: "choice" as const,
	choice: "medium",
	confidence: 1,
	probabilities: { low: 0, medium: 1, high: 0 },
};
const response = {
	api: "openai-decisions",
	provider: "openai",
	model: "test",
	answers: { issue_0: answer },
	stopReason: "stop" as const,
	timestamp: 0,
};
it.each([
	undefined,
	{ ...answer, type: "bool" },
	{ ...answer, choice: "unknown" },
	...[NaN, Infinity, -0.1, 1.1, "1", undefined].map((confidence) => ({ ...answer, confidence })),
	...[NaN, Infinity, -0.1, 1.1, "0"].map((low) => ({ ...answer, probabilities: { low, medium: 1, high: 0 } })),
	{ ...answer, probabilities: { medium: 1 } },
	{ ...answer, probabilities: { low: 0, medium: 0, high: 0 } },
	{ ...answer, probabilities: null },
])("caches invalid answer %# as a safe fallback", async (invalid) => {
	const { runner, models } = await setup();
	configure(models).mockResolvedValue({ type: "api_key" });
	const call = vi.spyOn(models, "classify").mockResolvedValue({ ...response, answers: { issue_0: invalid } } as any);
	const first = await classify(runner);
	expect(first.root).toMatchObject({ status: "fallback", complexity: "high", reason: "Invalid classifier answer" });
	expect(first.root).not.toHaveProperty("confidence");
	expect(await classify(runner)).toEqual(first);
	expect(call).toHaveBeenCalledTimes(1);
});
it.each([false, true])("does not repeat a paid request after SQLite restart (interrupted=%s)", async (interrupted) => {
	const dir = await mkdtemp(join(tmpdir(), "classifier-paid-"));
	const path = join(dir, "cache.sqlite");
	try {
		const { runner, models } = await setup(await openNodeSqliteStorage(path));
		configure(models).mockResolvedValue({ type: "api_key" });
		const call = vi.spyOn(models, "classify").mockResolvedValue(response);
		if (interrupted) {
			// Simulate a crash after the paid response but before its final audit commit.
			const harness = (runner as unknown as { harness: Harness }).harness;
			const commit = harness.commit.bind(harness);
			vi.spyOn(harness, "commit").mockImplementationOnce(commit).mockRejectedValueOnce(new Error("simulated crash"));
		}
		let first: Record<string, Audit> | undefined;
		if (interrupted) await expect(classify(runner)).rejects.toThrow("simulated crash");
		else {
			first = await classify(runner);
			expect(first.root).toMatchObject({
				status: "suggested",
				complexity: "medium",
				confidence: 1,
				probabilities: answer.probabilities,
			});
			expect(first.root?.reason).toContain("Moderate multi-file work or testing");
		}
		expect(call).toHaveBeenCalledTimes(1);
		await runner.close();
		runners.splice(runners.indexOf(runner), 1);
		const reopened = await setup(await openNodeSqliteStorage(path));
		configure(reopened.models).mockResolvedValue({ type: "api_key" });
		const nextCall = vi.spyOn(reopened.models, "classify");
		const restored = await classify(reopened.runner);
		if (interrupted)
			expect(restored.root).toMatchObject({
				status: "fallback",
				complexity: "high",
				reason: "Pending attempt; not retried after interruption",
			});
		else expect(restored).toEqual(first);
		expect(nextCall).not.toHaveBeenCalled();
		await reopened.runner.close();
		runners.splice(runners.indexOf(reopened.runner), 1);
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
});
it("shares linear-size context for 100 subtasks without duplicating descriptions", async () => {
	const { runner, models } = await setup();
	configure(models).mockResolvedValue({ type: "api_key" });
	const payloadSizes: number[] = [];
	const call = vi.spyOn(models, "classify").mockImplementation(async (_model, context) => {
		const issues = context.state.issues as { key: string; description: string; parentKey: string | null; subtaskKeys: string[] }[];
		const targets = context.state.targets as string[];
		const payload = JSON.stringify(context);
		payloadSizes.push(payload.length);
		expect(issues).toHaveLength(targets.length);
		expect(issues[0]).toMatchObject({ key: "root", parentKey: null, subtaskKeys: targets.slice(1) });
		for (const issue of issues) {
			expect(payload.split(issue.description)).toHaveLength(2);
			if (issue.key !== "root") expect(issue).toMatchObject({ parentKey: "root", subtaskKeys: [] });
		}
		return {
			...response,
			answers: Object.fromEntries(targets.map((_, index) => [`issue_${index}`, answer])),
		};
	});
	for (const count of [50, 100]) {
		const issue = {
			...command.issue,
			description: `root-description:${"r".repeat(4000)}:end`,
			subtasks: Array.from({ length: count }, (_, index) => ({
				key: `child-${index}`,
				summary: `Child ${index}`,
				description: `child-description-${index}:${"x".repeat(4000)}:end`,
				size: "",
				subtasks: [],
			})),
		};
		const result = await runner.handle({ ...command, run_id: `wide-${count}`, issue }) as Record<string, Audit>;
		expect(Object.values(result)).toHaveLength(count + 1);
		expect(Object.values(result).every((audit) => audit.status === "suggested")).toBe(true);
	}
	expect(call).toHaveBeenCalledTimes(2);
	// Doubling targets adds descriptions/questions linearly, not another copy of
	// every parent/sibling description for each new target.
	expect(payloadSizes[1]!).toBeLessThan(payloadSizes[0]! * 2.1);
});
