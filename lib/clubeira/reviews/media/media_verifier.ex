defmodule Clubeira.Reviews.MediaVerifier do
  @moduledoc """
  Verifies immutable review-media metadata and resolves its delivery URL.

  Implementations must derive the descriptor from trusted storage metadata;
  client-supplied hashes, dimensions and content types are not authoritative.
  """

  @type raw_descriptor :: map()

  @callback verify(storage_key :: String.t()) ::
              {:ok, raw_descriptor()} | {:error, atom()}

  @callback public_url(storage_key :: String.t()) ::
              {:ok, String.t()} | {:error, atom()}
end
