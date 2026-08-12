defmodule Clubeira.Privacy.RequestTransition do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false
  @actions_by_status %{
    "received" => ~w(start_identity_verification start_processing reject cancel),
    "identity_verification" => ~w(start_processing reject cancel),
    "in_progress" => ~w(complete partially_complete reject cancel)
  }
  @actions @actions_by_status |> Map.values() |> List.flatten() |> Enum.uniq()
  @fields [:action, :expected_status, :rejection_reason]

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

  @spec available_actions(term()) :: [String.t()]
  def available_actions(status), do: Map.get(@actions_by_status, status, [])

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes) do
    cast(%__MODULE__{}, attributes, @fields)
  end

  def change(_attributes) do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes
    |> change()
    |> update_change(:rejection_reason, &String.trim/1)
    |> validate_required([:action, :expected_status])
    |> validate_inclusion(:action, @actions)
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
    :invalid
    |> change()
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
