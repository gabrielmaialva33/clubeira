defmodule Clubeira.Partnerships do
  @moduledoc """
  Versioned commercial agreements linking partner identities to one polo's catalog.
  """

  alias Clubeira.Partnerships.AgreementPublisher
  alias Clubeira.Partnerships.AgreementReader
  alias Clubeira.Tenancy.Scope

  @spec publish_agreement(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate publish_agreement(scope, attributes), to: AgreementPublisher, as: :publish

  @spec list_agreements(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_agreements(scope, params), to: AgreementReader, as: :list

  @spec get_agreement(Scope.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get_agreement(scope, agreement_id), to: AgreementReader, as: :get
end
