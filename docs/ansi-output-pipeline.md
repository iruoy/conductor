# ANSI in tool output: pipeline and compatibility

## Output path

1. `runner/src/runner.ts` installs Pi Durable's `CodingTools` and watches conversation events. `runner/src/main.ts` writes each runner event as `JSON.stringify(value) + "\n"` to stdout. JSON escapes embedded control bytes and decoding restores them.
2. The pinned `@earendil-works/pi-durable@1.1.0` bash tool sends `NodeExecutionEnv.exec` output to `api.output`. The harness sanitizes and bounds output for both streaming `tool_execution_update` events and durable tool-result entries.
3. Runner forwards snapshots and live events as JSONL. Phoenix decodes them in the runner port and `Conductor.Runs.ingest/1` persists `message_end` payloads and broadcasts events. These boundaries preserve ESC and BEL once Pi Durable's sanitizer allows them through.
4. The host renders tool output through `ConductorWeb.AnsiOutput`: it interprets supported SGR formatting and strips remaining terminal control sequences before output is rendered. Raw terminal controls are never passed through as active browser markup.

## Rendering choice

`ansi_to_html` 0.6.0 was evaluated through source review and runtime probes. It was not added: combined SGR/selective-reset behavior was unsuitable, malformed extended colors could crash conversion, and unsupported codes could create unbounded atoms. Client-side converters would also leave escaping and streamed DOM ownership split between the server and browser.

`ConductorWeb.AnsiOutput.render/1` instead returns escaped text and generated inline spans. Only fixed formatting declarations and validated numeric colors become CSS; input never becomes a tag, attribute, URL, or atom. The stateless parser handles basic/bright, 256-color and RGB SGR, emphasis and resets, and safely withholds incomplete trailing escapes. Only tool-output panels use it; commands, file contents and diffs retain their existing text rendering and the output scroller remains attached to the server-updated `pre`.

## Reproducible sanitizer patch

Pi Durable 1.1.0's `dist/harness/output.js` originally removed ESC (`0x1b`) and BEL (`0x07`) using `INVALID_OUTPUT`. ESC removal destroyed ANSI SGR and OSC sequences before either a live update or final durable result reached Conductor. BEL removal also truncated OSC sequences that use BEL as their terminator.

`runner/patches/@earendil-works__pi-durable@1.1.0.patch` is maintained via pnpm's patch workflow and registered in `runner/pnpm-workspace.yaml`, with the patch hash recorded in `runner/pnpm-lock.yaml`. It only changes the sanitizer's invalid C0 ranges to preserve ESC and BEL. NUL and the other harmful C0 controls remain removed. This does not change execution output, command behavior, storage semantics, or historical entries.

`runner/test/protocol.test.ts` runs the installed bash tool with real `printf` output and verifies original SGR ESC sequences and a BEL-terminated OSC survive both live updates and the durable tool result; it also verifies NUL is still removed. JSONL framing does not strip those retained bytes.

## Legacy data limitation

Output already sanitized by an earlier Pi Durable version has irretrievably lost its ESC and BEL bytes. The plain text fragments left behind cannot reliably distinguish stripped terminal formatting from literal user output. Conductor does not infer missing ESC bytes, perform ESC-less bracket repair, or mutate historical transcript entries. The patch fixes output captured after installing the patched dependency; it cannot reconstruct older persisted output.

The renderer is a separate security boundary: it recognizes only supported SGR sequences and strips other terminal controls, including OSC, rather than forwarding terminal instructions to the browser. Retaining controls in the durable transcript makes safe host-side interpretation possible without treating arbitrary terminal sequences as trusted presentation instructions.
