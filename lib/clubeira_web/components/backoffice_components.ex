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
    <div id="backoffice-shell" class="clubeira-canvas min-h-screen text-clubeira-ink">
      <div
        id="backoffice-sidebar-overlay"
        class="fixed inset-0 z-30 hidden bg-slate-950/45 backdrop-blur-sm lg:hidden"
        phx-click={toggle_mobile_sidebar()}
      />

      <aside
        id="backoffice-sidebar"
        class="fixed inset-y-0 left-0 z-40 flex w-[252px] -translate-x-full flex-col overflow-hidden border-r border-clubeira-line bg-white text-clubeira-ink shadow-xl transition-transform duration-300 lg:translate-x-0 lg:shadow-none"
      >
        <div class="flex h-[68px] items-center justify-between border-b border-clubeira-line px-5">
          <.link navigate={~p"/admin"} class="flex items-center gap-3" aria-label="Clubeira">
            <span class="clubeira-brand-mark">
              <img src={~p"/images/logo.svg"} class="h-5 w-7" alt="" />
            </span>
            <div>
              <p class="text-[17px] font-black tracking-[-0.04em]">Clubeira</p>
              <p class="text-[9px] font-bold uppercase tracking-[0.22em] text-clubeira-orange">
                {gettext("Backoffice")}
              </p>
            </div>
          </.link>
          <button
            id="close-mobile-navigation"
            type="button"
            phx-click={toggle_mobile_sidebar()}
            class="grid size-9 place-items-center rounded-lg text-clubeira-muted transition hover:bg-clubeira-canvas hover:text-clubeira-ink lg:hidden"
            aria-label={gettext("Close navigation")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <nav id="backoffice-navigation" class="flex-1 overflow-y-auto px-3 py-5">
          <p class="px-3 text-[10px] font-bold uppercase tracking-[0.18em] text-clubeira-muted">
            {gettext("Workspace")}
          </p>
          <div class="mt-2 space-y-0.5">
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

        <div class="border-t border-clubeira-line p-3">
          <div class="rounded-xl bg-clubeira-canvas p-3">
            <div class="flex items-center gap-3">
              <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-clubeira-blue text-[11px] font-black text-white">
                {@initials}
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate text-xs font-bold text-clubeira-ink">{gettext("Administrator")}</p>
                <p id="backoffice-user-email" class="truncate text-[10px] text-clubeira-muted">
                  {@account_scope.user.email}
                </p>
              </div>
              <.link
                href={~p"/admin/logout"}
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
              <button
                id="open-mobile-navigation"
                type="button"
                phx-click={toggle_mobile_sidebar()}
                class="grid size-10 shrink-0 place-items-center rounded-lg border border-clubeira-line bg-white text-clubeira-muted lg:hidden"
                aria-label={gettext("Open navigation")}
              >
                <.icon name="hero-bars-3-bottom-left" class="size-5" />
              </button>
              <div class="hidden min-w-0 sm:block">
                <p class="text-[10px] font-bold uppercase tracking-[0.16em] text-clubeira-muted">
                  {gettext("Current operation")}
                </p>
                <p class="truncate text-sm font-bold text-clubeira-ink">{@current_polo.name}</p>
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
                  class="clubeira-control max-w-44 appearance-none py-0 pl-3.5 pr-9 text-xs font-bold sm:max-w-56 sm:text-sm"
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

        <main class="mx-auto max-w-[1680px] px-4 py-6 sm:px-6 lg:px-8 lg:py-7">
          <div class="min-w-0">{render_slot(@inner_block)}</div>
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
        "clubeira-nav-link group",
        @active && "clubeira-nav-link-active",
        !@active && "text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
      ]}
    >
      <span class={[
        "grid size-7 place-items-center rounded-lg transition",
        @active && "bg-white text-clubeira-blue",
        !@active && "text-clubeira-muted group-hover:text-clubeira-orange"
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
