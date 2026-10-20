import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { createCodemodeExtension } from "@earendil-works/pi-durable/codemode";
import { createToolSearchExtension } from "@earendil-works/pi-durable/tool-search";

/** One worker budget shared by the head and all subagents of this runner. */
export function createExecutionTools() {
	let workers = 0;
	const sandbox = new CodemodeSandbox({
		memoryLimitBytes: 256 * 1024 * 1024,
		acquireWorker: () => {
			if (workers >= 2) throw new Error("Codemode worker capacity reached; retry after another script finishes.");
			workers++;
			// Pi calls this only on constructor failure or actual exit, even if cancellation settled earlier.
			return () => { workers--; };
		},
	});
	return {
		sandbox,
		extensions: [createCodemodeExtension({ sandbox, models: false }), createToolSearchExtension()],
	};
}
