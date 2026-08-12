defmodule ClubeiraWeb.PublicReviewKeyTest do
  use ExUnit.Case, async: true

  alias ClubeiraWeb.PublicReviewKey

  test "keeps DOM keys stable and resolves only authenticated query tokens" do
    review_id = Ecto.UUID.generate(version: 7)
    dom_key = PublicReviewKey.from_id(review_id)
    token = PublicReviewKey.sign(review_id)

    assert PublicReviewKey.from_id(review_id) == dom_key
    assert {:ok, ^review_id} = PublicReviewKey.resolve(token)
    assert {:error, :invalid_review_key} = PublicReviewKey.resolve(dom_key)
    assert {:error, :invalid_review_key} = PublicReviewKey.resolve(tamper(token))
    assert {:error, :invalid_review_key} = PublicReviewKey.resolve(nil)

    refute dom_key =~ review_id
    refute token =~ review_id
  end

  defp tamper(token), do: String.replace_suffix(token, String.last(token), "!")
end
