# Ash signals and run coordination

Conductor keeps `Conductor.Runs.Notifier` for run and question broadcasts. Ash 3.36 signals are useful for
transactional reactions between resources, but do not improve the current PubSub delivery or replace the
Coordinator's external work.

## Transaction boundaries

Run and question changes must reach subscribers only after their database transaction commits. The notifier
loads the run's project and broadcasts the existing `{:run_updated, run}` and `{:question, question}` messages.
`test/conductor/runs_notifier_test.exs` verifies direct resource writes, nested transactions, commit delivery,
and suppression on rollback.

Default signal listeners run inline as nested actions, generally inside the emitter's transaction. A failing
listener rolls back the emitting action. An `:after_transaction` signal is not an equivalent after-commit
mechanism: when the action runs inside an outer transaction, its listener still runs before that outer
transaction commits. Moving PubSub broadcasts to either kind would let subscribers observe rolled-back state.

## Coordinator operations

Provisioning workspaces, starting the runner, and handing work to GitHub remain in the supervised Coordinator.
Signals provide no durable external-job queue by default. Moving those operations into inline listeners would
hold database transactions across filesystem, subprocess, and network work. Retain the existing reconciliation
on process restart, idempotent runner commands, and persisted run state.

Likewise, answering a question requires the runner to accept the answer before the run resumes. A fire-and-forget
signal is unsuitable for replacing that ordered, acknowledged interaction.

## When to introduce signals

Use signals when a new resource needs to react transactionally to a domain event without the emitting resource
knowing its consumers. For example, a future database-backed usage ledger could record a settled run in the same
transaction. Define a typed signal contract, emit it from the resource action, and have the ledger's create action
listen to it. A listener failure should then deliberately prevent settlement.

At that point add `:ash_signals` to the Mix and development reloadable compilers, disable consolidation in tests,
and cover emissions, listener failure rollback, and listener behavior through `Ash.Signals.Test`. A reaction that
calls an external service needs a durable job delivery implementation and an idempotency key, rather than an
inline listener. No unused compiler or signal contracts are introduced before such a consumer exists.

References: [Ash signals](https://hexdocs.pm/ash/signals.html),
[notifiers](https://hexdocs.pm/ash/notifiers.html), and the installed Ash 3.36.1
`documentation/topics/resources/signals.md`, especially Signals vs. notifiers and Delivery.
