defmodule ClubeiraWeb.Public.PolosLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.RedemptionsFixtures
  alias ClubeiraWeb.Public.PolosLive

  setup do
    previous_reader = Application.get_env(:clubeira, PolosLive)

    on_exit(fn -> restore_reader(previous_reader) end)

    :ok
  end

  test "lists only active polos through public slugs without exposing tenant UUIDs", %{conn: conn} do
    active = RedemptionsFixtures.create!()
    draft = RedemptionsFixtures.create!()

    RedemptionsFixtures.scoped_query!(
      draft,
      "UPDATE polos SET status = 'draft' WHERE id = $1",
      [draft.ids.polo]
    )

    {:ok, view, html} = live(conn, "/explorar")

    assert has_element?(view, "#public-polos")
    assert has_element?(view, "#public-polo-#{active.polo_slug}")
    refute has_element?(view, "#public-polo-#{draft.polo_slug}")

    assert has_element?(
             view,
             "#public-polo-#{active.polo_slug} a[href='/explorar/#{active.polo_slug}']"
           )

    refute html =~ active.ids.polo
    refute html =~ draft.ids.polo
  end

  test "replaces the current keyset page when the visitor asks for more polos", %{conn: conn} do
    fixtures = [RedemptionsFixtures.create!(), RedemptionsFixtures.create!()]
    [first, second] = Enum.sort_by(fixtures, & &1.polo_slug)

    {:ok, view, _html} = live(conn, "/explorar?limit=1")

    assert has_element?(view, "#public-polo-#{first.polo_slug}")
    refute has_element?(view, "#public-polo-#{second.polo_slug}")

    view
    |> element("#public-polos-next-page")
    |> render_click()

    refute has_element?(view, "#public-polo-#{first.polo_slug}")
    assert has_element?(view, "#public-polo-#{second.polo_slug}")
  end

  test "keeps an unavailable public directory on a recoverable local error state", %{conn: conn} do
    Application.put_env(:clubeira, PolosLive, reader: Clubeira.UnavailablePublicPolosReader)

    {:ok, view, _html} = live(conn, "/explorar")

    assert has_element?(view, "#public-polos-load-error")
    assert has_element?(view, "#public-polos-retry[href='/explorar']")
    refute has_element?(view, "#public-polos-stream")
  end

  test "canonicalizes an invalid public-directory cursor", %{conn: conn} do
    _fixture = RedemptionsFixtures.create!()

    assert {:error, {:redirect, %{to: "/explorar"}}} =
             live(conn, "/explorar?after=malformed")
  end

  defp restore_reader(nil), do: Application.delete_env(:clubeira, PolosLive)
  defp restore_reader(reader), do: Application.put_env(:clubeira, PolosLive, reader)
end
