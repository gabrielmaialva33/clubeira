defmodule Clubeira.Schema do
  @moduledoc """
  Shared Ecto schema defaults for Clubeira domain records.

  UUIDv7 values are generated in the application so aggregates can reference
  their identifiers before persistence. Database defaults remain the fallback
  for writers outside Ecto.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]}
      @foreign_key_type Ecto.UUID
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
