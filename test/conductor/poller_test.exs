defmodule Conductor.PollerTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  alias Conductor.{Poller, Runs}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    project = project_fixture(%{repo: repo_fixture(%{clone_url: git_remote(dir)})})
    settings_fixture(%{max_concurrent: 0})
    start_workers(dir)
    %{project: project}
  end

  test "picks up matching issues once and records the poll", %{project: project} do
    stub_github(issues: [%{"number" => 1, "title" => "One"}, %{"number" => 2, "title" => "Two"}])
    assert %{last_poll: nil, interval: nil} = Poller.status()
    Poller.subscribe()

    assert :ok = Poller.poll()
    assert :ok = Poller.poll()

    assert ["#{project.repo.name}-1-1", "#{project.repo.name}-2-1"] ==
             Runs.list_by_status([:picked_up]) |> Enum.map(& &1.id) |> Enum.sort()

    assert_receive {:polled, %{ok?: true, reason: nil, at: %DateTime{}}}
    assert_receive {:polled, last_poll}
    assert %{last_poll: ^last_poll} = Poller.status()
  end

  test "records a failed poll with its reason" do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "Bad credentials"}]})
    end)

    Poller.subscribe()

    assert :ok = Poller.poll()
    assert_receive {:polled, %{ok?: false, reason: reason}}
    assert reason =~ "Bad credentials"
    assert %{last_poll: %{ok?: false, reason: ^reason}} = Poller.status()
  end

  test "prunes old workspaces of merged and failed runs, never those in review", %{
    project: project,
    tmp_dir: dir
  } do
    workspace = fn name ->
      path = Path.join(dir, name)
      File.mkdir_p!(path)
      path
    end

    merged = run_fixture(project, "shop-3", %{status: :merged, workspace_path: workspace.("m")})
    failed = run_fixture(project, "shop-4", %{status: :failed, workspace_path: workspace.("f")})

    review =
      run_fixture(project, "shop-5", %{status: :completed, workspace_path: workspace.("r")})

    recent = run_fixture(project, "shop-6", %{status: :failed, workspace_path: workspace.("n")})

    ids = [merged.id, failed.id, review.id]

    Repo.update_all(from(r in Conductor.Runs.Run, where: r.id in ^ids),
      set: [updated_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert :ok = Poller.prune()

    for run <- [merged, failed] do
      refute File.exists?(run.workspace_path)
      assert Runs.get_run!(run.id).workspace_path == nil
    end

    for run <- [review, recent] do
      assert File.dir?(run.workspace_path)
      assert Runs.get_run!(run.id).workspace_path == run.workspace_path
    end
  end
end
