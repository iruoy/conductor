defmodule Conductor.PollerTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  alias Conductor.{Poller, Runs}

  @moduletag :tmp_dir

  test "picks up matching issues once and prunes old workspaces", %{tmp_dir: dir} do
    remote = git_remote(dir)
    project = project_fixture(%{repo: repo_fixture(%{clone_url: remote})})
    settings_fixture(%{max_concurrent: 0})

    stub_github(issues: [%{"number" => 1, "title" => "One"}, %{"number" => 2, "title" => "Two"}])

    start_workers(dir)

    assert :ok = Poller.poll()
    assert :ok = Poller.poll()

    assert ["#{project.repo.name}-1-1", "#{project.repo.name}-2-1"] ==
             Runs.list_by_status(["picked_up"]) |> Enum.map(& &1.id) |> Enum.sort()

    old =
      run_fixture(project, "shop-3", %{status: "completed", workspace_path: Path.join(dir, "old")})

    File.mkdir_p!(old.workspace_path)

    Repo.update_all(from(r in Conductor.Runs.Run, where: r.id == ^old.id),
      set: [updated_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert :ok = Poller.prune()
    refute File.exists?(Path.join(dir, "old"))
    assert Runs.get_run!(old.id).workspace_path == nil
  end
end
