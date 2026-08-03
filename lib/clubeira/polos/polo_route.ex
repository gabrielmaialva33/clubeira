defmodule Clubeira.Polos.PoloRoute do
  @moduledoc """
  A globally resolvable public address for a polo.

  Routes deliberately live outside tenant RLS so an incoming hostname or URL
  slug can be translated into a `polo_id` before opening a scoped transaction.
  The tenant record itself remains protected.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo

  @primary_key false

  schema "polo_routes" do
    belongs_to :polo, Polo, primary_key: true

    field :slug, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          polo_id: Ecto.UUID.t(),
          slug: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
