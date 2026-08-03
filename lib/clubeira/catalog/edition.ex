defmodule Clubeira.Catalog.Edition do
  @moduledoc """
  A polo-scoped catalog edition with independent sales and benefit windows.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Types.TstzRange

  schema "editions" do
    belongs_to :polo, Polo

    field :code, :string
    field :name, :string
    field :sales_during, TstzRange
    field :benefits_during, TstzRange
    field :status, :string

    timestamps()
  end
end
