defmodule Clubeira.Partnerships.AgreementPublisher do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Catalog.BenefitOffer
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Catalog.Edition
  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.BrandOwnership
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Partnerships.AgreementBrand
  alias Clubeira.Partnerships.AgreementEdition
  alias Clubeira.Partnerships.AgreementOfferVersion
  alias Clubeira.Partnerships.AgreementOrganization
  alias Clubeira.Partnerships.AgreementPolo
  alias Clubeira.Partnerships.AgreementPoloPlace
  alias Clubeira.Partnerships.AgreementPublishRequest
  alias Clubeira.Partnerships.AgreementTerm
  alias Clubeira.Partnerships.PartnerAgreement
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "partnerships.publish_agreement"
  @replay_reasons %{
    "agreement_number_taken" => :agreement_number_taken,
    "brand_not_authorized" => :brand_not_authorized,
    "edition_not_found" => :edition_not_found,
    "benefit_offer_version_not_found" => :benefit_offer_version_not_found,
    "organization_not_found" => :organization_not_found,
    "polo_place_not_authorized" => :polo_place_not_authorized
  }

  @type result :: %{agreement: map(), replayed?: boolean()}

  @spec publish(Scope.t(), map()) :: {:ok, result()} | {:error, term()}
  def publish(%Scope{actor_user_id: nil}, _attributes), do: {:error, :partner_admin_required}

  def publish(%Scope{} = scope, attributes) when is_map(attributes) do
    with {:ok, request} <- AgreementPublishRequest.new(attributes) do
      scope
      |> transact_publish(request)
      |> unwrap_transaction()
    end
  end

  def publish(_scope, _attributes), do: {:error, :partner_admin_required}

  defp transact_publish(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now),
           :ok <- validate_signed_at(request, now) do
        reserve_publication(repo, scope, request, now)
      end
    end)
  end

  defp reserve_publication(repo, scope, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, request),
           now
         ) do
      {:new, idempotency_id} ->
        publish_new(repo, scope, request, idempotency_id, now)

      {:replay, key} ->
        {:ok, replay(key)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_new(repo, scope, request, idempotency_id, now) do
    case validate_references(repo, scope, request, now) do
      :ok ->
        insert_graph(repo, scope, request, idempotency_id, now)

      {:error, reason} ->
        {:ok, reject!(repo, scope, idempotency_id, reason, now)}
    end
  end

  defp insert_graph(repo, scope, request, idempotency_id, now) do
    case insert_agreement(repo, request, now) do
      {:ok, agreement} ->
        result = complete_graph!(repo, scope, agreement, request, now)

        Idempotency.complete!(
          repo,
          idempotency_id,
          "partner_agreement",
          agreement.id,
          result,
          now
        )

        {:ok, {:accepted, %{agreement: result, replayed?: false}}}

      {:error, :agreement_number_taken} ->
        {:ok, reject!(repo, scope, idempotency_id, :agreement_number_taken, now)}

      {:error, %Ecto.Changeset{} = changeset} ->
        repo.rollback(changeset)
    end
  end

  defp insert_agreement(repo, request, now) do
    %PartnerAgreement{
      agreement_number: request.agreement_number,
      name: request.name,
      valid_during: range(request.valid_from, request.valid_until),
      status: "active",
      signed_at: request.signed_at,
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:agreement_number,
      name: :partner_agreements_agreement_number_index
    )
    |> repo.insert(mode: :savepoint)
    |> classify_agreement_insert()
  end

  defp classify_agreement_insert({:error, %Ecto.Changeset{} = changeset}) do
    conflict? =
      Enum.any?(changeset.errors, fn
        {:agreement_number, {_message, metadata}} ->
          metadata[:constraint] == :unique and
            metadata[:constraint_name] == "partner_agreements_agreement_number_index"

        _other ->
          false
      end)

    if conflict?, do: {:error, :agreement_number_taken}, else: {:error, changeset}
  end

  defp classify_agreement_insert(result), do: result

  defp complete_graph!(repo, scope, agreement, request, now) do
    term =
      %AgreementTerm{
        partner_agreement_id: agreement.id,
        version: 1,
        effective_during: agreement.valid_during,
        settlement_model: request.settlement_model,
        redemption_sla_seconds: request.redemption_sla_seconds,
        published_at: now,
        inserted_at: now
      }
      |> repo.insert!()

    insert_organizations!(repo, agreement.id, request.organization_ids, now)
    insert_brands!(repo, agreement.id, request.brand_ids, now)
    insert_polo!(repo, agreement.id, scope.polo_id, now)
    insert_polo_places!(repo, agreement.id, scope.polo_id, request.polo_place_ids, now)
    insert_editions!(repo, agreement.id, scope.polo_id, request.edition_ids, now)

    insert_offer_versions!(
      repo,
      agreement.id,
      scope.polo_id,
      request.benefit_offer_version_ids,
      now
    )

    result = response_data(agreement, term, scope.polo_id, request)
    record_publication!(repo, scope, agreement, result, now)
    result
  end

  defp insert_organizations!(repo, agreement_id, ids, now) do
    rows =
      Enum.map(
        ids,
        &%{
          partner_agreement_id: agreement_id,
          organization_id: &1,
          party_role: "partner",
          inserted_at: now
        }
      )

    repo.insert_all(AgreementOrganization, rows)
  end

  defp insert_brands!(repo, agreement_id, ids, now) do
    rows =
      Enum.map(
        ids,
        &%{
          partner_agreement_id: agreement_id,
          brand_id: &1,
          inserted_at: now
        }
      )

    repo.insert_all(AgreementBrand, rows)
  end

  defp insert_polo!(repo, agreement_id, polo_id, now) do
    %AgreementPolo{partner_agreement_id: agreement_id, polo_id: polo_id, inserted_at: now}
    |> repo.insert!()
  end

  defp insert_polo_places!(repo, agreement_id, polo_id, ids, now) do
    rows =
      Enum.map(
        ids,
        &%{
          partner_agreement_id: agreement_id,
          polo_id: polo_id,
          polo_place_id: &1,
          inserted_at: now
        }
      )

    repo.insert_all(AgreementPoloPlace, rows)
  end

  defp insert_editions!(repo, agreement_id, polo_id, ids, now) do
    rows =
      Enum.map(
        ids,
        &%{
          partner_agreement_id: agreement_id,
          polo_id: polo_id,
          edition_id: &1,
          inserted_at: now
        }
      )

    repo.insert_all(AgreementEdition, rows)
  end

  defp insert_offer_versions!(repo, agreement_id, polo_id, ids, now) do
    rows =
      Enum.map(
        ids,
        &%{
          partner_agreement_id: agreement_id,
          polo_id: polo_id,
          benefit_offer_version_id: &1,
          inserted_at: now
        }
      )

    repo.insert_all(AgreementOfferVersion, rows)
  end

  defp validate_references(repo, scope, request, now) do
    with :ok <- validate_organizations(repo, request.organization_ids),
         :ok <- validate_brands(repo, request.brand_ids, request.organization_ids, now),
         :ok <- validate_polo_places(repo, scope, request, now),
         :ok <- validate_editions(repo, scope.polo_id, request.edition_ids) do
      validate_offer_versions(repo, scope.polo_id, request.benefit_offer_version_ids, now)
    end
  end

  defp validate_organizations(repo, ids) do
    count =
      Organization
      |> where([organization], organization.id in ^ids and organization.status == "active")
      |> select([organization], count(organization.id))
      |> repo.one()

    exact_count(count, ids, :organization_not_found)
  end

  defp validate_brands(_repo, [], _organization_ids, _now), do: :ok

  defp validate_brands(repo, ids, organization_ids, now) do
    count =
      Brand
      |> join(:inner, [brand], ownership in BrandOwnership, on: ownership.brand_id == brand.id)
      |> where([brand], brand.id in ^ids and brand.status == "active")
      |> where([_brand, ownership], ownership.organization_id in ^organization_ids)
      |> where(
        [_brand, ownership],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          ownership.valid_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> select([brand], count(fragment("DISTINCT ?", brand.id)))
      |> repo.one()

    exact_count(count, ids, :brand_not_authorized)
  end

  defp validate_polo_places(repo, scope, request, now) do
    count =
      PoloPlace
      |> join(:inner, [polo_place], place in Place, on: place.id == polo_place.place_id)
      |> join(:inner, [_polo_place, place], operator in PlaceOperator,
        on: operator.place_id == place.id
      )
      |> where(
        [polo_place, place],
        polo_place.id in ^request.polo_place_ids and polo_place.polo_id == ^scope.polo_id and
          polo_place.status == "active" and place.status == "active"
      )
      |> where(
        [polo_place],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          polo_place.participation_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> where(
        [_polo_place, _place, operator],
        operator.organization_id in ^request.organization_ids and operator.role == "operator"
      )
      |> where(
        [_polo_place, _place, operator],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          operator.valid_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> select([polo_place], count(fragment("DISTINCT ?", polo_place.id)))
      |> repo.one()

    exact_count(count, request.polo_place_ids, :polo_place_not_authorized)
  end

  defp validate_editions(_repo, _polo_id, []), do: :ok

  defp validate_editions(repo, polo_id, ids) do
    count =
      Edition
      |> where(
        [edition],
        edition.id in ^ids and edition.polo_id == ^polo_id and
          edition.status in ["on_sale", "active"]
      )
      |> select([edition], count(edition.id))
      |> repo.one()

    exact_count(count, ids, :edition_not_found)
  end

  defp validate_offer_versions(repo, polo_id, ids, now) do
    count =
      BenefitOfferVersion
      |> join(:inner, [version], offer in BenefitOffer,
        on: offer.id == version.benefit_offer_id and offer.polo_id == version.polo_id
      )
      |> where(
        [version, offer],
        version.id in ^ids and version.polo_id == ^polo_id and version.status == "published" and
          offer.status == "active"
      )
      |> where(
        [version],
        fragment(
          "? @> (? AT TIME ZONE 'UTC')",
          version.effective_during,
          type(^now, :utc_datetime_usec)
        )
      )
      |> select([version], count(version.id))
      |> repo.one()

    exact_count(count, ids, :benefit_offer_version_not_found)
  end

  defp exact_count(count, ids, reason) do
    if count == length(ids), do: :ok, else: {:error, reason}
  end

  defp fetch_active_polo(repo, polo_id) do
    case repo.one(from polo in Polo, where: polo.id == ^polo_id, lock: "FOR SHARE") do
      %Polo{status: "active"} = polo -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp validate_signed_at(request, now) do
    cond do
      DateTime.after?(request.signed_at, now) -> {:error, :invalid_signed_at}
      DateTime.before?(request.signed_at, request.valid_from) -> {:error, :invalid_signed_at}
      not DateTime.before?(request.signed_at, request.valid_until) -> {:error, :invalid_signed_at}
      true -> :ok
    end
  end

  defp record_publication!(repo, scope, agreement, result, now) do
    payload = %{
      "partner_agreement_id" => agreement.id,
      "agreement_number" => agreement.agreement_number,
      "organization_ids" => result["organization_ids"],
      "polo_place_ids" => result["polo_place_ids"],
      "benefit_offer_version_ids" => result["benefit_offer_version_ids"],
      "term_version" => 1,
      "published_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "partner_agreement",
      aggregate_id: agreement.id,
      aggregate_version: 1,
      event_type: "partner_agreement.published",
      topic: "partnerships.agreements.published",
      message_key: agreement.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "partner_agreement.published",
      resource_type: "partner_agreement",
      resource_id: agreement.id,
      metadata: payload,
      occurred_at: now
    })
  end

  defp response_data(agreement, term, polo_id, request) do
    %{
      "id" => agreement.id,
      "agreement_number" => agreement.agreement_number,
      "name" => agreement.name,
      "status" => agreement.status,
      "valid_from" => DateTime.to_iso8601(agreement.valid_during.lower),
      "valid_until" => range_bound(agreement.valid_during.upper),
      "signed_at" => DateTime.to_iso8601(agreement.signed_at),
      "terms" => %{
        "id" => term.id,
        "version" => term.version,
        "settlement_model" => term.settlement_model,
        "redemption_sla_seconds" => term.redemption_sla_seconds,
        "published_at" => DateTime.to_iso8601(term.published_at)
      },
      "organization_ids" => Enum.sort(request.organization_ids),
      "brand_ids" => Enum.sort(request.brand_ids),
      "polo_ids" => [polo_id],
      "polo_place_ids" => Enum.sort(request.polo_place_ids),
      "edition_ids" => Enum.sort(request.edition_ids),
      "benefit_offer_version_ids" => Enum.sort(request.benefit_offer_version_ids)
    }
  end

  defp replay(%Key{status: "completed", response_status: 201, response_body: body})
       when is_map(body),
       do: {:accepted, %{agreement: body, replayed?: true}}

  defp replay(%Key{status: "failed", response_body: %{"reason" => reason}}),
    do: {:denied, Map.fetch!(@replay_reasons, reason)}

  defp replay(key), do: raise("invalid persisted agreement response: #{inspect(key)}")

  defp reject!(repo, scope, idempotency_id, reason, now) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now,
      response_status: failure_status(reason)
    )

    Audit.record_tenant!(repo, scope, %{
      action: "partner_agreement.publication_rejected",
      resource_type: "partner_agreement_publication",
      metadata: %{"reason" => Atom.to_string(reason)},
      occurred_at: now
    })

    {:denied, reason}
  end

  defp failure_status(:agreement_number_taken), do: 409
  defp failure_status(_reason), do: 422

  defp request_hash(scope, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.agreement_number,
      request.name,
      request.valid_from,
      request.valid_until,
      request.signed_at,
      request.settlement_model,
      request.redemption_sla_seconds,
      Enum.sort(request.organization_ids),
      Enum.sort(request.brand_ids),
      Enum.sort(request.polo_place_ids),
      Enum.sort(request.edition_ids),
      Enum.sort(request.benefit_offer_version_ids)
    })
  end

  defp range(lower, upper) do
    %Postgrex.Range{
      lower: lower,
      upper: upper,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp range_bound(:unbound), do: nil
  defp range_bound(value), do: DateTime.to_iso8601(value)

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
