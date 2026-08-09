defmodule Clubeira.Reviews.MediaVerifiers.HttpTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Clubeira.Reviews.MediaVerifiers.Http

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:clubeira, Http)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:clubeira, Http, previous),
        else: Application.delete_env(:clubeira, Http)
    end)

    Application.put_env(:clubeira, Http,
      verification_url: "https://storage.example.test/v1/objects/verify",
      public_base_url: "https://cdn.example.test/",
      bearer_token: "storage-control-token",
      req_options: [plug: {Req.Test, Http}]
    )

    :ok
  end

  test "verifies immutable metadata through the trusted control endpoint" do
    digest = :crypto.hash(:sha256, "immutable review image")

    Req.Test.expect(Http, fn request ->
      request = fetch_query_params(request)

      assert request.method == "GET"
      assert request.request_path == "/v1/objects/verify"
      assert request.query_params == %{"key" => "reviews/member 1/photo.webp"}
      assert get_req_header(request, "authorization") == ["Bearer storage-control-token"]

      Req.Test.json(request, %{
        "immutable" => true,
        "content_type" => "image/webp",
        "sha256" => Base.url_encode64(digest, padding: false),
        "size_bytes" => 42_000,
        "width" => 1280,
        "height" => 720,
        "duration_ms" => nil
      })
    end)

    assert {:ok,
            %{
              content_type: "image/webp",
              content_sha256: ^digest,
              size_bytes: 42_000,
              width: 1280,
              height: 720,
              duration_ms: nil
            }} = Http.verify("reviews/member 1/photo.webp")

    assert {:ok, "https://cdn.example.test/reviews/member%201/photo.webp"} =
             Http.public_url("/reviews/member 1/photo.webp")
  end

  test "fails closed for unavailable storage, mutable objects and malformed digests" do
    Req.Test.expect(Http, fn request ->
      Req.Test.json(request, %{"immutable" => false})
    end)

    assert {:error, :media_not_verified} = Http.verify("reviews/mutable.webp")

    Req.Test.expect(Http, fn request ->
      Req.Test.json(request, %{"immutable" => true, "sha256" => "not-a-digest"})
    end)

    assert {:error, :media_not_verified} = Http.verify("reviews/malformed.webp")
    assert {:error, :media_not_verified} = Http.verify(nil)
    assert {:error, :media_not_found} = Http.public_url(nil)

    Application.put_env(:clubeira, Http, verification_url: "not-a-url")

    assert {:error, :media_storage_unavailable} = Http.verify("reviews/unavailable.webp")
    assert {:error, :media_storage_unavailable} = Http.public_url("reviews/unavailable.webp")
  end

  test "normalizes transport failures without exposing storage configuration" do
    Application.put_env(:clubeira, Http,
      verification_url: "http://storage.example.test/v1/objects/verify",
      public_base_url: "http://cdn.example.test",
      req_options: [plug: {Req.Test, Http}, retry: false]
    )

    Req.Test.expect(Http, fn request ->
      assert get_req_header(request, "authorization") == []
      Req.Test.transport_error(request, :timeout)
    end)

    assert {:error, :media_not_verified} = Http.verify("reviews/timeout.webp")
  end
end
