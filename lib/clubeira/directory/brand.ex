defmodule Clubeira.Directory.Brand do
  @moduledoc """
  A commercial brand shared by one or more establishments.
  """

  use Clubeira.Schema

  schema "brands" do
    field :slug, :string
    field :name, :string
    field :status, :string

    timestamps()
  end
end
