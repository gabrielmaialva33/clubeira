defmodule Clubeira.Seeds.Demo.Profiles do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Directory.PoloPlaceOpeningPeriod
  alias Clubeira.Directory.PoloPlaceProfileCategory
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer

  @seeded_at ~U[2026-01-01 00:00:00Z]
  @category_fields ~w(key name status display_order updated_at)a
  @profile_fields ~w(polo_id polo_place_id public_email public_phone revision updated_at)a

  @spec run!() :: :ok
  def run! do
    categories = seed_categories!()

    Seeds.with_polo!(id(:polo_sobral), fn ->
      seed_profile!(
        profile_id: id(:profile_franchise_sobral),
        polo_id: id(:polo_sobral),
        polo_place_id: id(:polo_place_franchise_sobral),
        email: "sobral@cafe-horizonte.example",
        phone: "+5588999991001",
        categories: [categories.cafe, categories.bakery],
        periods: franchise_sobral_periods()
      )

      seed_profile!(
        profile_id: id(:profile_local_sobral),
        polo_id: id(:polo_sobral),
        polo_place_id: id(:polo_place_local_sobral),
        email: "reservas@sabores-do-acarau.example",
        phone: "+5588999991002",
        categories: [categories.restaurant, categories.regional_cuisine],
        periods: local_sobral_periods()
      )
    end)

    Seeds.with_polo!(id(:polo_londrina), fn ->
      seed_profile!(
        profile_id: id(:profile_franchise_londrina),
        polo_id: id(:polo_londrina),
        polo_place_id: id(:polo_place_franchise_londrina),
        email: "londrina@cafe-horizonte.example",
        phone: "+5543999991003",
        categories: [categories.cafe, categories.bakery],
        periods: franchise_londrina_periods()
      )
    end)

    :ok
  end

  defp seed_categories! do
    %{
      cafe: seed_category!(:category_cafe, "cafe", "Café", 10),
      bakery: seed_category!(:category_bakery, "bakery", "Padaria", 20),
      restaurant: seed_category!(:category_restaurant, "restaurant", "Restaurante", 30),
      regional_cuisine:
        seed_category!(
          :category_regional_cuisine,
          "regional-cuisine",
          "Culinária regional",
          40
        )
    }
  end

  defp seed_category!(id_name, key, name, display_order) do
    Writer.upsert!(
      :place_category,
      %{
        id: id(id_name),
        key: key,
        name: name,
        status: "active",
        display_order: display_order,
        inserted_at: @seeded_at,
        updated_at: @seeded_at
      },
      @category_fields
    )
  end

  defp seed_profile!(attributes) do
    profile_id = Keyword.fetch!(attributes, :profile_id)
    polo_id = Keyword.fetch!(attributes, :polo_id)

    profile =
      Writer.upsert!(
        :polo_place_profile,
        %{
          id: profile_id,
          polo_id: polo_id,
          polo_place_id: Keyword.fetch!(attributes, :polo_place_id),
          public_email: Keyword.fetch!(attributes, :email),
          public_phone: Keyword.fetch!(attributes, :phone),
          revision: 1,
          inserted_at: @seeded_at,
          updated_at: @seeded_at
        },
        @profile_fields
      )

    replace_profile_categories!(profile, Keyword.fetch!(attributes, :categories))
    replace_opening_periods!(profile, Keyword.fetch!(attributes, :periods))
  end

  defp replace_profile_categories!(profile, categories) do
    Repo.delete_all(
      from(profile_category in PoloPlaceProfileCategory,
        where:
          profile_category.polo_id == ^profile.polo_id and
            profile_category.polo_place_profile_id == ^profile.id
      )
    )

    Enum.each(categories, fn category ->
      Writer.insert_once!(:polo_place_profile_category, %{
        polo_id: profile.polo_id,
        polo_place_profile_id: profile.id,
        place_category_id: category.id,
        inserted_at: @seeded_at
      })
    end)
  end

  defp replace_opening_periods!(profile, periods) do
    Repo.delete_all(
      from(period in PoloPlaceOpeningPeriod,
        where:
          period.polo_id == ^profile.polo_id and
            period.polo_place_profile_id == ^profile.id
      )
    )

    Enum.each(periods, fn period ->
      Writer.insert_once!(
        :polo_place_opening_period,
        Map.merge(period, %{
          polo_id: profile.polo_id,
          polo_place_profile_id: profile.id,
          inserted_at: @seeded_at,
          updated_at: @seeded_at
        })
      )
    end)
  end

  defp franchise_sobral_periods do
    [
      weekly(:period_franchise_sobral_mon, 1, ~T[07:30:00], ~T[19:00:00]),
      weekly(:period_franchise_sobral_tue, 2, ~T[07:30:00], ~T[19:00:00]),
      weekly(:period_franchise_sobral_wed, 3, ~T[07:30:00], ~T[19:00:00]),
      weekly(:period_franchise_sobral_thu, 4, ~T[07:30:00], ~T[19:00:00]),
      weekly(:period_franchise_sobral_fri, 5, ~T[07:30:00], ~T[19:00:00]),
      weekly(:period_franchise_sobral_sat, 6, ~T[08:00:00], ~T[18:00:00]),
      weekly(:period_franchise_sobral_sun, 7, ~T[08:00:00], ~T[13:00:00]),
      closed(:period_franchise_sobral_christmas, ~D[2026-12-25]),
      exception(
        :period_franchise_sobral_new_year,
        ~D[2026-12-31],
        ~T[07:30:00],
        ~T[16:00:00]
      )
    ]
  end

  defp local_sobral_periods do
    [
      weekly(:period_local_sobral_tue_lunch, 2, ~T[11:30:00], ~T[15:00:00]),
      weekly(:period_local_sobral_tue_dinner, 2, ~T[18:00:00], ~T[23:00:00]),
      weekly(:period_local_sobral_wed_lunch, 3, ~T[11:30:00], ~T[15:00:00]),
      weekly(:period_local_sobral_wed_dinner, 3, ~T[18:00:00], ~T[23:00:00]),
      weekly(:period_local_sobral_thu_lunch, 4, ~T[11:30:00], ~T[15:00:00]),
      weekly(:period_local_sobral_thu_dinner, 4, ~T[18:00:00], ~T[23:00:00]),
      weekly(:period_local_sobral_fri_lunch, 5, ~T[11:30:00], ~T[15:00:00]),
      weekly(:period_local_sobral_fri_dinner, 5, ~T[18:00:00], ~T[23:00:00]),
      weekly(:period_local_sobral_sat_lunch, 6, ~T[11:30:00], ~T[15:00:00]),
      weekly(:period_local_sobral_sat_dinner, 6, ~T[18:00:00], ~T[23:00:00]),
      weekly(:period_local_sobral_sun_lunch, 7, ~T[11:30:00], ~T[15:00:00]),
      weekly(:period_local_sobral_sun_dinner, 7, ~T[18:00:00], ~T[23:00:00]),
      closed(:period_local_sobral_christmas, ~D[2026-12-25]),
      exception(
        :period_local_sobral_new_year,
        ~D[2026-12-31],
        ~T[11:30:00],
        ~T[16:00:00]
      )
    ]
  end

  defp franchise_londrina_periods do
    [
      weekly(:period_franchise_londrina_mon, 1, ~T[08:00:00], ~T[19:00:00]),
      weekly(:period_franchise_londrina_tue, 2, ~T[08:00:00], ~T[19:00:00]),
      weekly(:period_franchise_londrina_wed, 3, ~T[08:00:00], ~T[19:00:00]),
      weekly(:period_franchise_londrina_thu, 4, ~T[08:00:00], ~T[19:00:00]),
      weekly(:period_franchise_londrina_fri, 5, ~T[08:00:00], ~T[19:00:00]),
      weekly(:period_franchise_londrina_sat, 6, ~T[08:00:00], ~T[18:00:00]),
      weekly(:period_franchise_londrina_sun, 7, ~T[09:00:00], ~T[14:00:00]),
      closed(:period_franchise_londrina_christmas, ~D[2026-12-25]),
      exception(
        :period_franchise_londrina_new_year,
        ~D[2026-12-31],
        ~T[08:00:00],
        ~T[15:00:00]
      )
    ]
  end

  defp weekly(id_name, weekday, opens_at, closes_at) do
    %{
      id: id(id_name),
      kind: "weekly",
      weekday: weekday,
      local_date: nil,
      opens_at: opens_at,
      closes_at: closes_at,
      closes_next_day: false
    }
  end

  defp closed(id_name, local_date) do
    %{
      id: id(id_name),
      kind: "exception_closed",
      weekday: nil,
      local_date: local_date,
      opens_at: nil,
      closes_at: nil,
      closes_next_day: false
    }
  end

  defp exception(id_name, local_date, opens_at, closes_at) do
    %{
      id: id(id_name),
      kind: "exception_open",
      weekday: nil,
      local_date: local_date,
      opens_at: opens_at,
      closes_at: closes_at,
      closes_next_day: false
    }
  end

  defp id(name), do: Ids.fetch!(name)
end
