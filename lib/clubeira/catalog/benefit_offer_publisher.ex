defmodule Clubeira.Catalog.BenefitOfferPublisher do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferPublishRequest
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.BenefitOfferVersionPlace
  alias Clubeira.Directory.Place
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "catalog.publish_benefit_offer"
  @replay_reasons %{"offer_code_taken" => :offer_code_taken}

  @type result :: %{String.t() => term()}
  @type error ::
          atom()
          | {:tenant_scope_mismatch, :polo_id | :actor_user_id | :request_id}
          | Ecto.Changeset.t()

  @spec publish(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, error()}
  def publish(%Scope{actor_user_id: nil}, _place_id, _attributes),
    do: {:error, :partner_admin_required}

  def publish(%Scope{} = scope, place_id, attributes) when is_map(attributes) do
    with {:ok, place_id} <- cast_place_id(place_id),
         {:ok, request} <- BenefitOfferPublishRequest.new(attributes) do
      scope
      |> transact_publish(place_id, request)
      |> unwrap_transaction()
    end
  end

  def publish(_scope, _place_id, _attributes), do: {:error, :partner_admin_required}

  defp transact_publish(scope, place_id, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now),
           {:ok, participation} <- fetch_active_participation(repo, scope, place_id) do
        reserve_publish(repo, scope, place_id, participation, request, now)
      end
    end)
  end

  defp reserve_publish(repo, scope, place_id, participation, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, place_id, request),
           now
         ) do
      {:new, idempotency_id} ->
        {:ok,
         publish_new!(
           repo,
           scope,
           place_id,
           participation,
           request,
           idempotency_id,
           now
         )}

      {:replay, key} ->
        {:ok, replay(key)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_new!(repo, scope, place_id, participation, request, key_id, now) do
    case insert_offer(repo, scope, request, now) do
      {:ok, offer} ->
        complete_publication!(repo, scope, place_id, participation, offer, request, key_id, now)

      {:error, :offer_code_taken} ->
        reject!(repo, scope, key_id, :offer_code_taken, now)

      {:error, %Ecto.Changeset{} = changeset} ->
        repo.rollback(changeset)
    end
  end

  defp insert_offer(repo, scope, request, now) do
    %BenefitOffer{
      polo_id: scope.polo_id,
      code: request.code,
      name: request.name,
      benefit_kind: request.benefit_kind,
      status: "active",
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:code, name: :benefit_offers_polo_id_code_index)
    |> repo.insert(mode: :savepoint)
    |> classify_offer_insert()
  end

  defp classify_offer_insert({:error, %Ecto.Changeset{} = changeset}) do
    if offer_code_conflict?(changeset),
      do: {:error, :offer_code_taken},
      else: {:error, changeset}
  end

  defp classify_offer_insert(result), do: result

  defp offer_code_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:code, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          metadata[:constraint_name] == "benefit_offers_polo_id_code_index"

      _other ->
        false
    end)
  end

  defp complete_publication!(
         repo,
         scope,
         place_id,
         participation,
         offer,
         request,
         key_id,
         now
       ) do
    version =
      %BenefitOfferVersion{
        polo_id: scope.polo_id,
        benefit_offer_id: offer.id,
        version: 1,
        title: request.title,
        description: request.description,
        terms: request.terms,
        redemption_instructions: request.redemption_instructions,
        percentage_value: request.percentage_value,
        amount_value: request.amount_value,
        currency: request.currency,
        effective_during: effective_range(request),
        status: "published",
        published_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    %BenefitOfferVersionPlace{
      polo_id: scope.polo_id,
      benefit_offer_version_id: version.id,
      polo_place_id: participation.id,
      inserted_at: now
    }
    |> repo.insert!()

    result = response_data(place_id, participation.id, offer, version)

    record_publication!(repo, scope, place_id, participation.id, offer, version, now)

    Idempotency.complete!(repo, key_id, "benefit_offer", offer.id, result, now)

    {:accepted, result}
  end

  defp record_publication!(repo, scope, place_id, polo_place_id, offer, version, now) do
    payload = %{
      "benefit_offer_id" => offer.id,
      "benefit_offer_version_id" => version.id,
      "polo_place_id" => polo_place_id,
      "place_id" => place_id,
      "code" => offer.code,
      "benefit_kind" => offer.benefit_kind,
      "version" => version.version,
      "published_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "benefit_offer",
      aggregate_id: offer.id,
      aggregate_version: version.version,
      event_type: "benefit_offer.published",
      topic: "catalog.benefit_offers.published",
      message_key: offer.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "benefit_offer.published",
      resource_type: "benefit_offer",
      resource_id: offer.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp fetch_active_polo(repo, polo_id) do
    polo =
      Polo
      |> where([polo], polo.id == ^polo_id)
      |> lock("FOR SHARE")
      |> repo.one()

    case polo do
      %Polo{status: "active"} -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp fetch_active_participation(repo, scope, place_id) do
    participation =
      PoloPlace
      |> where([polo_place], polo_place.polo_id == ^scope.polo_id)
      |> where([polo_place], polo_place.place_id == ^place_id and polo_place.status == "active")
      |> where(
        [polo_place],
        fragment("? @> statement_timestamp()", polo_place.participation_during)
      )
      |> lock("FOR SHARE")
      |> repo.one()

    case participation do
      %PoloPlace{} -> ensure_active_place(repo, participation)
      nil -> {:error, :place_not_found}
    end
  end

  defp ensure_active_place(repo, participation) do
    active_place =
      Place
      |> where([place], place.id == ^participation.place_id and place.status == "active")
      |> lock("FOR SHARE")
      |> repo.one()

    if active_place, do: {:ok, participation}, else: {:error, :place_not_found}
  end

  defp replay(%Key{
         status: "completed",
         response_status: 201,
         resource_type: "benefit_offer",
         response_body: response_body
       })
       when is_map(response_body),
       do: {:accepted, response_body}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(key), do: raise("invalid persisted benefit offer response: #{inspect(key)}")

  defp reject!(repo, scope, idempotency_id, reason, now) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now, response_status: 409)

    Audit.record_tenant!(repo, scope, %{
      action: "benefit_offer.publication_rejected",
      resource_type: "benefit_offer_publication",
      metadata: %{"reason" => Atom.to_string(reason)},
      occurred_at: now
    })

    {:denied, reason}
  end

  defp request_hash(scope, place_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      place_id,
      request.code,
      request.name,
      request.benefit_kind,
      request.title,
      request.description,
      request.terms,
      request.redemption_instructions,
      request.percentage_value,
      request.amount_value,
      request.currency,
      request.effective_from,
      request.effective_until
    })
  end

  defp response_data(place_id, polo_place_id, offer, version) do
    %{
      "offer" => %{
        "id" => offer.id,
        "code" => offer.code,
        "name" => offer.name,
        "benefit_kind" => offer.benefit_kind,
        "status" => offer.status
      },
      "version" => %{
        "id" => version.id,
        "number" => version.version,
        "title" => version.title,
        "description" => version.description,
        "terms" => version.terms,
        "redemption_instructions" => version.redemption_instructions,
        "benefit" => %{
          "percentage" => decimal_to_string(version.percentage_value),
          "amount" => decimal_to_string(version.amount_value),
          "currency" => version.currency
        },
        "effective_during" => %{
          "starts_at" => DateTime.to_iso8601(version.effective_during.lower),
          "ends_at" => range_end(version.effective_during.upper)
        },
        "status" => version.status,
        "published_at" => DateTime.to_iso8601(version.published_at)
      },
      "place" => %{"id" => place_id, "polo_place_id" => polo_place_id}
    }
  end

  defp effective_range(request) do
    %Postgrex.Range{
      lower: request.effective_from,
      upper: request.effective_until || :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(value), do: Decimal.to_string(value, :normal)
  defp range_end(:unbound), do: nil
  defp range_end(value), do: DateTime.to_iso8601(value)

  defp cast_place_id(place_id) do
    case Ecto.UUID.cast(place_id) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :place_not_found}
    end
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
