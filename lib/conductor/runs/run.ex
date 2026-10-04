defmodule Conductor.Runs.Run do
  @moduledoc """
  One attempt at one issue, with id `KEY-attempt`.

  Status: `picked_up → provisioning → running ⇄ waiting_for_input → handing_off → completed | failed`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(picked_up provisioning running waiting_for_input handing_off completed failed)
  @terminal ~w(completed failed)

  @primary_key {:id, :string, autogenerate: false}
  schema "runs" do
    field :issue_key, :string
    field :attempt, :integer
    field :status, :string, default: "picked_up"
    field :workspace_path, :string
    field :branch, :string
    field :issue_snapshot, :map
    field :outcome, :string
    field :summary, :string
    field :error, :string
    field :pr_url, :string
    belongs_to :project, Conductor.Config.Project
    has_many :questions, Conductor.Runs.Question
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :workspace_path,
      :branch,
      :issue_snapshot,
      :outcome,
      :summary,
      :error,
      :pr_url
    ])
    |> validate_inclusion(:status, @statuses)
  end

  def id_for(issue_key, attempt), do: "#{issue_key}-#{attempt}"
end
