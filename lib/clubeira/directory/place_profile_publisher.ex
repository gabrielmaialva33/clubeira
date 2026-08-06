defmodule Clubeira.Directory.PlaceProfilePublisher do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Audit
  alias Clubeira.Directory.Place
  alias Clubeira.Directory.PlaceCategory
  alias Clubeira.Directory.PlaceProfileUpdateRequest
  alias Clubeira.Directory.PlaceProfileView
  alias Clubeira.Directory.PoloPlaceOpeningPeriod
  alias Clubeira.Directory.PoloPlaceProfile
  alias Clubeira.Directory.PoloPlaceProfileCategory
  alias Clubeira.Events
  alias Clubeira.Idempotency
  alias Clubeira.Idempotency.Key
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @idempotency_scope "directory.publish_place_profile"

  @type result :: %{String.t() => term()}

  @spec publish(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def publish(%Scope{actor_user_id: nil}, _place_id, _attributes),
    do: {:error, :partner_admin_required}

  def publish(%Scope{} = scope, place_id, attributes) when is_map(attributes) do
    with {:ok, place_id} <- cast_place_id(place_id),
         {:ok, request} <- PlaceProfileUpdateRequest.new(attributes) do
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
           :ok <- Authorization.authorize(repo, scope, :manage_partners, now) do
        reserve_publish(repo, scope, place_id, request, now)
      end
    end)
  end

  defp reserve_publish(repo, scope, place_id, request, now) do
    case Idempotency.reserve(
           repo,
           scope,
           @idempotency_scope,
           request.idempotency_key,
           request_hash(scope, place_id, request),
           now
         ) do
      {:new, idempotency_id} ->
        with {:ok, participation} <- fetch_active_participation(repo, scope, place_id),
             {:ok, categories} <- fetch_categories(repo, request.category_keys) do
          {:ok,
           publish_new!(
             repo,
             scope,
             place_id,
             participation,
             categories,
             request,
             idempotency_id,
             now
           )}
        end

      {:replay, key} ->
        {:ok, replay(key)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_new!(repo, scope, place_id, participation, categories, request, key_id, now) do
    profile = upsert_profile!(repo, scope, participation, request, now)
    replace_categories!(repo, scope, profile, categories, now)
    periods = replace_opening_periods!(repo, scope, profile, request, now)

    result = %{
      "place_id" => place_id,
      "polo_place_id" => participation.id,
      "profile" => PlaceProfileView.build(profile, categories, periods)
    }

    record_publication!(repo, scope, place_id, profile, categories, request, now)

    Idempotency.complete!(
      repo,
      key_id,
      "polo_place_profile",
      profile.id,
      result,
      now,
      response_status: 200
    )

    {:accepted, result}
  end

  defp upsert_profile!(repo, scope, participation, request, now) do
    existing =
      PoloPlaceProfile
      |> where(
        [profile],
        profile.polo_id == ^scope.polo_id and profile.polo_place_id == ^participation.id
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    case existing do
      nil ->
        %PoloPlaceProfile{
          polo_id: scope.polo_id,
          polo_place_id: participation.id,
          public_email: request.public_email,
          public_phone: request.public_phone,
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
        |> repo.insert!()

      %PoloPlaceProfile{} = profile ->
        profile
        |> Ecto.Changeset.change(%{
          public_email: request.public_email,
          public_phone: request.public_phone,
          revision: profile.revision + 1,
          updated_at: now
        })
        |> repo.update!()
    end
  end

  defp replace_categories!(repo, scope, profile, categories, now) do
    repo.delete_all(
      from(category in PoloPlaceProfileCategory,
        where:
          category.polo_id == ^scope.polo_id and
            category.polo_place_profile_id == ^profile.id
      )
    )

    Enum.each(categories, fn category ->
      %PoloPlaceProfileCategory{
        polo_id: scope.polo_id,
        polo_place_profile_id: profile.id,
        place_category_id: category.id,
        inserted_at: now
      }
      |> repo.insert!()
    end)
  end

  defp replace_opening_periods!(repo, scope, profile, request, now) do
    repo.delete_all(
      from(period in PoloPlaceOpeningPeriod,
        where:
          period.polo_id == ^scope.polo_id and
            period.polo_place_profile_id == ^profile.id
      )
    )

    request
    |> period_attributes()
    |> Enum.map(fn attributes ->
      struct!(PoloPlaceOpeningPeriod, %{
        id: uuid7(),
        polo_id: scope.polo_id,
        polo_place_profile_id: profile.id,
        kind: attributes.kind,
        weekday: Map.get(attributes, :weekday),
        local_date: Map.get(attributes, :local_date),
        opens_at: Map.get(attributes, :opens_at),
        closes_at: Map.get(attributes, :closes_at),
        closes_next_day: Map.get(attributes, :closes_next_day, false),
        inserted_at: now,
        updated_at: now
      })
      |> repo.insert!()
    end)
  end

  defp period_attributes(request) do
    weekly =
      Enum.map(request.weekly_hours, fn window ->
        Map.put(window, :kind, "weekly")
      end)

    special =
      Enum.flat_map(request.special_hours, fn
        %{kind: "closed", local_date: local_date} ->
          [%{kind: "exception_closed", local_date: local_date}]

        %{kind: "custom", local_date: local_date, windows: windows} ->
          Enum.map(windows, fn window ->
            window
            |> Map.put(:kind, "exception_open")
            |> Map.put(:local_date, local_date)
          end)
      end)

    weekly ++ special
  end

  defp record_publication!(repo, scope, place_id, profile, categories, request, now) do
    {action, topic} =
      if profile.revision == 1 do
        {"place_profile.published", "places.profiles.published"}
      else
        {"place_profile.updated", "places.profiles.updated"}
      end

    payload = %{
      "polo_place_profile_id" => profile.id,
      "polo_place_id" => profile.polo_place_id,
      "place_id" => place_id,
      "revision" => profile.revision,
      "category_ids" => Enum.map(categories, & &1.id),
      "weekly_hours_count" => length(request.weekly_hours),
      "special_hours_count" => length(request.special_hours),
      "published_at" => DateTime.to_iso8601(now)
    }

    Events.emit!(repo, %{
      polo_id: scope.polo_id,
      aggregate_type: "polo_place_profile",
      aggregate_id: profile.id,
      aggregate_version: profile.revision,
      event_type: action,
      topic: topic,
      message_key: profile.id,
      payload: payload,
      metadata: request_metadata(scope),
      occurred_at: now
    })

    Audit.record_tenant!(repo, scope, %{
      action: action,
      resource_type: "polo_place_profile",
      resource_id: profile.id,
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
      |> lock("FOR UPDATE")
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

  defp fetch_categories(repo, category_keys) do
    categories =
      PlaceCategory
      |> where([category], category.key in ^category_keys and category.status == "active")
      |> order_by([category], asc: category.display_order, asc: category.key)
      |> lock("FOR SHARE")
      |> repo.all()

    if MapSet.new(Enum.map(categories, & &1.key)) == MapSet.new(category_keys) do
      {:ok, categories}
    else
      {:error, :invalid_categories}
    end
  end

  defp replay(%Key{
         status: "completed",
         response_status: 200,
         resource_type: "polo_place_profile",
         response_body: response_body
       })
       when is_map(response_body),
       do: {:accepted, response_body}

  defp replay(key), do: raise("invalid persisted place profile response: #{inspect(key)}")

  defp request_hash(scope, place_id, request) do
    Idempotency.fingerprint({
      1,
      scope.polo_id,
      scope.actor_user_id,
      place_id,
      request.public_email,
      request.public_phone,
      request.category_keys,
      request.weekly_hours,
      request.special_hours
    })
  end

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

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)

  defp unwrap_transaction({:ok, {:accepted, result}}), do: {:ok, result}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
