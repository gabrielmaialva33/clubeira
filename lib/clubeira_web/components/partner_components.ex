defmodule ClubeiraWeb.PartnerComponents do
  @moduledoc "Reusable visual primitives for the assigned-partner portal."

  use ClubeiraWeb, :html

  attr :account_scope, :map, required: true
  attr :access, :map, required: true
  attr :current_polo, :map, required: true
  attr :polo_form, Phoenix.HTML.Form, required: true
  attr :flash, :map, required: true
  attr :active_section, :atom, values: [:places, :reviews], default: :places

  slot :inner_block, required: true

  def shell(assigns) do
    assigns =
      assigns
      |> assign(:initials, initials(assigns.account_scope.user.email))
      |> assign(:places_path, portal_path(assigns.current_polo.slug))
      |> assign(:reviews_path, reviews_path(assigns.current_polo.slug))

    ~H"""
    <div id="partner-shell" class="clubeira-canvas min-h-screen text-clubeira-ink">
      <aside class="fixed inset-y-0 left-0 hidden w-[252px] overflow-hidden border-r border-clubeira-line bg-white lg:flex lg:flex-col">
        <div class="flex h-[68px] items-center border-b border-clubeira-line px-5">
          <.link navigate={@places_path} class="flex items-center gap-3" aria-label="Clubeira">
            <span class="clubeira-brand-mark">
              <img src={~p"/images/logo.svg"} class="h-5 w-7" alt="" />
            </span>
            <div>
              <p class="text-[17px] font-black tracking-[-0.04em]">Clubeira</p>
              <p class="text-[9px] font-bold uppercase tracking-[0.22em] text-clubeira-orange">
                {gettext("Partner portal")}
              </p>
            </div>
          </.link>
        </div>

        <nav id="partner-navigation" class="flex-1 px-3 py-5">
          <p class="px-3 text-[10px] font-bold uppercase tracking-[0.18em] text-clubeira-muted">
            {gettext("Your operation")}
          </p>
          <div class="mt-2 space-y-0.5">
            <.nav_item
              id="partner-nav-places"
              navigate={@places_path}
              icon="hero-building-storefront"
              label={gettext("Places")}
              active={@active_section == :places}
            />
            <.nav_item
              id="partner-nav-reviews"
              navigate={@reviews_path}
              icon="hero-chat-bubble-left-right"
              label={gettext("Reviews")}
              active={@active_section == :reviews}
            />
          </div>
        </nav>

        <div class="border-t border-clubeira-line p-3">
          <div class="rounded-xl bg-clubeira-canvas p-3">
            <div class="flex items-center gap-3">
              <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-clubeira-orange text-[11px] font-black text-white">
                {@initials}
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate text-xs font-bold text-clubeira-ink">
                  {gettext("Partner manager")}
                </p>
                <p id="partner-user-email" class="truncate text-[10px] text-clubeira-muted">
                  {@account_scope.user.email}
                </p>
              </div>
              <.link
                id="partner-logout"
                href="/partner/logout"
                method="delete"
                class="grid size-8 place-items-center rounded-lg text-clubeira-muted transition hover:bg-clubeira-orange-soft hover:text-clubeira-orange"
                aria-label={gettext("Sign out")}
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
              </.link>
            </div>
          </div>
        </div>
      </aside>

      <div class="min-h-screen lg:pl-[252px]">
        <header class="sticky top-0 z-20 h-[68px] border-b border-clubeira-line bg-white/95 backdrop-blur">
          <div class="flex h-full items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
            <div class="flex min-w-0 items-center gap-3">
              <span class="clubeira-brand-mark lg:hidden">
                <img src={~p"/images/logo.svg"} class="h-5 w-7" alt="" />
              </span>
              <div class="min-w-0">
                <p class="text-[10px] font-bold uppercase tracking-[0.16em] text-clubeira-muted">
                  {gettext("Current operation")}
                </p>
                <p class="truncate text-sm font-bold text-clubeira-ink">{@current_polo.name}</p>
              </div>
            </div>

            <.form for={@polo_form} id="partner-polo-form" phx-change="change_polo">
              <label for={@polo_form[:polo].id} class="sr-only">{gettext("Select polo")}</label>
              <select
                id={@polo_form[:polo].id}
                name={@polo_form[:polo].name}
                class="clubeira-control max-w-56 px-3 text-sm font-bold"
              >
                <option
                  :for={polo <- @access.polos}
                  value={polo.slug}
                  selected={polo.slug == @current_polo.slug}
                >
                  {polo.name}
                </option>
              </select>
            </.form>
          </div>
        </header>

        <nav
          id="partner-mobile-navigation"
          class="flex gap-1 border-b border-clubeira-line bg-white px-4 py-2 lg:hidden"
        >
          <.mobile_nav_item
            id="partner-mobile-nav-places"
            navigate={@places_path}
            label={gettext("Places")}
            active={@active_section == :places}
          />
          <.mobile_nav_item
            id="partner-mobile-nav-reviews"
            navigate={@reviews_path}
            label={gettext("Reviews")}
            active={@active_section == :reviews}
          />
        </nav>

        <main class="mx-auto max-w-[1540px] px-4 py-6 sm:px-6 lg:px-8 lg:py-7">
          <div class="min-w-0">{render_slot(@inner_block)}</div>
        </main>
      </div>

      <Layouts.flash_group id="partner-flash-group" flash={@flash} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "clubeira-nav-link group",
        @active && "clubeira-nav-link-active",
        !@active && "text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
      ]}
    >
      <span class={[
        "grid size-7 place-items-center rounded-lg",
        @active && "bg-white text-clubeira-blue",
        !@active && "text-clubeira-muted group-hover:text-clubeira-orange"
      ]}>
        <.icon name={@icon} class="size-[18px]" />
      </span>
      <span>{@label}</span>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp mobile_nav_item(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "rounded-lg px-3.5 py-2 text-xs font-bold transition",
        @active && "bg-clubeira-blue-soft text-clubeira-blue",
        !@active && "text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
      ]}
    >
      {@label}
    </.link>
    """
  end

  defp portal_path(slug), do: "/partner?#{URI.encode_query(%{"polo" => slug})}"
  defp reviews_path(slug), do: "/partner/reviews?#{URI.encode_query(%{"polo" => slug})}"

  defp initials(email) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.split(~r/[^[:alnum:]]+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&(&1 |> String.first() |> String.upcase()))
    |> case do
      "" -> "CL"
      value -> value
    end
  end
end
