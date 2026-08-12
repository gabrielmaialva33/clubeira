defmodule ClubeiraWeb.Public.PlaceLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Directory
  alias Clubeira.Factory
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures

  test "shows a public place and only its published review without exposing UUIDs", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    place_slug = "place-#{short_suffix(fixture.ids.polo)}"

    assert {:ok, published} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-public-place-live-#{uuid7()}"
             })

    {:ok, view, html} = live(conn, "/explorar/#{fixture.polo_slug}/lugares/#{place_slug}")
    assert has_element?(view, "#public-place-detail")
    assert has_element?(view, "#public-place-reviews article[data-rating='5']")

    assert has_element?(
             view,
             "#public-place-reviews article",
             "O benefício foi entregue como anunciado."
           )

    assert has_element?(view, "#public-place-legal-link[href='/termos']")

    assert has_element?(
             view,
             "[id^='public-report-review-'][href='/app/login']"
           )

    refute html =~ fixture.ids.polo
    refute html =~ fixture.ids.place
    refute html =~ published.review.id
  end

  test "does not resolve a place slug through another polo", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    other = ReviewsFixtures.pending_review!()
    other_place_slug = "place-#{short_suffix(other.ids.polo)}"

    assert {:error, {:redirect, %{to: path}}} =
             live(conn, "/explorar/#{fixture.polo_slug}/lugares/#{other_place_slug}")

    assert path == "/explorar/#{fixture.polo_slug}"
  end

  test "renders the published profile contact, category, and overnight opening hours", %{
    conn: conn
  } do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    category = Factory.insert(:place_category, key: "cafe", name: "Café")
    place_slug = "place-#{short_suffix(fixture.ids.polo)}"

    assert {:ok, _profile} =
             Directory.publish_place_profile(admin_scope, fixture.ids.place, %{
               contact: %{email: "publico@cafe.example", phone: "+5588999990110"},
               category_keys: [category.key],
               weekly_hours: [%{weekday: 1, opens_at: "22:00", closes_at: "02:00"}],
               special_hours: [],
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 0,
               idempotency_key: "public-place-profile-#{uuid7()}"
             })

    {:ok, view, _html} =
      live(conn, "/explorar/#{fixture.polo_slug}/lugares/#{place_slug}")

    assert has_element?(view, "#public-place-detail", "Café")

    assert has_element?(
             view,
             "a[href='mailto:publico@cafe.example']",
             "publico@cafe.example"
           )

    assert has_element?(view, "a[href='tel:+5588999990110']", "+5588999990110")
    assert has_element?(view, "#public-place-hours", "Segunda-feira")
    assert has_element?(view, "#public-place-hours", "22:00")
    assert has_element?(view, "#public-place-hours", "02:00")
    assert has_element?(view, "#public-place-hours", "+1")
  end

  test "canonicalizes an invalid review cursor without exposing it", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    place_slug = "place-#{short_suffix(fixture.ids.polo)}"
    canonical = "/explorar/#{fixture.polo_slug}/lugares/#{place_slug}"

    assert {:error, {:redirect, %{to: ^canonical}}} =
             live(conn, "#{canonical}?reviews_after=malformed")
  end

  defp short_suffix(uuid), do: uuid |> String.replace("-", "") |> String.slice(-12, 12)
  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
