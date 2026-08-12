defmodule ClubeiraWeb.Public.PolosLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Polos

  @page_limit "20"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:polos, dom_id: &"public-polo-#{&1.slug}")
     |> assign(:page_title, gettext("Explore Clubeira"))
     |> assign(:load_error?, false)
     |> assign(:next_page_path, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case public_polos_reader().list_public(pagination_params(params)) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:load_error?, false)
         |> assign(:next_page_path, next_page_path(params, result.page))
         |> stream(:polos, result.polos, reset: true)}

      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The polo page was invalid and has been reset."))
         |> redirect(to: ~p"/explorar")}

      {:error, reason} ->
        Logger.error("could not load public polos", reason: inspect(reason))

        {:noreply,
         socket
         |> assign(:load_error?, true)
         |> assign(:next_page_path, nil)
         |> stream(:polos, [], reset: true)}
    end
  end

  defp pagination_params(params) do
    params
    |> Map.take(~w(after limit))
    |> Map.put_new("limit", @page_limit)
  end

  defp next_page_path(_params, %{has_more: false}), do: nil

  defp next_page_path(params, page) do
    query = [after: page.next_cursor, limit: Map.get(params, "limit", @page_limit)]
    ~p"/explorar?#{query}"
  end

  defp public_polos_reader do
    :clubeira
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:reader, Polos)
  end
end
