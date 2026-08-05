defmodule Clubeira.Seeds.Demo.Polo do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Writer

  @range_start ~U[2026-01-01 00:00:00Z]
  @range_end ~U[2027-01-01 00:00:00Z]
  @default_validation_secret "M-bCcLGupP8XuBxzemHd-4JumJf6trsiQpinEl30xwg"

  @polo_fields ~w(city_id name timezone status updated_at)a
  @polo_route_fields ~w(slug updated_at)a
  @edition_fields ~w(polo_id code name sales_during benefits_during status updated_at)a
  @benefit_offer_fields ~w(polo_id code name benefit_kind status updated_at)a

  @benefit_offer_version_fields ~w(
    polo_id
    benefit_offer_id
    version
    title
    description
    terms
    redemption_instructions
    percentage_value
    amount_value
    currency
    effective_during
    status
    published_at
  )a

  @spec run!(keyword()) :: :ok
  def run!(options) do
    polo_id = Keyword.fetch!(options, :id)

    Seeds.with_polo!(polo_id, fn ->
      city = Keyword.fetch!(options, :city)

      polo =
        Writer.upsert!(
          :polo,
          %{
            id: polo_id,
            city: city,
            name: Keyword.fetch!(options, :name),
            timezone: Keyword.fetch!(options, :timezone),
            status: "active"
          },
          @polo_fields
        )

      Writer.upsert!(
        :polo_route,
        %{polo: polo, slug: Keyword.fetch!(options, :slug)},
        @polo_route_fields,
        conflict_target: [:polo_id]
      )

      Writer.insert_once!(:polo_policy_version, %{
        id: Keyword.fetch!(options, :policy_id),
        polo: polo,
        version: 1,
        effective_during: active_range(),
        published_at: @range_start
      })

      polo_places = seed_polo_places!(polo, city, Keyword.fetch!(options, :places))
      seed_validation_points!(polo, Keyword.get(options, :validation_points, []))
      edition = seed_edition!(polo, Keyword.fetch!(options, :edition_id))

      Enum.each(polo_places, fn polo_place ->
        Writer.insert_once!(:edition_place, %{
          polo: polo,
          edition: edition,
          polo_place: polo_place
        })
      end)

      seed_benefit_offers!(polo, Keyword.get(options, :offers, []))
    end)

    :ok
  end

  defp seed_polo_places!(polo, city, places) do
    Enum.map(places, fn {place, polo_place_id} ->
      Writer.insert_once!(:polo_place, %{
        id: polo_place_id,
        city: city,
        polo: polo,
        place: place,
        participation_during: active_range(),
        status: "active"
      })
    end)
  end

  defp seed_edition!(polo, edition_id) do
    Writer.upsert!(
      :edition,
      %{
        id: edition_id,
        polo: polo,
        code: "2026",
        name: "Temporada 2026",
        sales_during: edition_range(),
        benefits_during: edition_range(),
        status: "active"
      },
      @edition_fields
    )
  end

  defp seed_validation_points!(polo, validation_points) do
    secret_hash = validation_secret_hash!()

    Enum.each(validation_points, fn attributes ->
      validation_point =
        Writer.insert_once!(:validation_point, %{
          id: Map.fetch!(attributes, :id),
          polo_id: polo.id,
          polo_place_id: Map.fetch!(attributes, :polo_place_id),
          name: Map.fetch!(attributes, :name),
          kind: "api",
          status: "active"
        })

      credential =
        Writer.insert_once!(:validation_credential, %{
          id: Map.fetch!(attributes, :credential_id),
          polo_id: polo.id,
          validation_point_id: validation_point.id,
          version: 1,
          kind: "api_key",
          secret_hash: secret_hash,
          valid_during: active_range(),
          status: "active",
          inserted_at: @range_start
        })

      if credential.secret_hash != secret_hash do
        raise "demo validation secret changed in place; publish a new credential version"
      end
    end)
  end

  defp validation_secret_hash! do
    secret = System.get_env("CLUBEIRA_DEMO_VALIDATION_SECRET", @default_validation_secret)

    case Base.url_decode64(secret, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 32 -> :crypto.hash(:sha256, decoded)
      _invalid -> raise "CLUBEIRA_DEMO_VALIDATION_SECRET must encode exactly 32 random bytes"
    end
  end

  defp seed_benefit_offers!(polo, offers) do
    Enum.each(offers, fn attributes ->
      offer =
        Writer.upsert!(
          :benefit_offer,
          %{
            id: Map.fetch!(attributes, :id),
            polo: polo,
            code: Map.fetch!(attributes, :code),
            name: Map.fetch!(attributes, :name),
            benefit_kind: Map.fetch!(attributes, :benefit_kind),
            status: "active"
          },
          @benefit_offer_fields
        )

      version =
        Writer.upsert!(
          :benefit_offer_version,
          %{
            id: Map.fetch!(attributes, :version_id),
            polo: polo,
            benefit_offer: offer,
            version: 1,
            title: Map.fetch!(attributes, :title),
            description: Map.fetch!(attributes, :description),
            terms: "Um uso por ciclo enquanto a assinatura estiver ativa.",
            redemption_instructions: "Apresente o voucher antes de fechar a conta.",
            effective_during: active_range(),
            status: "published",
            published_at: @range_start
          },
          @benefit_offer_version_fields
        )

      Writer.insert_once!(:benefit_offer_version_place, %{
        polo: polo,
        benefit_offer_version: version,
        polo_place_id: Map.fetch!(attributes, :polo_place_id)
      })
    end)
  end

  defp active_range, do: Factory.tstz_range(@range_start)
  defp edition_range, do: Factory.tstz_range(@range_start, @range_end)
end
