defmodule ClubeiraWeb.Reviews.ReviewReportJSON do
  @moduledoc false

  def create(%{report: report}), do: %{data: report}
end
