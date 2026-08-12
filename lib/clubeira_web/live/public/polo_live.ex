defmodule ClubeiraWeb.Public.PoloLive do
  use ClubeiraWeb, :live_view

  alias Clubeira.Catalog
  alias Clubeira.Directory

  @page_limit "12"
  @sections ~w(all benefits places)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:offers, dom_id: &"public-offer-#{&1.code}")
     |> stream_configure(:places, dom_id: &"public-place-#{&1.slug}")
     |> assign(:page_title, gettext("Explore Clubeira"))}
  end

  @impl true
  def handle_params(%{"polo_slug" => polo_slug} = params, _uri, socket) do
    with {:ok, section} <- parse_section(params["section"]),
         {:ok, catalog} <- Catalog.fetch_public(polo_slug, catalog_params(params)),
         {:ok, directory} <- Directory.fetch_public(polo_slug, directory_params(params)) do
      {:noreply,
       socket
       |> assign(:page_title, catalog.polo.name)
       |> assign(:polo, catalog.polo)
       |> assign(:section, section)
       |> assign(:benefits_next_page_path, benefits_next_page_path(params, catalog.page))
       |> assign(:places_next_page_path, places_next_page_path(params, directory.page))
       |> stream(:offers, catalog.offers, reset: true)
       |> stream(:places, directory.places, reset: true)}
    else
      {:error, :invalid_filter} ->
        reset_invalid_page(socket, polo_slug)

      {:error, :invalid_pagination} ->
        reset_invalid_page(socket, polo_slug)

      {:error, :polo_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This polo is not available."))
         |> redirect(to: ~p"/explorar")}
    end
  end

  def benefit_value(%{benefit_kind: "discount_percentage", percentage_value: value})
      when not is_nil(value),
      do: gettext("%{value}% discount", value: Decimal.to_string(value, :normal))

  def benefit_value(%{benefit_kind: "discount_amount", amount_value: value, currency: currency})
      when not is_nil(value) and is_binary(currency),
      do:
        gettext("%{currency} %{value} discount",
          currency: currency,
          value: Decimal.to_string(value, :normal)
        )

  def benefit_value(%{benefit_kind: "complimentary_item"}), do: gettext("Complimentary item")
  def benefit_value(%{benefit_kind: "bundle"}), do: gettext("Bundle benefit")
  def benefit_value(_offer), do: gettext("Exclusive benefit")

  defp reset_invalid_page(socket, polo_slug) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The selected page or filter was invalid and has been reset."))
     |> redirect(to: ~p"/explorar/#{polo_slug}")}
  end

  defp parse_section(nil), do: {:ok, "all"}
  defp parse_section(section) when section in @sections, do: {:ok, section}
  defp parse_section(_section), do: {:error, :invalid_filter}

  defp catalog_params(params) do
    %{
      "after" => params["benefits_after"],
      "limit" => Map.get(params, "limit", @page_limit)
    }
    |> compact()
  end

  defp directory_params(params) do
    %{
      "after" => params["places_after"],
      "limit" => Map.get(params, "limit", @page_limit)
    }
    |> compact()
  end

  defp benefits_next_page_path(_params, %{has_more: false}), do: nil

  defp benefits_next_page_path(params, page) do
    query =
      params
      |> Map.take(~w(section places_after limit))
      |> Map.put("benefits_after", page.next_cursor)

    ~p"/explorar/#{params["polo_slug"]}?#{query}"
  end

  defp places_next_page_path(_params, %{has_more: false}), do: nil

  defp places_next_page_path(params, page) do
    query =
      params
      |> Map.take(~w(section benefits_after limit))
      |> Map.put("places_after", page.next_cursor)

    ~p"/explorar/#{params["polo_slug"]}?#{query}"
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
