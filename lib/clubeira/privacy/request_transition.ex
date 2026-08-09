defmodule Clubeira.Privacy.RequestTransition do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :action, :string
    field :expected_status, :string
    field :rejection_reason, :string
  end

  @type t :: %__MODULE__{
          action: String.t(),
          expected_status: String.t(),
          rejection_reason: String.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:action, :expected_status, :rejection_reason])
    |> update_change(:rejection_reason, &String.trim/1)
    |> validate_required([:action, :expected_status])
    |> validate_inclusion(:action, ~w(
      start_identity_verification
      start_processing
      complete
      partially_complete
      reject
      cancel
    ))
    |> validate_inclusion(:expected_status, ~w(
      received
      identity_verification
      in_progress
      completed
      partially_completed
      rejected
      cancelled
    ))
    |> validate_rejection_reason()
    |> apply_action(:update)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:update)
  end

  defp validate_rejection_reason(changeset) do
    if get_field(changeset, :action) == "reject" do
      changeset
      |> validate_required([:rejection_reason])
      |> validate_length(:rejection_reason, min: 3, max: 500)
    else
      case get_field(changeset, :rejection_reason) do
        nil -> changeset
        _reason -> add_error(changeset, :rejection_reason, "is only allowed when rejecting")
      end
    end
  end
end
