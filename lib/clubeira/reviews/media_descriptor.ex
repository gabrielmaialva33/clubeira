defmodule Clubeira.Reviews.MediaDescriptor do
  @moduledoc false

  @enforce_keys ~w(kind content_type content_sha256 size_bytes)a
  defstruct @enforce_keys ++ [:width, :height, :duration_ms]

  @type t :: %__MODULE__{
          kind: String.t(),
          content_type: String.t(),
          content_sha256: <<_::256>>,
          size_bytes: pos_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          duration_ms: pos_integer() | nil
        }

  @image_types ~w(image/jpeg image/png image/webp)
  @video_types ~w(video/mp4 video/webm)
  @maximum_image_bytes 15 * 1_024 * 1_024
  @maximum_video_bytes 100 * 1_024 * 1_024

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_media_descriptor}
  def new(descriptor) when is_map(descriptor) do
    content_type = value(descriptor, :content_type)
    kind = kind_for(content_type)

    candidate = %__MODULE__{
      kind: kind,
      content_type: content_type,
      content_sha256: value(descriptor, :content_sha256),
      size_bytes: value(descriptor, :size_bytes),
      width: value(descriptor, :width),
      height: value(descriptor, :height),
      duration_ms: value(descriptor, :duration_ms)
    }

    if valid?(candidate), do: {:ok, candidate}, else: {:error, :invalid_media_descriptor}
  end

  def new(_descriptor), do: {:error, :invalid_media_descriptor}

  defp valid?(%__MODULE__{kind: "image"} = descriptor) do
    valid_hash?(descriptor.content_sha256) and
      is_integer(descriptor.size_bytes) and descriptor.size_bytes in 1..@maximum_image_bytes and
      positive?(descriptor.width) and positive?(descriptor.height) and
      is_nil(descriptor.duration_ms)
  end

  defp valid?(%__MODULE__{kind: "video"} = descriptor) do
    valid_hash?(descriptor.content_sha256) and
      is_integer(descriptor.size_bytes) and descriptor.size_bytes in 1..@maximum_video_bytes and
      optional_positive?(descriptor.width) and optional_positive?(descriptor.height) and
      positive?(descriptor.duration_ms)
  end

  defp valid?(_descriptor), do: false

  defp kind_for(content_type) when content_type in @image_types, do: "image"
  defp kind_for(content_type) when content_type in @video_types, do: "video"
  defp kind_for(_content_type), do: nil

  defp valid_hash?(hash), do: is_binary(hash) and byte_size(hash) == 32
  defp positive?(value), do: is_integer(value) and value > 0
  defp optional_positive?(nil), do: true
  defp optional_positive?(value), do: positive?(value)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
