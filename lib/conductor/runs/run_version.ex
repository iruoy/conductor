defmodule Conductor.Runs.RunVersion do
  @moduledoc """
  What `Conductor.Runs.Run.Version`, the resource `AshPaperTrail` generates for the status history of a run, gets
  on top of what the extension gives it: the history is read per run, so the reference to the run is indexed.
  """

  defmacro __using__(_opts) do
    quote do
      postgres do
        references do
          reference :version_source, index?: true
        end
      end
    end
  end
end
