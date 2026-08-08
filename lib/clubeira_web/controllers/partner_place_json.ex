defmodule ClubeiraWeb.PartnerPlaceJSON do
  @moduledoc false

  alias ClubeiraWeb.BackofficePlaceJSON

  def index(assigns), do: BackofficePlaceJSON.index(assigns)
end
