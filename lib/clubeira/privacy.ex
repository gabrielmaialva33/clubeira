defmodule Clubeira.Privacy do
  @moduledoc """
  Consent timelines, data-subject requests, and their processing purposes.

  Consent is an idempotent desired-state PUT. Repeating the current state and
  legal version does not create duplicate immutable evidence.
  """

  alias Clubeira.Privacy.ConsentCommand
  alias Clubeira.Privacy.Consents
  alias Clubeira.Privacy.ProcessingPurposes
  alias Clubeira.Privacy.Requests
  alias Clubeira.Privacy.RequestSubmission
  alias Clubeira.Privacy.RequestTransition
  alias Clubeira.Tenancy.ActorScope

  @type consent_state :: Consents.state()

  @spec put_consent(ActorScope.t(), String.t(), map()) ::
          {:ok, consent_state()} | {:error, atom() | Ecto.Changeset.t()}
  def put_consent(%ActorScope{} = scope, purpose_code, attributes)
      when is_binary(purpose_code) and is_map(attributes) do
    with {:ok, command} <- ConsentCommand.new(attributes) do
      Consents.put(scope, purpose_code, command)
    end
  end

  def put_consent(%ActorScope{}, _purpose_code, attributes),
    do: ConsentCommand.new(attributes)

  def put_consent(_scope, _purpose_code, _attributes), do: {:error, :invalid_actor_scope}

  @spec list_consents(ActorScope.t()) ::
          {:ok, [consent_state()]} | {:error, :profile_required | :invalid_actor_scope}
  def list_consents(%ActorScope{} = scope), do: Consents.list(scope)
  def list_consents(_scope), do: {:error, :invalid_actor_scope}

  @spec submit_request(ActorScope.t(), map()) ::
          {:ok, %{request: map(), replayed?: boolean()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def submit_request(%ActorScope{} = scope, attributes) when is_map(attributes) do
    with {:ok, submission} <- RequestSubmission.new(attributes) do
      Requests.submit(scope, submission)
    end
  end

  def submit_request(%ActorScope{}, attributes), do: RequestSubmission.new(attributes)
  def submit_request(_scope, _attributes), do: {:error, :invalid_actor_scope}

  @spec list_requests(ActorScope.t()) ::
          {:ok, [map()]} | {:error, :profile_required | :invalid_actor_scope}
  def list_requests(%ActorScope{} = scope), do: Requests.list(scope)
  def list_requests(_scope), do: {:error, :invalid_actor_scope}

  @spec list_platform_requests(ActorScope.t(), map()) ::
          {:ok, %{requests: [map()], page: map()}} | {:error, atom()}
  def list_platform_requests(%ActorScope{} = scope, params) when is_map(params),
    do: Requests.list_platform(scope, params)

  def list_platform_requests(%ActorScope{}, _params), do: {:error, :invalid_pagination}
  def list_platform_requests(_scope, _params), do: {:error, :invalid_actor_scope}

  @spec transition_request(ActorScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{request: map(), replayed?: boolean()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def transition_request(%ActorScope{} = scope, request_id, attributes)
      when is_map(attributes) do
    with {:ok, request_id} <- cast_request_id(request_id),
         {:ok, transition} <- RequestTransition.new(attributes) do
      Requests.transition(scope, request_id, transition)
    end
  end

  def transition_request(%ActorScope{}, _request_id, attributes),
    do: RequestTransition.new(attributes)

  def transition_request(_scope, _request_id, _attributes),
    do: {:error, :invalid_actor_scope}

  @spec list_processing_purposes(ActorScope.t()) ::
          {:ok, [map()]} | {:error, atom()}
  def list_processing_purposes(%ActorScope{} = scope), do: ProcessingPurposes.list(scope)
  def list_processing_purposes(_scope), do: {:error, :invalid_actor_scope}

  @spec put_processing_purpose(ActorScope.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def put_processing_purpose(%ActorScope{} = scope, code, attributes)
      when is_binary(code) and is_map(attributes),
      do: ProcessingPurposes.put(scope, code, attributes)

  def put_processing_purpose(%ActorScope{}, _code, _attributes),
    do: {:error, :invalid_processing_purpose}

  def put_processing_purpose(_scope, _code, _attributes),
    do: {:error, :invalid_actor_scope}

  defp cast_request_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :privacy_request_not_found}
    end
  end
end
