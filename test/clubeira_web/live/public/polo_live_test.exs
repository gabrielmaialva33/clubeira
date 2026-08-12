defmodule ClubeiraWeb.Public.PoloLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.RedemptionsFixtures

  test "shows one active polo catalog and directory through public identifiers", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other = RedemptionsFixtures.create!()
    offer_code = "offer-#{short_suffix(fixture.ids.polo)}"
    place_slug = "place-#{short_suffix(fixture.ids.polo)}"

    {:ok, view, html} = live(conn, "/explorar/#{fixture.polo_slug}")

    assert has_element?(view, "#public-polo")
    assert has_element?(view, "#public-offer-#{offer_code}")
    assert has_element?(view, "#public-offer-#{offer_code} details", "Uso único")
    assert has_element?(view, "#public-place-#{place_slug}")

    assert has_element?(
             view,
             "#public-place-#{place_slug} a[href='/explorar/#{fixture.polo_slug}/lugares/#{place_slug}']"
           )

    refute html =~ fixture.ids.polo
    refute html =~ fixture.ids.place
    refute html =~ fixture.ids.benefit_offer
    refute html =~ other.ids.polo
    refute html =~ other.ids.place
  end

  test "keeps the selected URL filter while replacing the current keyset page", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        additional_offer: true,
        alternate_validation_place: true
      )

    suffix = short_suffix(fixture.ids.polo)
    first_offer_code = "offer-#{suffix}"
    second_offer_code = "other-offer-#{suffix}"

    {:ok, view, _html} =
      live(conn, "/explorar/#{fixture.polo_slug}?section=benefits&limit=1")

    assert has_element?(view, "#public-polo-filter-benefits[aria-current='page']")
    assert has_element?(view, "#public-offer-#{first_offer_code}")
    refute has_element?(view, "#public-offer-#{second_offer_code}")
    refute has_element?(view, "#public-places")

    view
    |> element("#public-benefits-next-page")
    |> render_click()

    refute has_element?(view, "#public-offer-#{first_offer_code}")
    assert has_element?(view, "#public-offer-#{second_offer_code}")
    assert has_element?(view, "#public-polo-filter-benefits[aria-current='page']")
  end

  test "canonicalizes invalid filters and both independent cursors", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    canonical = "/explorar/#{fixture.polo_slug}"

    for query <- [
          "section=unknown",
          "benefits_after=malformed",
          "places_after=malformed"
        ] do
      assert {:error, {:redirect, %{to: ^canonical}}} = live(conn, "#{canonical}?#{query}")
    end
  end

  test "renders a percentage discount through the public catalog", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        benefit_kind: "discount_percentage",
        percentage_value: Decimal.new("12.5")
      )

    offer_code = "offer-#{short_suffix(fixture.ids.polo)}"
    {:ok, view, _html} = live(conn, "/explorar/#{fixture.polo_slug}?section=benefits")

    assert has_element?(view, "#public-offer-#{offer_code}", "de desconto")
  end

  defp short_suffix(uuid), do: uuid |> String.replace("-", "") |> String.slice(-12, 12)
end
