defmodule ClubeiraWeb.Public.PlaceLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Directory
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.PublicReviewKey

  @review_page_limit "10"
  @slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:reviews, dom_id: &"public-review-#{&1.public_key}")
     |> assign(:page_title, gettext("Place details"))}
  end

  @impl true
  def handle_params(
        %{"polo_slug" => polo_slug, "place_slug" => place_slug} = params,
        _uri,
        socket
      ) do
    with :ok <- validate_slug(place_slug),
         {:ok, %{polo: polo, place: place}} <-
           Directory.get_public_place(polo_slug, place_slug),
         {:ok, result} <-
           Reviews.list_public(
             Scope.new!(polo.id),
             place.place_id,
             review_params(params)
           ) do
      reviews =
        Enum.map(result.reviews, &Map.put(&1, :public_key, PublicReviewKey.from_id(&1.id)))

      {:noreply,
       socket
       |> assign(:page_title, place.name)
       |> assign(:polo, polo)
       |> assign(:place, place)
       |> assign(:reviews_next_page_path, reviews_next_page_path(params, result.page))
       |> stream(:reviews, reviews, reset: true)}
    else
      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The review page was invalid and has been reset."))
         |> redirect(to: ~p"/explorar/#{polo_slug}/lugares/#{place_slug}")}

      {:error, reason} when reason in [:invalid_slug, :place_not_found, :polo_not_found] ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This place is not available."))
         |> redirect(to: ~p"/explorar/#{polo_slug}")}

      {:error, reason} ->
        Logger.error(
          "could not load public place #{inspect(polo_slug)}/#{inspect(place_slug)}",
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("This place is temporarily unavailable."))
         |> redirect(to: ~p"/explorar/#{polo_slug}")}
    end
  end

  def profile_categories(%{profile: nil}), do: []
  def profile_categories(%{profile: profile}), do: Map.get(profile, "categories", [])

  def weekly_hours(%{profile: nil}), do: []
  def weekly_hours(%{profile: profile}), do: Map.get(profile, "weekly_hours", [])

  def profile_contact(%{profile: nil}, _key), do: nil

  def profile_contact(%{profile: profile}, key) do
    profile
    |> Map.get("contact", %{})
    |> Map.get(key)
  end

  def weekday_name(1), do: gettext("Monday")
  def weekday_name(2), do: gettext("Tuesday")
  def weekday_name(3), do: gettext("Wednesday")
  def weekday_name(4), do: gettext("Thursday")
  def weekday_name(5), do: gettext("Friday")
  def weekday_name(6), do: gettext("Saturday")
  def weekday_name(7), do: gettext("Sunday")
  def weekday_name(_weekday), do: gettext("Day")

  defp validate_slug(slug) when is_binary(slug) and byte_size(slug) in 2..80 do
    if Regex.match?(@slug_pattern, slug), do: :ok, else: {:error, :invalid_slug}
  end

  defp validate_slug(_slug), do: {:error, :invalid_slug}

  defp review_params(params) do
    %{
      "after" => params["reviews_after"],
      "limit" => Map.get(params, "limit", @review_page_limit)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp reviews_next_page_path(_params, %{has_more: false}), do: nil

  defp reviews_next_page_path(params, page) do
    query =
      params
      |> Map.take(~w(limit))
      |> Map.put("reviews_after", page.next_cursor)

    ~p"/explorar/#{params["polo_slug"]}/lugares/#{params["place_slug"]}?#{query}"
  end
end
