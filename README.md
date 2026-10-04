# Conductor

Picks GitHub issues assigned to a runner account, works them with a durable coding agent in a git working tree, and
opens a pull request when the agent is done. Phoenix LiveView for the UI, a Node
[pi-durable](https://www.npmjs.com/package/@earendil-works/pi-durable) runner for the agent, and PostgreSQL for Conductor's application data.

```
Poller ─search─▶ Coordinator ──provision──▶ Workspace (mirror → clone → issue branch)
                    │  start_run / answer / abort / sync      ▲
                    ▼                                          │ git push (agent)
              Runner (Port) ◀──JSON lines──▶ runner/dist/main.js (pi-durable, durable.sqlite)
                    │ events
                    ▼
               Runs (Postgres, PubSub) ──▶ LiveViews: / (runs), /runs/:id (transcript, questions), /config
```

## Setup

Start PostgreSQL before setup. By default, Conductor connects as `postgres` with password `postgres` on
`localhost` (override with `PGUSER`, `PGPASSWORD`, and `PGHOST`). For example, to use a local PostgreSQL Unix
socket, set `PGHOST=/run/postgresql`.

```sh
cd runner && pnpm install && pnpm build && cd ..
mix setup
mix phx.server   # http://localhost:4000
```

Models come from pi-ai: the OpenAI subscription login in `~/.pi/agent/auth.json` (log in with `pi`; refreshes are
shared with it through the same file lock), plus any provider whose API key is in the environment
(`ANTHROPIC_API_KEY`, ...). Pick the head and per-complexity models on `/config`.

Environment:

| Variable | Used for |
|---|---|
| `GITHUB_TOKEN` | Polling, issue snapshots, status labels, checking the pushed branch and opening the PR (Phoenix), and the agent's `close_issue` tool. Needs read/write on issues and pull requests |
| `DATABASE_URL` | PostgreSQL connection URL in production |
| `CONDUCTOR_WORKSPACES` | Workspace root, default `~/conductor-workspaces` |
| `CONDUCTOR_RUNNER_DATA` | Runner state directory, default `runner/data` |
| `PI_AUTH_PATH` | pi credentials file, default `~/.pi/agent/auth.json` |

Git pushes use the machine's own git credentials (SSH agent or credential helper) for the repositories' clone URLs.

## How a run goes

1. The Poller searches `repo:<owner>/<name> is:issue is:open assignee:<runner> label:"<pickup>"` every minute and
   queues issue `#12` of project `KEY` as run `KEY-12-1` (`picked_up`). GitHub has no workflow statuses, so a
   project's statuses are labels: an issue carries the pickup, the active or the hand-off label.
2. When a slot is free (`max_concurrent`; runs waiting for a human do not count), the Coordinator swaps the pickup
   label for the active one, provisions `<root>/<repo>-issues/<KEY>` on `feature/KEY` or `bugfix/KEY` from staging (else
   main), runs the setup script once, and sends `start_run` with the rendered prompt.
3. The head agent implements the subtasks through `run_subagents` (one child conversation per sub-issue, model by
   complexity label, "blocked by" dependency waves), closes finished sub-issues, tests, commits, pushes, and ends with `DONE` or
   `FAILED: reason`. `ask_human` questions, and a final message without a verdict, appear on the run page to answer.
4. On `DONE` the Coordinator checks the branch was pushed, opens (or finds) the PR (`Closes #12`), and gives the issue
   the hand-off label. Retry starts `KEY-(attempt+1)`; finished workspaces are pruned after `prune_days`.

Crashes: the runner keeps every conversation, tool call and run in `durable.sqlite` and resumes them on start. If it
dies, the Runner process restarts it and the Coordinator reconciles: runs the runner does not know are sent again
(`start_run` is idempotent), settled ones are handed off, open questions are kept.

## Tests

```sh
mix test                      # ExUnit, with test/support/fake_runner.exs standing in for the runner
cd runner && pnpm test        # vitest, with pi-ai's faux model
```

The runner protocol (JSON lines; commands carry `id`, replies `{"type":"reply","id","ok","result"|"error"}`, events
carry `seq`) is documented in `runner/src/runner.ts`.
