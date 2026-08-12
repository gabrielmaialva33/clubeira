defmodule ClubeiraWeb.MemberComponents do
  @moduledoc "Reusable visual primitives for the member application."

  use ClubeiraWeb, :html

  attr :account_scope, :map, required: true
  attr :flash, :map, required: true

  attr :active_section, :atom,
    values: [:overview, :catalog, :wallet, :subscriptions, :orders, :profile, :privacy],
    default: :overview

  slot :inner_block, required: true

  def shell(assigns) do
    assigns = assign(assigns, :initials, initials(assigns.account_scope.user.email))

    ~H"""
    <div id="member-shell" class="clubeira-canvas min-h-screen text-clubeira-ink">
      <header class="sticky top-0 z-30 border-b border-clubeira-line bg-white/95 backdrop-blur">
        <div class="mx-auto flex h-[68px] max-w-[1380px] items-center gap-4 px-4 sm:px-6">
          <.link navigate={~p"/app"} class="flex shrink-0 items-center gap-3" aria-label="Clubeira">
            <span class="clubeira-brand-mark">
              <img src={~p"/images/logo.svg"} class="h-5 w-7" alt="" />
            </span>
            <div class="hidden sm:block">
              <p class="text-[17px] font-black tracking-[-0.04em]">Clubeira</p>
              <p class="text-[9px] font-bold uppercase tracking-[0.22em] text-clubeira-orange">
                {gettext("Member app")}
              </p>
            </div>
          </.link>

          <nav id="member-navigation" class="ml-auto hidden items-center gap-1 lg:flex">
            <.nav_link
              id="member-nav-overview"
              navigate={~p"/app"}
              label={gettext("Home")}
              active={@active_section == :overview}
            />
            <.nav_link
              id="member-nav-catalog"
              navigate={~p"/app/catalog"}
              label={gettext("Explore")}
              active={@active_section == :catalog}
            />
            <.nav_link
              id="member-nav-wallet"
              navigate={~p"/app/wallet"}
              label={gettext("Wallet")}
              active={@active_section == :wallet}
            />
            <.nav_link
              id="member-nav-subscriptions"
              navigate={~p"/app/subscriptions"}
              label={gettext("Subscriptions")}
              active={@active_section == :subscriptions}
            />
            <.nav_link
              id="member-nav-orders"
              navigate={~p"/app/orders"}
              label={gettext("Orders")}
              active={@active_section == :orders}
            />
          </nav>

          <details class="relative ml-auto lg:ml-3">
            <summary
              id="member-account-menu"
              class="flex cursor-pointer list-none items-center gap-2 rounded-lg border border-clubeira-line bg-white p-1 pr-2.5 transition hover:border-slate-300"
            >
              <span class="grid size-8 place-items-center rounded-md bg-clubeira-blue text-[10px] font-black text-white">{@initials}</span>
              <span class="hidden max-w-40 truncate text-xs font-bold text-clubeira-ink sm:block">{@account_scope.user.email}</span>
              <.icon name="hero-chevron-down" class="size-4 text-clubeira-muted" />
            </summary>
            <div class="absolute right-0 mt-2 w-56 overflow-hidden rounded-xl border border-clubeira-line bg-white p-1.5 shadow-[0_12px_32px_rgba(16,33,61,.12)]">
              <.link
                id="member-nav-profile"
                navigate={~p"/app/profile"}
                class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-semibold text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
              >
                <.icon name="hero-user-circle" class="size-5 text-clubeira-blue" /> {gettext(
                  "Profile"
                )}
              </.link>
              <.link
                id="member-nav-privacy"
                navigate={~p"/app/privacy"}
                class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-semibold text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
              >
                <.icon name="hero-shield-check" class="size-5 text-clubeira-blue" /> {gettext(
                  "Privacy"
                )}
              </.link>
              <.link
                href={~p"/app/logout"}
                method="delete"
                class="mt-1 flex items-center gap-3 border-t border-clubeira-line px-3 py-3 text-sm font-semibold text-clubeira-orange hover:bg-clubeira-orange-soft"
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" /> {gettext(
                  "Sign out"
                )}
              </.link>
            </div>
          </details>
        </div>
      </header>

      <nav
        id="member-mobile-navigation"
        class="fixed inset-x-0 bottom-0 z-30 grid grid-cols-5 border-t border-clubeira-line bg-white/95 px-2 pt-1.5 pb-[calc(.375rem+env(safe-area-inset-bottom))] backdrop-blur lg:hidden"
      >
        <.mobile_nav_link
          id="member-mobile-nav-overview"
          navigate={~p"/app"}
          icon="hero-home"
          label={gettext("Home")}
          active={@active_section == :overview}
        />
        <.mobile_nav_link
          id="member-mobile-nav-catalog"
          navigate={~p"/app/catalog"}
          icon="hero-magnifying-glass"
          label={gettext("Explore")}
          active={@active_section == :catalog}
        />
        <.mobile_nav_link
          id="member-mobile-nav-wallet"
          navigate={~p"/app/wallet"}
          icon="hero-ticket"
          label={gettext("Wallet")}
          active={@active_section == :wallet}
        />
        <.mobile_nav_link
          id="member-mobile-nav-subscriptions"
          navigate={~p"/app/subscriptions"}
          icon="hero-credit-card"
          label={gettext("Subscriptions")}
          active={@active_section == :subscriptions}
        />
        <.mobile_nav_link
          id="member-mobile-nav-orders"
          navigate={~p"/app/orders"}
          icon="hero-shopping-bag"
          label={gettext("Orders")}
          active={@active_section == :orders}
        />
      </nav>

      <main class="mx-auto max-w-[1380px] px-4 pt-6 pb-24 sm:px-6 sm:pt-8 lg:pb-8">
        <Layouts.flash_group id="member-flash-group" flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "relative shrink-0 rounded-lg px-3.5 py-2 text-xs font-bold transition",
        @active && "bg-clubeira-blue-soft text-clubeira-blue",
        !@active && "text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp mobile_nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "flex min-w-0 flex-col items-center gap-0.5 rounded-lg px-1 py-1.5 text-[10px] font-bold transition",
        @active && "bg-clubeira-blue-soft text-clubeira-blue",
        !@active && "text-clubeira-muted"
      ]}
    >
      <.icon name={@icon} class="size-[18px]" />
      <span class="max-w-full truncate">{@label}</span>
    </.link>
    """
  end

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
