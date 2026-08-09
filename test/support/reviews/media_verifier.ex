defmodule Clubeira.TestReviewMediaVerifier do
  @moduledoc false

  @behaviour Clubeira.Reviews.MediaVerifier

  @impl true
  def verify("reviews/verified/photo.webp") do
    {:ok,
     %{
       kind: "image",
       content_type: "image/webp",
       content_sha256: :crypto.hash(:sha256, "verified review image"),
       size_bytes: 24_000,
       width: 1_280,
       height: 720,
       duration_ms: nil
     }}
  end

  def verify("reviews/verified/second.webp") do
    {:ok,
     %{
       kind: "image",
       content_type: "image/webp",
       content_sha256: :crypto.hash(:sha256, "second verified review image"),
       size_bytes: 12_000,
       width: 640,
       height: 360,
       duration_ms: nil
     }}
  end

  def verify(_storage_key), do: {:error, :media_not_verified}

  @impl true
  def public_url("reviews/verified/photo.webp") do
    {:ok, "https://cdn.example.test/reviews/verified/photo.webp"}
  end

  def public_url(_storage_key), do: {:error, :media_not_found}
end
