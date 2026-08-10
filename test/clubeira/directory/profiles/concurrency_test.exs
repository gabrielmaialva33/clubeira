defmodule Clubeira.Directory.PlaceProfileConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Directory
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.ReviewsFixtures

  test "concurrent retries publish one place profile and replay the committed response", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    category = Factory.insert(:place_category)

    request =
      profile_request(category.key, "profile-concurrent-retry", %{
        email: "retry@parceiro.example",
        phone: "+5588999990101",
        weekday: 2
      })

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Directory.publish_place_profile(scope, fixture.ids.place, request) end,
               fn -> Directory.publish_place_profile(scope, fixture.ids.place, request) end
             ])

    assert first == second
    assert get_in(first, ["profile", "revision"]) == 1

    assert profile_counts(fixture) == %{
             audits: 1,
             categories: 1,
             domain_events: 1,
             idempotency_keys: 1,
             outbox_messages: 1,
             periods: 1,
             profiles: 1
           }
  end

  test "concurrent profile replacements serialize complete revisions without lost updates", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    morning = Factory.insert(:place_category)
    evening = Factory.insert(:place_category)

    first_request =
      profile_request(morning.key, "profile-concurrent-first", %{
        email: "manha@parceiro.example",
        phone: "+5588999990102",
        weekday: 3
      })

    second_request =
      profile_request(evening.key, "profile-concurrent-second", %{
        email: "noite@parceiro.example",
        phone: "+5588999990103",
        weekday: 4
      })

    assert [{:ok, _first}, {:ok, _second}] =
             results =
             run_concurrently(repo, [
               fn ->
                 Directory.publish_place_profile(scope, fixture.ids.place, first_request)
               end,
               fn ->
                 Directory.publish_place_profile(scope, fixture.ids.place, second_request)
               end
             ])

    assert results
           |> Enum.map(fn {:ok, result} -> get_in(result, ["profile", "revision"]) end)
           |> Enum.sort() == [1, 2]

    {:ok, directory} = Directory.fetch_public(fixture.polo_slug)
    public_place = Enum.find(directory.places, &(&1.place_id == fixture.ids.place))

    revision_two =
      Enum.find_value(results, fn
        {:ok, %{"profile" => %{"revision" => 2} = profile}} -> profile
        _other -> nil
      end)

    assert public_place.profile == revision_two

    assert profile_counts(fixture) == %{
             audits: 2,
             categories: 1,
             domain_events: 2,
             idempotency_keys: 2,
             outbox_messages: 2,
             periods: 1,
             profiles: 1
           }
  end

  defp profile_request(category_key, idempotency_key, attributes) do
    %{
      contact: %{email: attributes.email, phone: attributes.phone},
      category_keys: [category_key],
      weekly_hours: [
        %{weekday: attributes.weekday, opens_at: "09:00", closes_at: "18:00"}
      ],
      special_hours: [],
      idempotency_key: idempotency_key
    }
  end

  defp profile_counts(fixture) do
    %{rows: [[profiles, categories, periods, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM polo_place_profiles),
        (SELECT count(*) FROM polo_place_profile_categories),
        (SELECT count(*) FROM polo_place_opening_periods),
        (SELECT count(*) FROM tenant_audit_events
           WHERE resource_type = 'polo_place_profile'),
        (SELECT count(*) FROM domain_events
           WHERE aggregate_type = 'polo_place_profile'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic IN ('places.profiles.published', 'places.profiles.updated')),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'directory.publish_place_profile')
      """)

    %{
      profiles: profiles,
      categories: categories,
      periods: periods,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end
end
