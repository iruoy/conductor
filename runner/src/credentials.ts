// A CredentialStore over pi's ~/.pi/agent/auth.json. Writes take the same proper-lockfile lock as the pi CLI,
// so an OAuth refresh here and one in a concurrent `pi` never both rotate the refresh token.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import type { AuthOperationOptions, Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import lockfile from "proper-lockfile";

const STALE_MS = 30_000;

export function defaultAuthPath(): string {
	return process.env.PI_AUTH_PATH ?? join(homedir(), ".pi", "agent", "auth.json");
}

type AuthFile = Record<string, Credential>;

export class FileCredentialStore implements CredentialStore {
	readonly path: string;

	constructor(path: string = defaultAuthPath()) {
		this.path = path;
	}

	/** Read known secrets for inspection without locking, writing, or refreshing credentials. */
	redactionValues(): readonly string[] {
		const values: string[] = [];
		for (const credential of Object.values(this.load())) {
			if (credential.type === "api_key") {
				if (typeof credential.key === "string") values.push(credential.key);
			} else if (credential.type === "oauth") {
				if (typeof credential.access === "string") values.push(credential.access);
				if (typeof credential.refresh === "string") values.push(credential.refresh);
			}
		}
		return values;
	}

	async read(providerId: string, _options?: AuthOperationOptions): Promise<Credential | undefined> {
		return this.load()[providerId];
	}

	async list(_options?: AuthOperationOptions): Promise<readonly CredentialInfo[]> {
		return Object.entries(this.load()).map(([providerId, credential]) => ({ providerId, type: credential.type }));
	}

	async modify(
		providerId: string,
		fn: (current: Credential | undefined) => Promise<Credential | undefined>,
		options?: AuthOperationOptions,
	): Promise<Credential | undefined> {
		return this.withLock(async () => {
			const data = this.load();
			const next = await fn(data[providerId]);
			if (next === undefined) return data[providerId];
			this.save({ ...data, [providerId]: next });
			return next;
		}, options?.signal);
	}

	async delete(providerId: string, options?: AuthOperationOptions): Promise<void> {
		await this.withLock(async () => {
			const data = this.load();
			delete data[providerId];
			this.save(data);
		}, options?.signal);
	}

	private load(): AuthFile {
		if (!existsSync(this.path)) return {};
		const text = readFileSync(this.path, "utf8").replace(/^﻿/, "");
		return text.trim() === "" ? {} : (JSON.parse(text) as AuthFile);
	}

	private save(data: AuthFile): void {
		writeFileSync(this.path, JSON.stringify(data, null, 2), { encoding: "utf8", mode: 0o600 });
	}

	private async withLock<T>(fn: () => Promise<T>, signal?: AbortSignal): Promise<T> {
		mkdirSync(dirname(this.path), { recursive: true });
		if (!existsSync(this.path)) writeFileSync(this.path, "{}", { mode: 0o600 });
		const release = await this.acquire(signal);
		try {
			return await fn();
		} finally {
			await release().catch(() => {});
		}
	}

	private async acquire(signal?: AbortSignal): Promise<() => Promise<void>> {
		const deadline = Date.now() + STALE_MS;
		for (let retry = 0; ; retry++) {
			signal?.throwIfAborted();
			try {
				return await lockfile.lock(this.path, { realpath: false, retries: 0, stale: STALE_MS });
			} catch (error) {
				const code = (error as { code?: string }).code;
				if (code !== "ELOCKED" || Date.now() >= deadline) throw error;
				const base = Math.min(10 * 2 ** retry, 1_000);
				await sleep(Math.min(Math.round(base * (1 + Math.random())), deadline - Date.now()), undefined, { signal });
			}
		}
	}
}
