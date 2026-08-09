defmodule Clubeira.Platform.PlanVersion do
  @moduledoc "Immutable published definition of a platform plan."

  use Clubeira.Schema

  alias Clubeira.Platform.Plan

  schema "platform_plan_versions" do
    belongs_to :platform_plan, Plan

    field :version, :integer
    field :name, :string
    field :description, :string
    field :status, :string
    field :published_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          platform_plan_id: Ecto.UUID.t(),
          version: pos_integer(),
          name: String.t(),
          description: String.t(),
          status: String.t(),
          published_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }
end
