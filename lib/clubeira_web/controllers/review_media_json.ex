defmodule ClubeiraWeb.ReviewMediaJSON do
  @moduledoc false

  def show(%{media: media}) do
    %{data: Map.update!(media, :inserted_at, &DateTime.to_iso8601/1)}
  end
end
