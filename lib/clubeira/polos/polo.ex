defmodule Clubeira.Polos.Polo do
  @moduledoc """
  A city, region, or franchise hub with its own commercial rules.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.City

  schema "polos" do
    belongs_to :city, City

    field :name, :string
    field :timezone, :string
    field :status, :string

    timestamps()
  end
end
