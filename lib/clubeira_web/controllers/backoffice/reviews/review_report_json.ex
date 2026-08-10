defmodule ClubeiraWeb.Backoffice.ReviewReportJSON do
  @moduledoc false

  def index(%{reports: reports, page: page}) do
    %{data: Enum.map(reports, &report_data/1), page: page}
  end

  def create_action(%{result: result}), do: %{data: result}

  defp report_data(report) do
    report
    |> Map.update!(:reported_at, &DateTime.to_iso8601/1)
    |> Map.update!(:resolution, &resolution_data/1)
  end

  defp resolution_data(nil), do: nil

  defp resolution_data(resolution) do
    Map.update!(resolution, :resolved_at, &DateTime.to_iso8601/1)
  end
end
