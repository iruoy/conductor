// Entry point: JSON lines on stdin are commands, JSON lines on stdout are replies and events. stdout is reserved for
// the protocol, so console and stderr output go out as log messages. The process exits when stdin closes (Phoenix
// went away).
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { format } from "node:util";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import lockfile from "proper-lockfile";
import { FileCredentialStore } from "./credentials.ts";
import { type Command, Runner } from "./runner.ts";

const CLOSE_TIMEOUT_MS = 5_000;

const write = (value: unknown): void => void process.stdout.write(`${JSON.stringify(value)}\n`);

// Phoenix reads stderr from the same pipe as stdout. Two streams writing one pipe can split a long protocol line, so
// everything is written through stdout as log messages. Only Node's own output when it dies still reaches stderr.
const log =
	(level: "info" | "warning" | "error") =>
	(...args: unknown[]): void =>
		write({ type: "log", level, message: format(...args) });
console.log = console.info = console.debug = log("info");
console.warn = log("warning");
console.error = log("error");
process.stderr.write = ((chunk: string | Uint8Array, ...rest: unknown[]): boolean => {
	const text = typeof chunk === "string" ? chunk : Buffer.from(chunk).toString();
	write({ type: "log", level: "error", message: text.replace(/\n$/, "") });
	const callback = rest.find((arg) => typeof arg === "function") as (() => void) | undefined;
	if (callback) queueMicrotask(callback);
	return true;
}) as typeof process.stderr.write;

const dataDir = process.env.CONDUCTOR_RUNNER_DATA ?? join(process.cwd(), "data");
mkdirSync(dataDir, { recursive: true });
// Two runners writing one store corrupt it, so this one waits until the previous one is gone.
await lockfile.lock(dataDir, { retries: { retries: 40, minTimeout: 500, maxTimeout: 500 } });

const credentials = new FileCredentialStore();
const runner = await Runner.open({
	storage: await openNodeSqliteStorage(join(dataDir, "durable.sqlite")),
	models: builtinModels({ credentials }),
	emit: write,
});

// A failed Pi Session has already closed its storage. Exit nonzero so Phoenix restarts and reconciles it;
// normal stdin shutdown still closes cleanly below. Never attempt writes to the failed Session.
void runner.sessionEnd.then((end) => {
	if (end.kind === "failed") process.exit(1);
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
	// Closing waits for running tools, which may never finish; Phoenix is gone either way.
	setTimeout(() => process.exit(0), CLOSE_TIMEOUT_MS).unref();
	void runner.close().finally(() => process.exit(0));
});
