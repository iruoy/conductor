# Runner feed: how a conversation reaches Phoenix

## Shape

The runner (`runner/src/conversation-feed.ts`) watches each conversation of a run with Pi Durable's
`Conversation.watch()` and writes what it sees to stdout as `agent_event` lines (JSONL). Pi publishes a conversation
as state, not as events, and so does the feed:

- `snapshot`, once per attach: every entry of the conversation (the watch itself holds only the newest 50–100, so the
  runner pages through the rest), the live state, and the compaction failure.
- `update`, after each commit that changes something Phoenix shows: the entries appended since the last line, the
  whole live state when it changed, and the compaction failure when it changed. Each of the three keys is present
  only when there is something new.

The live state is Conductor's projection of Pi's `pi.live` and `pi.inbox` documents:

| field | what it is |
|---|---|
| `busy` | a run is under way (`pi.live.run` exists) |
| `message` | the answer being streamed: its text and thinking blocks each joined, or `null` |
| `retry` | the failed attempt that is retried at `at`, or `null` |
| `tools` | running tool calls, model-issued ones first, then nested (codemode) calls with `parentCallId`; with their arguments and retained output |
| `inbox` | queued input the agent has not read yet |

## Why state and not events

Phoenix stores entries and renders the live state as it is. Nothing is derived from the difference between two
states, on either side, so an update that is lost or arrives at a page that opened late is repaired by the next one,
and a page can show a conversation's live state as soon as it switches to it (`RunLive` keeps the newest one per
conversation).

Sending the live state whole is cheap because Pi throttles how often it commits the in-flight answer and running
tool output (`settings.progress`, 100 ms by default) and bounds the output it retains. LiveView sends a changed string
to the browser whole anyway, so deltas between runner and Phoenix would not make the browser's share smaller.

## What Phoenix does with it

- `Conductor.Runs.ingest/1` upserts every entry (except `pi.system`) and the compaction failure, keyed by
  `(run_id, conversation, entry)`, and broadcasts the line on `run:<id>`. The live state is not persisted.
- `ConductorWeb.RunLive` appends message entries to the transcript as they come (other entries show once the
  transcript is read again), then shows the live state: the streamed answer, the output of running tools, the inbox
  and whether the conversation is at work.
- `ConductorWeb.DashboardLive` logs answers and the tool calls they make from the entries, and a retry once per
  retry.

## Tool output

Pi Durable's sanitizer (`sanitizeOutput` in `@earendil-works/chord`) removes terminal escape sequences and C0
controls from tool output before it is stored or published, so tool output is shown as plain text. Commands run
without a TTY, so most of them print no colours in the first place, and the model gets no escape codes in its tool
results.
