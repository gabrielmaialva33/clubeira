defmodule ClubeiraWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias ClubeiraWeb.Backoffice.DashboardLive
  alias ClubeiraWeb.Telemetry

  test "exposes low-cardinality LiveView lifecycle metrics" do
    metrics = Map.new(Telemetry.metrics(), &{&1.name, &1})

    assert %{tags: [:view], unit: :millisecond} =
             metrics[[:phoenix, :live_view, :mount, :stop, :duration]]

    assert %{tags: [:view], unit: :millisecond} =
             metrics[[:phoenix, :live_view, :handle_params, :stop, :duration]]

    assert %{tags: [:view, :event], unit: :millisecond} =
             event_metric =
             metrics[[:phoenix, :live_view, :handle_event, :stop, :duration]]

    assert event_metric.tag_values.(%{
             socket: %{view: DashboardLive},
             event: "change_polo",
             params: %{"token" => "must-not-become-a-tag"}
           }) == %{view: DashboardLive, event: "change_polo"}
  end
end
