defmodule ConductorWeb.RunComponentsTest do
  use ExUnit.Case, async: true
  import ConductorWeb.RunComponents

  describe "run_duration/2" do
    @start ~U[2026-10-08 12:00:00Z]

    defp run(status, updated_at),
      do: %{status: status, inserted_at: @start, updated_at: updated_at}

    test "a run that has not started has none" do
      assert run_duration(run(:picked_up, @start), ~U[2026-10-08 13:00:00Z]) == "—"
    end

    test "a finished run took until its last update" do
      assert run_duration(run(:completed, ~U[2026-10-08 12:26:59Z]), ~U[2026-10-09 12:00:00Z]) ==
               "26m"

      assert run_duration(run(:failed, ~U[2026-10-08 13:05:00Z]), ~U[2026-10-09 12:00:00Z]) ==
               "1h 5m"
    end

    test "a run under way counts up to now, to the minute" do
      for status <- ~w(provisioning running waiting_for_input handing_off)a do
        run = run(status, ~U[2026-10-08 12:01:00Z])
        assert run_duration(run, ~U[2026-10-08 12:00:59Z]) == "<1m"
        assert run_duration(run, ~U[2026-10-08 12:21:30Z]) == "21m"
        assert run_duration(run, ~U[2026-10-08 14:02:00Z]) == "2h 2m"
      end
    end
  end

  describe "local_time/1" do
    test "shows the time for today and the date too for another day" do
      assert local_time(DateTime.utc_now()) =~ ~r/^\d\d:\d\d$/
      assert local_time(~U[2020-03-07 12:00:00Z]) =~ ~r/^\d{1,2} Mar \d\d:\d\d$/
      assert local_time(nil) == ""
    end
  end

  test "status_label/1 puts a status in words" do
    assert status_label(:waiting_for_input) == "waiting for input"
  end
end
