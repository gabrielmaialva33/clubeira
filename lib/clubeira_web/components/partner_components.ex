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
    <div id="partner-shell" class="min-h-screen bg-[#f4f7fb] text-slate-950">
      <aside class="fixed inset-y-0 left-0 hidden w-[278px] overflow-hidden bg-[#071d38] text-white lg:flex lg:flex-col">
        <div class="absolute inset-0 opacity-30 [background-image:radial-gradient(circle_at_top_right,rgba(37,99,235,.38),transparent_36%),radial-gradient(circle_at_bottom_left,rgba(249,115,22,.26),transparent_32%)]" />

        <div class="relative flex h-[76px] items-center border-b border-white/[0.07] px-6">
          <.link navigate={@places_path} class="flex items-center gap-3" aria-label="Clubeira">
            <span class="grid size-10 place-items-center rounded-xl bg-white shadow-lg">
              <img src={~p"/images/logo.svg"} class="h-6 w-8" alt="" />
            </span>
            <div>
              <p class="text-lg font-black tracking-[-0.04em]">Clubeira</p>
              <p class="text-[9px] font-bold uppercase tracking-[0.26em] text-orange-300">
                {gettext("Partner portal")}
              </p>
            </div>
          </.link>
        </div>

        <nav id="partner-navigation" class="relative flex-1 px-4 py-6">
          <p class="px-3 text-[10px] font-bold uppercase tracking-[0.22em] text-slate-500">
            {gettext("Your operation")}
          </p>
          <div class="mt-3 space-y-1.5">
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

        <div class="relative border-t border-white/[0.07] p-4">
          <div class="rounded-2xl border border-white/[0.08] bg-white/[0.055] p-3.5">
            <div class="flex items-center gap-3">
              <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-orange-500 text-xs font-black text-white shadow-[0_8px_20px_rgba(249,115,22,.24)]">
                {@initials}
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-semibold">{gettext("Partner manager")}</p>
                <p id="partner-user-email" class="truncate text-[11px] text-slate-400">
                  {@account_scope.user.email}
                </p>
              </div>
              <.link
                id="partner-logout"
                href="/partner/logout"
                method="delete"
                class="grid size-8 place-items-center rounded-lg text-slate-400 transition hover:bg-white/10 hover:text-orange-300"
                aria-label={gettext("Sign out")}
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
              </.link>
            </div>
          </div>
        </div>
      </aside>

      <div class="min-h-screen lg:pl-[278px]">
        <header class="sticky top-0 z-20 h-[76px] border-b border-slate-200/80 bg-white/85 backdrop-blur-xl">
          <div class="flex h-full items-center justify-between gap-4 px-5 sm:px-7 lg:px-9">
            <div class="min-w-0">
              <p class="text-[10px] font-bold uppercase tracking-[0.2em] text-slate-400">
                {gettext("Current operation")}
              </p>
              <p class="truncate text-sm font-bold text-slate-900">{@current_polo.name}</p>
            </div>

            <.form for={@polo_form} id="partner-polo-form" phx-change="change_polo">
              <label for={@polo_form[:polo].id} class="sr-only">{gettext("Select polo")}</label>
              <select
                id={@polo_form[:polo].id}
                name={@polo_form[:polo].name}
                class="h-10 max-w-56 rounded-xl border border-slate-200 bg-white px-3 text-sm font-bold text-slate-700 shadow-sm outline-none focus:border-blue-500 focus:ring-4 focus:ring-blue-100"
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
          class="flex gap-1 border-b border-slate-200 bg-white px-4 py-2 lg:hidden"
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

        <main class="px-5 py-7 sm:px-7 lg:px-9 lg:py-9">
          {render_slot(@inner_block)}
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
        "flex h-11 items-center gap-3 rounded-xl px-3 text-sm font-semibold transition",
        @active && "bg-blue-500 text-white shadow-[0_10px_24px_rgba(37,99,235,.24)]",
        !@active && "text-slate-300 hover:bg-white/[0.06] hover:text-white"
      ]}
    >
      <span class="grid size-7 place-items-center rounded-lg bg-white/10">
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
        "rounded-xl px-3.5 py-2 text-xs font-black transition",
        @active && "bg-blue-50 text-blue-700",
        !@active && "text-slate-500 hover:bg-slate-50 hover:text-slate-900"
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
