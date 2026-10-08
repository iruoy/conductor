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
      run_fixture(project, "shop-3", %{status: :completed, workspace_path: Path.join(dir, "old")})

    File.mkdir_p!(old.workspace_path)

    Repo.update_all(from(r in Conductor.Runs.Run, where: r.id == ^old.id),
      set: [updated_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert :ok = Poller.prune()
    refute File.exists?(Path.join(dir, "old"))
    assert Runs.get_run!(old.id).workspace_path == nil
  end

  describe "last poll" do
    setup %{tmp_dir: dir} do
      project_fixture(%{repo: repo_fixture(%{clone_url: git_remote(dir)})})
      settings_fixture(%{max_concurrent: 0})
      start_workers(dir)
      :ok
    end

    test "is empty before the first poll and the timers are off in tests" do
      assert %{last_poll: nil, interval: nil} = Poller.status()
    end

    test "records a good poll and broadcasts it" do
      stub_github(issues: [])
      Poller.subscribe()

      assert :ok = Poller.poll()
      assert_receive {:polled, %{ok?: true, reason: nil, at: %DateTime{}} = last_poll}
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
  end
end
