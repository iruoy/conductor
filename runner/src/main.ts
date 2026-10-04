// Entry point: JSON lines on stdin are commands, JSON lines on stdout are replies and events. stdout is reserved for
// the protocol, so console output goes to stderr. The process exits when stdin closes (Phoenix went away).
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { FileCredentialStore } from "./credentials.ts";
import { type Command, Runner } from "./runner.ts";

for (const level of ["log", "info", "debug", "warn"] as const) console[level] = console.error;

const write = (value: unknown): void => void process.stdout.write(`${JSON.stringify(value)}\n`);

const dataDir = process.env.CONDUCTOR_RUNNER_DATA ?? join(process.cwd(), "data");
mkdirSync(dataDir, { recursive: true });

const runner = await Runner.open({
	storage: await openNodeSqliteStorage(join(dataDir, "durable.sqlite")),
	models: builtinModels({ credentials: new FileCredentialStore() }),
	emit: write,
});

const input = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY });
input.on("line", (line) => {
	if (line.trim() === "") return;
	let command: Command;
	try {
		command = JSON.parse(line) as Command;
	} catch {
		write({ type: "log", level: "error", message: `unparseable command: ${line.slice(0, 200)}` });
		return;
	}
	void runner.dispatch(command);
});
input.on("close", () => {
	void runner.close().finally(() => process.exit(0));
});
