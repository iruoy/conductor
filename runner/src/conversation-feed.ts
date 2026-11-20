// What Phoenix gets of a conversation. Pi Durable publishes a conversation as state (`Conversation.watch()`), and so
// does this feed: a `snapshot` with the whole transcript and the live state on attach, then an `update` with the
// entries appended since and, when it changed, the whole live state. Phoenix stores entries and renders the live state
// as it is; nothing is derived from the difference between two states, so a missed update is repaired by the next.
//
// Pi throttles how often the in-flight answer and running tool output commit (`settings.progress`), so sending the
// live state whole costs little; Phoenix shows only the tail of tool output anyway.
import type { Context } from "@earendil-works/chord/context";
import type {
	CompactionFailure,
	Conversation,
	ConversationView,
	EntryId,
	EntryRecord,
	LiveState,
	NestedToolSlot,
	ToolSlot,
} from "@earendil-works/pi-durable";

/** What a conversation is doing right now. Everything in it goes away when the conversation is done with it. */
export type Live = {
	/** A run is under way: the conversation has input to answer. */
	busy: boolean;
	/** The answer being streamed, its text and thinking blocks each joined. */
	message: { text: string; thinking: string } | null;
	/** The answer failed and is retried at `at` (epoch ms). */
	retry: { attempt: number; at: number; error: string } | null;
	/** Running tool calls in call order, nested calls (`parentCallId`) after the model-issued ones. */
	tools: LiveTool[];
	/** Queued input the agent has not read yet. */
	inbox: { id: number; mode: string }[];
};

type LiveTool = { callId: string; name: string; args: unknown; output: string; parentCallId: string | null };

type FeedEvent =
	| { type: "snapshot"; entries: EntryRecord[]; live: Live; compactionFailure: CompactionFailure | null }
	/** `entries`, `live` and `compactionFailure` are each present only when there is something new. */
	| { type: "update"; entries?: EntryRecord[]; live?: Live; compactionFailure?: CompactionFailure | null };

export type ConversationFeed = {
	readonly snapshot: FeedEvent;
	/** Delivers updates in commit order until `stop`. */
	start(listener: (update: FeedEvent) => Promise<void>): void;
	stop(): Promise<unknown>;
};

const ENTRY_PAGE = 500;

export async function watchConversation(conversation: Conversation, context: Context): Promise<ConversationFeed> {
	const watch = await conversation.watch(context);
	// The view holds only the newest entries; Phoenix stores the snapshot's, so it carries the whole history.
	const history = await entriesAfter(conversation, 0, undefined, context);
	const known = history.at(-1)?.id ?? 0;
	const entries = [...history, ...watch.value.entries.filter((entry) => entry.id > known)];
	let newest = entries.at(-1)?.id ?? watch.value.before ?? 0;
	// A model-issued call's arguments are in the assistant entry that made it, not in its live slot.
	const args = new Map<string, unknown>();
	for (const entry of entries) rememberArguments(args, entry);

	let live = liveOf(watch.value, args);
	let liveJson = JSON.stringify(live);
	let failure = failureOf(watch.value);
	let failureJson = JSON.stringify(failure);

	return {
		snapshot: { type: "snapshot", entries, live, compactionFailure: failure },
		start: (listener) =>
			watch.start(async (call) => {
				if (call.kind !== "value") return;
				const view = call.value;
				// A window that does not continue from the newest entry sent (it slid past several at once) misses some.
				const missed =
					view.before !== undefined && view.before > newest ? await entriesAfter(conversation, newest, view.before, context) : [];
				const appended = [...missed, ...view.entries.filter((entry) => entry.id > newest)];
				for (const entry of appended) rememberArguments(args, entry);
				newest = appended.at(-1)?.id ?? newest;

				const update: FeedEvent & { type: "update" } = { type: "update" };
				if (appended.length > 0) update.entries = appended;
				live = liveOf(view, args);
				const nextLive = JSON.stringify(live);
				if (nextLive !== liveJson) {
					liveJson = nextLive;
					update.live = live;
				}
				failure = failureOf(view);
				const nextFailure = JSON.stringify(failure);
				if (nextFailure !== failureJson) {
					failureJson = nextFailure;
					update.compactionFailure = failure;
				}
				if (Object.keys(update).length > 1) await listener(update);
			}),
		stop: () => watch.stop(),
	};
}

function liveOf(view: ConversationView, args: ReadonlyMap<string, unknown>): Live {
	const state = (view.docs["pi.live"] ?? {}) as LiveState;
	const inbox = view.docs["pi.inbox"] as { items?: { id: number; mode: string }[] } | undefined;
	const generation = state.generation;
	return {
		busy: state.run !== undefined,
		message: messageOf(generation?.message),
		retry: generation?.retry === undefined ? null : { attempt: generation.attempt, ...generation.retry },
		tools: [...(state.tools ?? []), ...(state.nestedTools ?? [])]
			.filter((slot) => slot.status === "running")
			.map((slot) => toolOf(slot, args)),
		inbox: (inbox?.items ?? []).map((item) => ({ id: item.id, mode: item.mode })),
	};
}

function messageOf(partial: unknown): Live["message"] {
	const content = (partial as { content?: { type: string; text?: string; thinking?: string }[] } | undefined)?.content;
	if (content === undefined) return null;
	let text = "";
	let thinking = "";
	for (const block of content) {
		if (block.type === "text") text += block.text ?? "";
		else if (block.type === "thinking") thinking += block.thinking ?? "";
	}
	return text === "" && thinking === "" ? null : { text, thinking };
}

function toolOf(slot: ToolSlot | NestedToolSlot, args: ReadonlyMap<string, unknown>): LiveTool {
	const nested = "parentCallId" in slot;
	return {
		callId: slot.callId,
		name: slot.name,
		args: nested ? slot.arguments : (args.get(slot.callId) ?? {}),
		output: slot.output ?? "",
		parentCallId: nested ? slot.parentCallId : null,
	};
}

function failureOf(view: ConversationView): CompactionFailure | null {
	return ((view.docs["pi.live"] ?? {}) as LiveState).compactionFailure ?? null;
}

function rememberArguments(args: Map<string, unknown>, entry: EntryRecord): void {
	const message = (entry.model as { role?: string; content?: unknown }[] | undefined)?.[0];
	if (message?.role !== "assistant" || !Array.isArray(message.content)) return;
	for (const block of message.content as { type?: string; id?: string; arguments?: unknown }[]) {
		if (block.type === "toolCall" && typeof block.id === "string") args.set(block.id, block.arguments ?? {});
	}
}

/** Entries after `after`, up to and including `upTo`, oldest first. */
async function entriesAfter(
	conversation: Conversation,
	after: number,
	upTo: number | undefined,
	context: Context,
): Promise<EntryRecord[]> {
	const query = {
		order: "ascending" as const,
		...(after > 0 ? { minEntryId: (after + 1) as EntryId } : {}),
		...(upTo === undefined ? {} : { maxEntryId: upTo as EntryId }),
	};
	const result: EntryRecord[] = [];
	let cursor: Parameters<Conversation["entries"]>[2];
	do {
		const page = await conversation.entries(query, ENTRY_PAGE, cursor, context);
		result.push(...page.items);
		cursor = page.next;
	} while (cursor !== undefined);
	return result;
}
