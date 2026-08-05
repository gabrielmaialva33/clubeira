defmodule ClubeiraWeb.LegalJSON do
  @moduledoc false

  def registration(%{documents: documents}) do
    %{data: Enum.map(documents, &Map.put(&1, :required, true))}
  end
end
