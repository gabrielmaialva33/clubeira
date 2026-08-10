defmodule Clubeira.Directory.City do
  @moduledoc """
  A city in the geographic directory.
  """

  use Clubeira.Schema

  schema "cities" do
    field :country_code, :string
    field :subdivision_code, :string
    field :external_code, :string
    field :name, :string
    field :timezone, :string
    field :status, :string

    timestamps()
  end
end
