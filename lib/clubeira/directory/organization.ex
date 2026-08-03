defmodule Clubeira.Directory.Organization do
  @moduledoc """
  A legal or commercial organization in the partner network.
  """

  use Clubeira.Schema

  schema "organizations" do
    field :kind, :string
    field :legal_name, :string
    field :trade_name, :string
    field :country_code, :string
    field :status, :string

    timestamps()
  end
end
