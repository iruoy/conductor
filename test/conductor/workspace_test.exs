defmodule Conductor.WorkspaceTest do
  use ExUnit.Case, async: false
  import Conductor.Fixtures, only: [git_remote: 1, git_remote: 2, git!: 2]
  alias Conductor.Config.Repository
  alias Conductor.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:conductor, :workspace_root, Path.join(dir, "ws"))
    on_exit(fn -> Application.delete_env(:conductor, :workspace_root) end)
    :ok
  end

  defp repo(remote, attrs \\ %{}) do
    struct!(
      %Repository{name: "shop", clone_url: remote, owner: "acme", slug: "shop"},
      attrs
    )
  end

  test "clones from a mirror onto a feature branch from staging", %{tmp_dir: dir} do
    remote = git_remote(dir)

    assert {:ok, %{path: path, branch: "feature/SHOP-1", base: "staging", setup_output: nil}} =
             Workspace.provision(repo(remote), "SHOP-1", %{"type" => "Story"})

    assert path == Path.join([dir, "ws", "shop-issues", "SHOP-1"])
    assert File.dir?(Path.join([dir, "ws", "mirrors", "shop.git"]))
    assert File.exists?(Path.join(path, "STAGING.md"))
    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature/SHOP-1"
    assert git!(path, ["remote", "get-url", "origin"]) == remote
  end

  test "is idempotent and keeps work in progress", %{tmp_dir: dir} do
    remote = git_remote(dir)
    {:ok, %{path: path}} = Workspace.provision(repo(remote), "SHOP-2", %{})
    File.write!(Path.join(path, "wip.txt"), "unsaved")

    assert {:ok, %{path: ^path}} = Workspace.provision(repo(remote), "SHOP-2", %{})
    assert File.read!(Path.join(path, "wip.txt")) == "unsaved"
  end

  test "uses bugfix branches for bugs and main without staging", %{tmp_dir: dir} do
    remote = git_remote(dir, staging: false)

    assert {:ok, %{branch: "bugfix/SHOP-3", base: "main", path: path}} =
             Workspace.provision(repo(remote), "SHOP-3", %{"type" => "Bug"})

    refute File.exists?(Path.join(path, "STAGING.md"))
  end

  test "continues a pushed branch of an earlier attempt", %{tmp_dir: dir} do
    remote = git_remote(dir)
    seed = Path.join(dir, "seed")
    git!(seed, ["switch", "-c", "feature/SHOP-4"])
    File.write!(Path.join(seed, "earlier.txt"), "x")
    git!(seed, ["add", "."])
    git!(seed, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "earlier"])
    git!(seed, ["push", remote, "feature/SHOP-4"])

    assert {:ok, %{path: path}} = Workspace.provision(repo(remote), "SHOP-4", %{})
    assert File.exists?(Path.join(path, "earlier.txt"))
  end

  test "runs setup with only Bash and Git on PATH", %{tmp_dir: dir} do
    remote = git_remote(dir)
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.ln_s!(System.find_executable("git"), Path.join(bin, "git"))
    File.ln_s!(System.find_executable("bash"), Path.join(bin, "bash"))

    with_path(bin, fn ->
      assert {:ok, %{setup_output: "installed\n"}} =
               Workspace.provision(repo(remote, %{setup_script: "echo installed"}), "SHOP-7", %{})
    end)
  end

  test "reports a timed out setup without marking it complete", %{tmp_dir: dir} do
    previous = Application.get_env(:conductor, :setup_timeout_seconds)
    Application.put_env(:conductor, :setup_timeout_seconds, 0.1)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:conductor, :setup_timeout_seconds)
      else
        Application.put_env(:conductor, :setup_timeout_seconds, previous)
      end
    end)

    remote = git_remote(dir)

    repository =
      repo(remote, %{
        setup_script: """
        trap 'wait; exit 0' TERM
        echo starting
        echo warning >&2
        sleep 30 &
        echo $! > .setup-child
        wait
        """
      })

    assert {:error, "setup script timed out after 0.1s:\nstarting\nwarning\n"} =
             Workspace.provision(repository, "SHOP-9", %{})

    path = Workspace.path(repository, "SHOP-9")
    refute File.exists?(Path.join([path, ".git", "conductor-setup-done"]))

    child_pid = path |> Path.join(".setup-child") |> File.read!() |> String.trim()
    {_, status} = System.cmd("kill", ["-0", child_pid], stderr_to_stdout: true)
    assert status != 0
  end

  defp with_path(path, fun) do
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", path)

    try do
      fun.()
    after
      System.put_env("PATH", previous)
    end
  end

  test "runs the setup script once and reports failures", %{tmp_dir: dir} do
    remote = git_remote(dir)
    ok = repo(remote, %{setup_script: "echo installing; touch .installed"})

    assert {:ok, %{setup_output: "installing\n", path: path}} =
             Workspace.provision(ok, "SHOP-5", %{})

    assert File.exists?(Path.join(path, ".installed"))
    assert {:ok, %{setup_output: nil}} = Workspace.provision(ok, "SHOP-5", %{})

    failing = repo(remote, %{setup_script: "echo broken; exit 3"})

    assert {:error, "setup script exited with 3:\nbroken\n"} =
             Workspace.provision(failing, "SHOP-6", %{})
  end
end
