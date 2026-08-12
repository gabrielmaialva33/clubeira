defmodule ClubeiraWeb.BackofficeComponents do
  @moduledoc "Reusable visual primitives for the capability-aware backoffice."

  use ClubeiraWeb, :html

  attr :account_scope, :map, required: true
  attr :access, :map, required: true
  attr :current_polo, :map, required: true
  attr :polo_form, Phoenix.HTML.Form, required: true
  attr :flash, :map, required: true

  attr :active_section, :atom,
    values: [
      :overview,
      :places,
      :partners,
      :commercial,
      :validation,
      :subscriptions,
      :payments,
      :platform_billing,
      :moderation,
      :operations
    ],
    default: :overview

  slot :inner_block, required: true

  def shell(assigns) do
    assigns =
      assigns
      |> assign(:initials, initials(assigns.account_scope.user.email))
      |> assign(:capabilities, MapSet.new(assigns.current_polo.capabilities))
      |> assign(:dashboard_path, ~p"/admin?#{[polo: assigns.current_polo.slug]}")
      |> assign(:places_path, ~p"/admin/places?#{[polo: assigns.current_polo.slug]}")
      |> assign(:partners_path, ~p"/admin/partners?#{[polo: assigns.current_polo.slug]}")
      |> assign(
        :commercial_path,
        ~p"/admin/commercial/benefits?#{[polo: assigns.current_polo.slug]}"
      )
      |> assign(
        :validation_path,
        ~p"/admin/validation-points?#{[polo: assigns.current_polo.slug]}"
      )
      |> assign(
        :subscriptions_path,
        ~p"/admin/subscriptions?#{[polo: assigns.current_polo.slug]}"
      )
      |> assign(:payments_path, ~p"/admin/payments?#{[polo: assigns.current_polo.slug]}")
      |> assign(
        :platform_billing_path,
        ~p"/admin/platform-billing?#{[polo: assigns.current_polo.slug]}"
      )
      |> assign(
        :moderation_path,
        ~p"/admin/moderation/reviews?#{[polo: assigns.current_polo.slug]}"
      )
      |> assign(
        :operations_path,
        ~p"/admin/operations/outbox?#{[polo: assigns.current_polo.slug, status: "dead_letter"]}"
      )

    ~H"""
    <div id="backoffice-shell" class="min-h-screen bg-[#f4f7fb] text-slate-950">
      <div
        id="backoffice-sidebar-overlay"
        class="fixed inset-0 z-30 hidden bg-slate-950/45 backdrop-blur-sm lg:hidden"
        phx-click={toggle_mobile_sidebar()}
      />

      <aside
        id="backoffice-sidebar"
        class="fixed inset-y-0 left-0 z-40 flex w-[278px] -translate-x-full flex-col overflow-hidden bg-[#081b33] text-white shadow-2xl transition-transform duration-300 lg:translate-x-0 lg:shadow-none"
      >
        <div class="absolute inset-0 opacity-25 [background-image:radial-gradient(circle_at_top_right,rgba(59,130,246,.35),transparent_35%),radial-gradient(circle_at_bottom_left,rgba(249,115,22,.25),transparent_30%)]" />

        <div class="relative flex h-[76px] items-center justify-between border-b border-white/[0.07] px-6">
          <.link navigate={~p"/admin"} class="flex items-center gap-3" aria-label="Clubeira">
            <span class="grid size-10 place-items-center rounded-xl bg-white shadow-lg">
              <img src={~p"/images/logo.svg"} class="h-6 w-8" alt="" />
            </span>
            <div>
              <p class="text-lg font-black tracking-[-0.04em]">Clubeira</p>
              <p class="text-[9px] font-bold uppercase tracking-[0.26em] text-blue-300">
                {gettext("Backoffice")}
              </p>
            </div>
          </.link>
          <button
            id="close-mobile-navigation"
            type="button"
            phx-click={toggle_mobile_sidebar()}
            class="grid size-9 place-items-center rounded-lg text-slate-400 transition hover:bg-white/10 hover:text-white lg:hidden"
            aria-label={gettext("Close navigation")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <nav id="backoffice-navigation" class="relative flex-1 overflow-y-auto px-4 py-6">
          <p class="px-3 text-[10px] font-bold uppercase tracking-[0.22em] text-slate-500">
            {gettext("Workspace")}
          </p>
          <div class="mt-3 space-y-1.5">
            <.nav_item
              id="backoffice-nav-overview"
              navigate={@dashboard_path}
              icon="hero-squares-2x2"
              label={gettext("Overview")}
              active={@active_section == :overview}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :manage_partners)}
              id="backoffice-nav-places"
              navigate={@places_path}
              icon="hero-building-storefront"
              label={gettext("Places")}
              active={@active_section == :places}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :manage_partners)}
              id="backoffice-nav-partners"
              navigate={@partners_path}
              icon="hero-user-group"
              label={gettext("Partners")}
              active={@active_section == :partners}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :manage_partners)}
              id="backoffice-nav-commercial"
              navigate={@commercial_path}
              icon="hero-ticket"
              label={gettext("Commercial")}
              active={@active_section == :commercial}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :manage_partners)}
              id="backoffice-nav-validation"
              navigate={@validation_path}
              icon="hero-qr-code"
              label={gettext("Validation")}
              active={@active_section == :validation}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :manage_billing)}
              id="backoffice-nav-subscriptions"
              navigate={@subscriptions_path}
              icon="hero-user-group"
              label={gettext("Subscriptions")}
              active={@active_section == :subscriptions}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :manage_billing)}
              id="backoffice-nav-finance"
              navigate={@payments_path}
              icon="hero-banknotes"
              label={gettext("Finance")}
              active={@active_section == :payments}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :manage_billing)}
              id="backoffice-nav-platform-billing"
              navigate={@platform_billing_path}
              icon="hero-building-library"
              label={gettext("Clubeira billing")}
              active={@active_section == :platform_billing}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :moderate_reviews)}
              id="backoffice-nav-moderation"
              navigate={@moderation_path}
              icon="hero-shield-check"
              label={gettext("Moderation")}
              active={@active_section == :moderation}
            />
            <.nav_item
              :if={MapSet.member?(@capabilities, :manage_operations)}
              id="backoffice-nav-operations"
              navigate={@operations_path}
              icon="hero-command-line"
              label={gettext("Operations")}
              active={@active_section == :operations}
            />
          </div>
        </nav>

        <div class="relative border-t border-white/[0.07] p-4">
          <div class="rounded-2xl border border-white/[0.08] bg-white/[0.055] p-3.5">
            <div class="flex items-center gap-3">
              <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-blue-500 text-xs font-black text-white shadow-[0_8px_20px_rgba(37,99,235,.28)]">
                {@initials}
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-semibold">{gettext("Administrator")}</p>
                <p id="backoffice-user-email" class="truncate text-[11px] text-slate-400">
                  {@account_scope.user.email}
                </p>
              </div>
              <.link
                href={~p"/admin/logout"}
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
            <div class="flex min-w-0 items-center gap-3">
              <button
                id="open-mobile-navigation"
                type="button"
                phx-click={toggle_mobile_sidebar()}
                class="grid size-10 shrink-0 place-items-center rounded-xl border border-slate-200 bg-white text-slate-600 shadow-sm lg:hidden"
                aria-label={gettext("Open navigation")}
              >
                <.icon name="hero-bars-3-bottom-left" class="size-5" />
              </button>
              <div class="hidden min-w-0 sm:block">
                <p class="text-[10px] font-bold uppercase tracking-[0.2em] text-slate-400">
                  {gettext("Current operation")}
                </p>
                <p class="truncate text-sm font-bold text-slate-900">{@current_polo.name}</p>
              </div>
            </div>

            <div class="flex items-center gap-2.5">
              <.form
                for={@polo_form}
                id="polo-switcher"
                phx-change="change_polo"
                class="relative"
              >
                <label for={@polo_form[:polo].id} class="sr-only">{gettext("Select polo")}</label>
                <select
                  id={@polo_form[:polo].id}
                  name={@polo_form[:polo].name}
                  class="h-10 max-w-44 appearance-none rounded-xl border border-slate-200 bg-white py-0 pl-3.5 pr-9 text-xs font-bold text-slate-700 shadow-sm outline-none transition hover:border-slate-300 focus:border-blue-500 focus:ring-4 focus:ring-blue-100 sm:max-w-56 sm:text-sm"
                >
                  <option
                    :for={polo <- @access.polos}
                    value={polo.slug}
                    selected={polo.slug == @current_polo.slug}
                  >
                    {polo.name}
                  </option>
                </select>
                <.icon
                  name="hero-chevron-up-down"
                  class="pointer-events-none absolute right-3 top-3 size-4 text-slate-400"
                />
              </.form>
            </div>
          </div>
        </header>

        <main class="px-5 py-7 sm:px-7 lg:px-9 lg:py-9">
          {render_slot(@inner_block)}
        </main>
      </div>

      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, default: nil
  attr :navigate, :string, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      id={@id}
      href={@href}
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "group flex h-11 items-center gap-3 rounded-xl px-3 text-sm font-semibold transition",
        @active && "bg-blue-500 text-white shadow-[0_10px_24px_rgba(37,99,235,.24)]",
        !@active && "text-slate-400 hover:bg-white/[0.07] hover:text-white"
      ]}
    >
      <span class={[
        "grid size-7 place-items-center rounded-lg transition",
        @active && "bg-white/12 text-white",
        !@active && "text-slate-500 group-hover:text-orange-300"
      ]}>
        <.icon name={@icon} class="size-[18px]" />
      </span>
      <span>{@label}</span>
    </.link>
    """
  end

  defp toggle_mobile_sidebar do
    %JS{}
    |> JS.toggle_class("-translate-x-full", to: "#backoffice-sidebar")
    |> JS.toggle_class("hidden", to: "#backoffice-sidebar-overlay")
  end

  defp initials(email) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.split(~r/[._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&(&1 |> String.first() |> String.upcase()))
    |> case do
      "" -> "CL"
      value -> value
    end
  end
end
