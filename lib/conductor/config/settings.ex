defmodule Conductor.Config.Settings do
  @moduledoc "The global settings: the role models, the concurrency limit and how long finished workspaces are kept."
  use Ash.Resource, domain: Conductor.Config, data_layer: AshPostgres.DataLayer

  postgres do
    table "settings"
    repo Conductor.Repo
  end

  actions do
    defaults [:read, create: :*, update: :*]
  end

  validations do
    validate numericality(:max_concurrent, greater_than_or_equal_to: 0, less_than_or_equal_to: 20)
    validate numericality(:prune_days, greater_than: 0)
  end

  attributes do
    integer_primary_key :id

    attribute :models, Conductor.Config.Models do
      public? true
      allow_nil? false
      default %{}
    end

    attribute :max_concurrent, :integer do
      public? true
      allow_nil? false
      default 3
    end

    attribute :prune_days, :integer do
      public? true
      allow_nil? false
      default 7
    end
  end

  def roles, do: ~w(head low medium high)
end
