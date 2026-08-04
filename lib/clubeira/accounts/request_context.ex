defmodule Clubeira.Accounts.RequestContext do
  @moduledoc """
  Global request metadata used by authentication and system audit events.
  """

  @enforce_keys [:request_id]
  defstruct [:request_id]

  @type t :: %__MODULE__{
          request_id: Ecto.UUID.t()
        }

  @spec new!(Ecto.UUID.t()) :: t()
  def new!(request_id \\ generate_request_id()) do
    %__MODULE__{request_id: Ecto.UUID.cast!(request_id)}
  end

  defp generate_request_id, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
