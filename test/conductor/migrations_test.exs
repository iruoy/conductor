defmodule Conductor.MigrationsTest do
  use ExUnit.Case, async: false
  alias Conductor.{MigrationRepo, Repo}

  @migration_path Path.expand("../../priv/repo/migrations", __DIR__)

  setup_all do
    # Load migration modules once, then pass them directly to the migrator.
    # This avoids recompiling the same modules for each isolated database.
    migrations =
      for {filename, module} <- [
            {"20261004212747_init.exs", Conductor.Repo.Migrations.Init},
            {"20261004224052_install_ash_extensions_1.exs",
             Conductor.Repo.Migrations.InstallAshExtensions1},
            {"20261005001913_reconcile_existing_schema.exs",
             Conductor.Repo.Migrations.ReconcileExistingSchema}
          ] do
        unless Code.ensure_loaded?(module) do
          Code.require_file(Path.join(@migration_path, filename))
        end

        {filename |> String.split("_") |> hd() |> String.to_integer(), module}
      end

    {:ok, migrations: migrations}
  end

  @initial_version 20_261_004_212_747

  setup do
    database = "conductor_migration_#{System.unique_integer([:positive])}"

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(~s(CREATE DATABASE "#{database}"))
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(~s|DROP DATABASE "#{database}" WITH (FORCE)|)
      end)
    end)

    config =
      Repo.config()
      |> Keyword.drop([:name])
      |> Keyword.merge(database: database, pool: DBConnection.ConnectionPool, pool_size: 2)

    start_supervised!({MigrationRepo, config})
    :ok
  end

  test "fresh databases migrate and enforce the run attempt identity", %{migrations: migrations} do
    Ecto.Migrator.run(MigrationRepo, migrations, :up, all: true, log: false)
    assert_tables()
    assert_run_identity()
  end

  test "upgrading the historical schema preserves data and supports rollback", %{
    migrations: migrations
  } do
    assert [@initial_version] =
             Ecto.Migrator.run(MigrationRepo, migrations, :up,
               to: @initial_version,
               log: false
             )

    %{rows: [[id]]} =
      MigrationRepo.query!("""
      INSERT INTO repos (name, clone_url, owner, slug, inserted_at, updated_at)
      VALUES ('existing', 'git@example.com:acme/existing.git', 'acme', 'existing', now(), now())
      RETURNING id
      """)

    seed_history(id)

    Ecto.Migrator.run(MigrationRepo, migrations, :up, all: true, log: false)
    assert_tables()
    assert_run_identity()
    assert_existing_repo(id)

    Ecto.Migrator.run(MigrationRepo, migrations, :down, step: 1, log: false)

    assert %{rows: [[nil]]} =
             MigrationRepo.query!("SELECT to_regclass('public.runs_issue_key_attempt_index')")

    assert_existing_repo(id)

    Ecto.Migrator.run(MigrationRepo, migrations, :up, all: true, log: false)
    assert_run_identity()
    assert_existing_repo(id)
  end

  defp assert_tables do
    for table <- ~w(repos projects settings runs run_events questions) do
      assert %{rows: [[^table]]} = MigrationRepo.query!("SELECT to_regclass($1)::text", [table])
    end
  end

  defp assert_run_identity do
    assert %{rows: [[true]]} =
             MigrationRepo.query!("""
             SELECT indisunique FROM pg_index
             WHERE indexrelid = 'runs_issue_key_attempt_index'::regclass
             """)
  end

  defp seed_history(repo_id) do
    %{rows: [[project_id]]} =
      MigrationRepo.query!(
        """
        INSERT INTO projects
          (repo_id, project_owner, project_number, runner_login, pickup_status,
           active_status, handoff_status, inserted_at, updated_at)
        VALUES ($1, 'acme', 1, 'bot', 'Ready', 'Active', 'Review', now(), now())
        RETURNING id
        """,
        [repo_id]
      )

    MigrationRepo.query!(
      """
      INSERT INTO runs (id, project_id, issue_key, attempt, status, summary, inserted_at, updated_at)
      VALUES ('existing-1', $1, 'existing', 1, 'completed', 'Historical summary', now(), now())
      """,
      [project_id]
    )

    MigrationRepo.query!("""
    INSERT INTO run_events (run_id, conversation, role, entry, kind, payload, inserted_at)
    VALUES ('existing-1', 0, 'head', 'entry-1', 'message', '{"text":"Historical event"}', now())
    """)

    MigrationRepo.query!("""
    INSERT INTO questions (run_id, qid, text, answer, inserted_at, updated_at)
    VALUES ('existing-1', 'question-1', 'Historical question', 'Historical answer', now(), now())
    """)

    MigrationRepo.query!("""
    INSERT INTO settings (models, max_concurrent, prune_days, inserted_at, updated_at)
    VALUES ('{"head":{"provider":"faux","modelId":"saved"}}', 2, 10, now(), now())
    """)
  end

  defp assert_existing_repo(id) do
    assert %{rows: [[^id, "existing", "acme"]]} =
             MigrationRepo.query!("SELECT id, name, owner FROM repos WHERE id = $1", [id])

    assert %{
             rows: [
               [
                 ^id,
                 "existing-1",
                 "completed",
                 "Historical summary",
                 %{"text" => "Historical event"},
                 "Historical answer",
                 %{"head" => %{"provider" => "faux", "modelId" => "saved"}},
                 2,
                 10
               ]
             ]
           } =
             MigrationRepo.query!("""
             SELECT p.repo_id, r.id, r.status, r.summary, e.payload, q.answer,
                    s.models, s.max_concurrent, s.prune_days
             FROM projects p
             JOIN runs r ON r.project_id = p.id
             JOIN run_events e ON e.run_id = r.id
             JOIN questions q ON q.run_id = r.id
             CROSS JOIN settings s
             """)
  end
end
