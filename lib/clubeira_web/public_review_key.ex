defmodule ClubeiraWeb.PublicReviewKey do
  @moduledoc false

  alias ClubeiraWeb.Endpoint

  @salt "public review v1"

  @spec from_id(Ecto.UUID.t()) :: String.t()
  def from_id(id) when is_binary(id) do
    :sha256
    |> :crypto.hash(id)
    |> Base.url_encode64(padding: false)
  end

  @spec sign(Ecto.UUID.t()) :: String.t()
  def sign(id) when is_binary(id) do
    Phoenix.Token.sign(Endpoint, @salt, Ecto.UUID.dump!(id))
  end

  @spec resolve(term()) :: {:ok, Ecto.UUID.t()} | {:error, :invalid_review_key}
  def resolve(key) when is_binary(key) do
    with {:ok, binary_id} <- Phoenix.Token.verify(Endpoint, @salt, key, max_age: :infinity),
         {:ok, review_id} <- Ecto.UUID.load(binary_id) do
      {:ok, review_id}
    else
      _invalid -> {:error, :invalid_review_key}
    end
  end

  def resolve(_key), do: {:error, :invalid_review_key}
end
