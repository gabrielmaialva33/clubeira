defmodule Clubeira.Directory.PublicPlaceReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Directory
  alias Clubeira.RedemptionsFixtures

  test "gets one exact active place through its public route" do
    fixture = RedemptionsFixtures.create!()
    place_slug = "place-#{short_suffix(fixture.ids.polo)}"

    assert {:ok, %{polo: polo, place: place}} =
             Directory.get_public_place(fixture.polo_slug, place_slug)

    assert polo.slug == fixture.polo_slug
    assert place.slug == place_slug
    assert place.place_id == fixture.ids.place
    assert place.polo_place_id == fixture.ids.polo_place
  end

  test "returns not found for an unknown place slug in an active polo" do
    fixture = RedemptionsFixtures.create!()

    assert {:error, :place_not_found} =
             Directory.get_public_place(fixture.polo_slug, "unknown-place")
  end

  test "does not resolve a place through another polo route" do
    fixture = RedemptionsFixtures.create!()
    other = RedemptionsFixtures.create!()
    other_place_slug = "place-#{short_suffix(other.ids.polo)}"

    assert {:error, :place_not_found} =
             Directory.get_public_place(fixture.polo_slug, other_place_slug)
  end

  defp short_suffix(uuid), do: uuid |> String.replace("-", "") |> String.slice(-12, 12)
end
