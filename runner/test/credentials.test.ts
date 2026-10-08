import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as ctx } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { type Harness, MemoryStorage } from "@earendil-works/pi-durable";
import { afterEach, describe, expect, it } from "vitest";
import { FileCredentialStore } from "../src/credentials.ts";
import { Runner, type Event } from "../src/runner.ts";
import { RunsDoc } from "../src/state.ts";

const directories: string[] = [];
const runners: Runner[] = [];
afterEach(async () => {
	for (const runner of runners.splice(0)) await runner.close();
	for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

function fixture() {
	const directory = mkdtempSync(join(tmpdir(), "conductor-credentials-"));
	directories.push(directory);
	const path = join(directory, "auth.json");
	return { directory, path, store: new FileCredentialStore(path) };
}

describe("credential inspection secrets", () => {
	it("collects only API keys and OAuth access/refresh strings without changing files", () => {
		const { directory, path, store } = fixture();
		const text = JSON.stringify({
			api: { type: "api_key", key: "local-api-secret", env: { ACCOUNT: "account-metadata" } },
			oauth: { type: "oauth", access: "local-access-secret", refresh: "local-refresh-secret", expires: 0, accountId: "oauth-metadata" },
			invalidFields: { type: "oauth", access: 42, refresh: null, extra: "not-a-secret" },
			unknown: { type: "unknown", key: "not-a-known-key" },
		});
		writeFileSync(path, text);
		const before = statSync(path);
		expect(store.redactionValues()).toEqual(["local-api-secret", "local-access-secret", "local-refresh-secret"]);
		expect(store.redactionValues()).toEqual(["local-api-secret", "local-access-secret", "local-refresh-secret"]);
		expect(readFileSync(path, "utf8")).toBe(text);
		const after = statSync(path);
		expect([after.mtimeMs, after.ctimeMs, after.mode, after.size]).toEqual([before.mtimeMs, before.ctimeMs, before.mode, before.size]);
		expect(readdirSync(directory)).toEqual(["auth.json"]);
	});

	it("does not create a missing credential file or its parent", () => {
		const { directory } = fixture();
		const parent = join(directory, "missing");
		expect(new FileCredentialStore(join(parent, "auth.json")).redactionValues()).toEqual([]);
		expect(existsSync(parent)).toBe(false);
	});

	it("redacts current local credentials and contains invalid-file errors in generic inspection failures", async () => {
		const { path, store } = fixture();
		const events: Event[] = [];
		const runner = await Runner.open({ storage: new MemoryStorage(), models: createModels(), emit: (event) => events.push(event), inspectionSecrets: () => store.redactionValues() });
		runners.push(runner);
		const harness = (runner as unknown as { harness: Harness }).harness;
		const ids = await harness.commit(async (tx) => {
			const conversation = await tx.createConversation({ ownership: { kind: "ownerless" } });
			(await tx.doc(RunsDoc)).runs.test = {
				conversationId: conversation.id, cwd: process.cwd(), models: { head: { provider: "unused", modelId: "unused" } },
				submissionId: null, status: "settled", aborted: false, questions: {}, settled: null, children: {},
			};
			const entry = await tx.appendEntry(conversation.id, { kind: "pi.user", model: [{ role: "user", content: "local-api-secret local-access-secret local-refresh-secret account-metadata", timestamp: 1 }] });
			return { conversation: conversation.id, entry: entry.id };
		}, ctx);
		const command = { type: "inspect_context", run_id: "test", ...ids };
		// Write after opening the runner to prove credentials are read at inspection time.
		writeFileSync(path, JSON.stringify({ api: { type: "api_key", key: "local-api-secret" }, oauth: { type: "oauth", access: "local-access-secret", refresh: "local-refresh-secret", expires: 0, accountId: "account-metadata" } }));
		const result = await runner.handle(command) as { text: string };
		for (const secret of ["local-api-secret", "local-access-secret", "local-refresh-secret"]) expect(result.text).not.toContain(secret);
		expect(result.text).toContain("account-metadata");
		expect(result.text).toContain("[REDACTED]");
		writeFileSync(path, "invalid-json-secret");
		expect(() => store.redactionValues()).toThrow();
		await runner.dispatch(command);
		expect(events.at(-1)).toEqual({ type: "reply", id: null, ok: false, error: "Unable to inspect context" });
		expect(readFileSync(path, "utf8")).toBe("invalid-json-secret");
	});
});
