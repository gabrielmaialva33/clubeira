defmodule Clubeira.Catalog.BenefitOfferPublishRequestTest do
  use ExUnit.Case, async: true

  alias Clubeira.Catalog
  alias Clubeira.Catalog.BenefitOfferPublishRequest

  test "the form boundary exposes a changeset and rejects non-map payloads" do
    changeset =
      Catalog.change_benefit_offer_publish_request(%{
        "code" => "almoco-executivo",
        "name" => "Almoço executivo"
      })

    assert Ecto.Changeset.get_field(changeset, :code) == "almoco-executivo"
    assert Ecto.Changeset.get_field(changeset, :name) == "Almoço executivo"

    Enum.each([:invalid, %BenefitOfferPublishRequest{}], fn attributes ->
      invalid = Catalog.change_benefit_offer_publish_request(attributes)

      refute invalid.valid?
      assert {:base, {"must be a map", []}} in invalid.errors
    end)
  end
end
