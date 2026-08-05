defmodule Clubeira.Directory.PartnerOnboarder do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Directory.Address
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationIdentifier
  alias Clubeira.Directory.PartnerOnboardingRequest
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceOperator
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Security.IdentifierVault
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "directory.onboard_partner"
  @replay_reasons %{
    "cnpj_already_registered" => :cnpj_already_registered,
    "place_slug_taken" => :place_slug_taken
  }

  @type result :: %{
          organization: Organization.t(),
          place: Place.t(),
          participation: PoloPlace.t()
        }

  @spec onboard(Scope.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def onboard(%Scope{actor_user_id: nil}, _attributes), do: {:error, :partner_admin_required}

  def onboard(%Scope{} = scope, attributes) when is_map(attributes) do
    with {:ok, request} <- PartnerOnboardingRequest.new(attributes) do
      scope
      |> transact_onboarding(request)
      |> unwrap_transaction()
    end
  end

  def onboard(_scope, _attributes), do: {:error, :partner_admin_required}

  defp transact_onboarding(scope, request) do
    Repo.transact_in_polo(scope, fn repo ->
      now = transaction_time(repo)

      with {:ok, polo} <- fetch_active_polo(repo, scope.polo_id),
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now) do
        {:ok, reserve_onboarding(repo, scope, polo, request, now)}
      end
    end)
  end

  defp reserve_onboarding(repo, scope, polo, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, request),
           now
         ) do
      {:new, idempotency_id} ->
        onboard_new(repo, scope, polo, request, idempotency_id, now)

      {:replay, key} ->
        replay(repo, key)

      {:error, reason} ->
        {:denied, reason}
    end
  end

  defp onboard_new(repo, scope, polo, request, idempotency_id, now) do
    address = insert_address!(repo, polo, request, now)

    case insert_place(repo, polo, address, request, now) do
      {:ok, place} ->
        insert_partner_identity(repo, scope, polo, address, place, request, idempotency_id, now)

      {:error, %Ecto.Changeset{}} ->
        repo.delete!(address)
        reject!(repo, idempotency_id, :place_slug_taken, now)
    end
  end

  defp insert_partner_identity(
         repo,
         scope,
         polo,
         address,
         place,
         request,
         idempotency_id,
         now
       ) do
    organization = insert_organization!(repo, request, now)
    sealed_cnpj = IdentifierVault.seal("cnpj", request.cnpj)

    case insert_identifier(repo, organization, sealed_cnpj, now) do
      {:ok, _identifier} ->
        complete_onboarding!(repo, scope, polo, organization, place, idempotency_id, now)

      {:error, %Ecto.Changeset{}} ->
        repo.delete!(organization)
        repo.delete!(place)
        repo.delete!(address)
        reject!(repo, idempotency_id, :cnpj_already_registered, now)
    end
  end

  defp complete_onboarding!(
         repo,
         scope,
         polo,
         organization,
         place,
         idempotency_id,
         now
       ) do
    active_range = active_range(now)

    %PlaceOperator{
      place_id: place.id,
      organization_id: organization.id,
      role: "operator",
      valid_during: active_range,
      inserted_at: now
    }
    |> repo.insert!()

    participation =
      %PoloPlace{
        city_id: polo.city_id,
        polo_id: polo.id,
        place_id: place.id,
        participation_during: active_range,
        status: "active",
        inserted_at: now,
        updated_at: now
      }
      |> repo.insert!()

    result = %{organization: organization, place: place, participation: participation}
    record_onboarding!(repo, scope, result, now)

    Idempotency.complete!(
      repo,
      idempotency_id,
      "polo_place",
      participation.id,
      %{
        "organization_id" => organization.id,
        "place_id" => place.id,
        "polo_place_id" => participation.id
      },
      now
    )

    {:accepted, result}
  end

  defp insert_address!(repo, polo, request, now) do
    %Address{
      city_id: polo.city_id,
      postal_code: request.postal_code,
      street: request.street,
      number: request.number,
      complement: empty_to_nil(request.complement),
      district: request.district,
      inserted_at: now,
      updated_at: now
    }
    |> repo.insert!()
  end

  defp insert_place(repo, polo, address, request, now) do
    %Place{
      city_id: polo.city_id,
      address_id: address.id,
      slug: request.place_slug,
      name: request.place_name,
      timezone: polo.timezone,
      status: "active",
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:slug, name: :places_city_id_slug_index)
    |> repo.insert(mode: :savepoint)
  end

  defp insert_organization!(repo, request, now) do
    %Organization{
      kind: "legal_entity",
      legal_name: request.legal_name,
      trade_name: request.trade_name,
      country_code: "BR",
      status: "active",
      inserted_at: now,
      updated_at: now
    }
    |> repo.insert!()
  end

  defp insert_identifier(repo, organization, sealed, now) do
    organization
    |> OrganizationIdentifier.create_changeset("cnpj", sealed, now)
    |> repo.insert(mode: :savepoint)
  end

  defp record_onboarding!(repo, scope, result, now) do
    payload = %{
      "organization_id" => result.organization.id,
      "place_id" => result.place.id,
      "polo_place_id" => result.participation.id,
      "status" => result.participation.status,
      "onboarded_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "polo_place",
      aggregate_id: result.participation.id,
      aggregate_version: 1,
      event_type: "partner.onboarded",
      topic: "partners.onboarded",
      message_key: result.participation.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: "partner.onboarded",
      resource_type: "polo_place",
      resource_id: result.participation.id,
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

  defp replay(
         repo,
         %Key{
           status: "completed",
           resource_type: "polo_place",
           response_body: %{
             "organization_id" => organization_id,
             "place_id" => place_id,
             "polo_place_id" => polo_place_id
           }
         }
       ) do
    with %Organization{} = organization <- repo.get(Organization, organization_id),
         %Place{} = place <- repo.get(Place, place_id),
         %PoloPlace{} = participation <- repo.get(PoloPlace, polo_place_id) do
      {:accepted, %{organization: organization, place: place, participation: participation}}
    else
      nil -> raise "completed partner onboarding key points to missing resources"
    end
  end

  defp replay(_repo, %Key{status: "failed", response_body: %{"reason" => reason}}) do
    {:denied, Map.fetch!(@replay_reasons, reason)}
  end

  defp replay(_repo, key) do
    raise "invalid persisted partner onboarding response: #{inspect(key)}"
  end

  defp reject!(repo, idempotency_id, reason, now) do
    Idempotency.fail!(repo, idempotency_id, reason, nil, nil, now)
    {:denied, reason}
  end

  defp request_hash(scope, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      request.legal_name,
      request.trade_name,
      request.cnpj,
      request.place_name,
      request.place_slug,
      request.postal_code,
      request.street,
      request.number,
      request.complement,
      request.district
    })
  end

  defp active_range(now) do
    %Postgrex.Range{
      lower: now,
      upper: :unbound,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp request_metadata(%Scope{request_id: nil}), do: %{}
  defp request_metadata(%Scope{request_id: request_id}), do: %{"request_id" => request_id}
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:denied, reason}}), do: {:error, reason}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
