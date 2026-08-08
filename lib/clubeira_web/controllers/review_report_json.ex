defmodule ClubeiraWeb.ReviewReportJSON do
  @moduledoc false

  def create(%{report: report}), do: %{data: report}
end
