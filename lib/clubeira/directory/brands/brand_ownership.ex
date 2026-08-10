defmodule Clubeira.Directory.BrandOwnership do
  @moduledoc """
  Records an organization's ownership of a brand over time.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.Organization
  alias Clubeira.Types.TstzRange

  schema "brand_ownerships" do
    belongs_to :brand, Brand
    belongs_to :organization, Organization

    field :valid_during, TstzRange
    field :inserted_at, :utc_datetime_usec
  end
end
