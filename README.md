# Conductor

Picks GitHub issues assigned to a runner account, works them with a durable coding agent in a git working tree, and
opens a pull request when the agent is done. Ash resources and domains for application data and the run status state machine (`Conductor.Runs.Run`), Phoenix LiveView for the UI, a Node
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
`localhost:5432` (override with `PGUSER`, `PGPASSWORD`, `PGHOST`, and `PGPORT`). For example, to use a local PostgreSQL Unix
socket, set `PGHOST=/run/postgresql`.

```sh
cd runner && pnpm install && pnpm build && cd ..
mix setup
mix phx.server   # http://localhost:4000
```

### Upgrading an existing database

Run `mix ecto.migrate` (or the release's migration command) before starting the upgraded app.
The original `20261004212747_init` migration is retained unchanged: the Ash migration
only adds the unique run identity on `(issue_key, attempt)`, preserving existing tables and data.
Existing duplicate run attempts must be reconciled before applying that unique index;
the migration fails rather than deleting or rewriting historical runs.

Models come from pi-ai: the OpenAI subscription login in `~/.pi/agent/auth.json` (log in with `pi`; refreshes are
shared with it through the same file lock), plus any provider whose API key is in the environment
(`ANTHROPIC_API_KEY`, ...). Pick the head and per-complexity models on `/config`.
Optional [missing-Size classifier suggestions](docs/complexity-classifier.md) are shadow-only and disabled by default.

### Local environment variables

In development, Dotenvy automatically loads `.env` from the project root when Conductor starts.
Copy the example and add your token:

```sh
cp .env.example .env
# Edit .env, then start normally:
mix phx.server
```

`.env` is ignored by Git. Existing shell environment variables take precedence over `.env` values,
and the Node runner inherits the loaded variables. Restart Conductor after changing `.env`.
The file is optional and is not loaded in tests or production; use environment variables there.

Environment:

| Variable | Used for |
|---|---|
| `GITHUB_TOKEN` | Reading the project and its issues, moving issues between statuses, checking the pushed branch and opening the PR (Phoenix), and the agent's `set_issue_status` tool. Needs read/write on projects, issues and pull requests (a classic token: `repo` and `project`) |
| `DATABASE_URL` | PostgreSQL connection URL in production |
| `CONDUCTOR_WORKSPACES` | Workspace root, default `~/conductor-workspaces` |
| `CONDUCTOR_RUNNER_DATA` | Runner state directory, default `runner/data` |
| `PI_AUTH_PATH` | pi credentials file, default `~/.pi/agent/auth.json` |

Git pushes use the machine's own git credentials (SSH agent or credential helper) for the repositories' clone URLs.

## How a run goes

1. Every minute the Poller reads the GitHub Project of each Conductor project and picks up the open issues of its
   repository that are assigned to the runner and in the pickup status. Issue `#12` of repository `shop` becomes run
   `shop-12-1` (`picked_up`). Relationships come first: an issue that is blocked by an open issue waits for it, and
   a sub-issue whose open parent is assigned to the runner is left to the parent's run.
2. Queued runs start by the issue's Priority in the project (the order of the field's options, issues without one
   last), the oldest first among equals. When a slot is free (`max_concurrent`; runs waiting for a human do not
   count), the Coordinator moves the issue to the active status, provisions `<root>/<repo>-issues/<number>` on
   `feature/<number>` or `bugfix/<number>` (issue type or label "bug") from staging (else main), runs the setup
   script once, and sends `start_run` with the rendered prompt.
3. The head agent implements the sub-issues through `run_subagents` (one child conversation per sub-issue, model by
   the sub-issue's Size in the project: XS and S low, M medium, the rest high; "blocked by" dependency waves), moves
   them to the active and the done status with `set_issue_status` (done also closes the sub-issue), tests, commits,
   pushes, and ends with `DONE` or `FAILED: reason`. `ask_human` questions, and a final message without a verdict,
   appear on the run page to answer.
4. On `DONE` the Coordinator checks the branch was pushed, opens (or finds) the PR (`Closes #12`), and moves the
   issue to the hand-off status. The run displays **In review** (`completed` internally), with its prompt still available.
5. Review feedback resumes the same run, conversation, workspace, branch and PR, displaying **In progress**.
   It needs a free concurrency slot and the original workspace. Closed or merged PRs cannot be resumed.
6. Each poll checks review PRs; a confirmed merge marks the run **Done** (`merged`) and removes the prompt.
   GitHub board statuses alone never prove a merge. Failed runs can be retried as `shop-12-2`;
   only failed or merged workspaces are pruned after `prune_days`, so review workspaces remain available.

The project's fields must be single-select fields named `Status`, `Size` and `Priority`, as in GitHub's templates.

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
