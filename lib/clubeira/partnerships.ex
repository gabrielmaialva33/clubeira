defmodule Clubeira.Partnerships do
  @moduledoc """
  Versioned commercial agreements linking partner identities to one polo's catalog.
  """

  alias Clubeira.Partnerships.AgreementOptionsReader
  alias Clubeira.Partnerships.AgreementPublisher
  alias Clubeira.Partnerships.AgreementPublishRequest
  alias Clubeira.Partnerships.AgreementReader
  alias Clubeira.Tenancy.Scope

  @spec publish_agreement(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate publish_agreement(scope, attributes), to: AgreementPublisher, as: :publish

  @doc false
  @spec change_agreement_publish_request(term()) :: Ecto.Changeset.t()
  def change_agreement_publish_request(attributes \\ %{}) do
    AgreementPublishRequest.change(attributes)
  end

  @spec list_agreements(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_agreements(scope, params), to: AgreementReader, as: :list

  @spec get_agreement(Scope.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get_agreement(scope, agreement_id), to: AgreementReader, as: :get

  @doc """
  Lists the currently selectable references for publishing an agreement.

  The options mirror the publisher's authorization and temporal constraints so
  administrative clients do not have to submit opaque UUIDs blindly.
  """
  @spec list_agreement_options(Scope.t()) :: {:ok, map()} | {:error, term()}
  defdelegate list_agreement_options(scope), to: AgreementOptionsReader, as: :list
end
