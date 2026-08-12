defmodule Clubeira.Reviews.MediaDescriptorTest do
  use ExUnit.Case, async: true

  alias Clubeira.Reviews.MediaDescriptor

  @hash :crypto.hash(:sha256, "review-media")

  test "accepts image descriptors with atom or external string keys" do
    assert {:ok, image} =
             MediaDescriptor.new(%{
               kind: "ignored",
               content_type: "image/webp",
               content_sha256: @hash,
               size_bytes: 15 * 1_024 * 1_024,
               width: 1_200,
               height: 800
             })

    assert image.kind == "image"
    assert image.duration_ms == nil

    assert {:ok, image} =
             MediaDescriptor.new(%{
               "content_type" => "image/jpeg",
               "content_sha256" => @hash,
               "size_bytes" => 1,
               "width" => 1,
               "height" => 1
             })

    assert image.kind == "image"
  end

  test "accepts bounded videos with optional dimensions" do
    assert {:ok, video} =
             MediaDescriptor.new(%{
               content_type: "video/mp4",
               content_sha256: @hash,
               size_bytes: 100 * 1_024 * 1_024,
               duration_ms: 1
             })

    assert video.kind == "video"
    assert video.width == nil
    assert video.height == nil

    assert {:ok, _video} =
             MediaDescriptor.new(%{
               content_type: "video/webm",
               content_sha256: @hash,
               size_bytes: 1,
               width: 1_920,
               height: 1_080,
               duration_ms: 3_000
             })
  end

  test "rejects malformed, oversized or semantically inconsistent descriptors" do
    valid_image = %{
      content_type: "image/png",
      content_sha256: @hash,
      size_bytes: 1,
      width: 1,
      height: 1
    }

    invalids = [
      nil,
      %{},
      %{valid_image | content_type: "image/gif"},
      %{valid_image | content_sha256: <<1>>},
      %{valid_image | size_bytes: 0},
      %{valid_image | size_bytes: 15 * 1_024 * 1_024 + 1},
      %{valid_image | width: nil},
      %{valid_image | height: -1},
      Map.put(valid_image, :duration_ms, 1),
      %{
        content_type: "video/mp4",
        content_sha256: @hash,
        size_bytes: 100 * 1_024 * 1_024 + 1,
        duration_ms: 1
      },
      %{
        content_type: "video/mp4",
        content_sha256: @hash,
        size_bytes: 1,
        width: 0,
        duration_ms: 0
      }
    ]

    for invalid <- invalids do
      assert {:error, :invalid_media_descriptor} = MediaDescriptor.new(invalid)
    end
  end
end
