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
    <div id="member-shell" class="min-h-screen bg-[#f5f7fb] text-slate-950">
      <header class="sticky top-0 z-30 border-b border-slate-200/80 bg-white/90 backdrop-blur-xl">
        <div class="mx-auto flex h-[72px] max-w-[1440px] items-center gap-4 px-4 sm:px-7">
          <.link navigate={~p"/app"} class="flex shrink-0 items-center gap-3" aria-label="Clubeira">
            <span class="grid size-10 place-items-center rounded-xl bg-[#0b2342] shadow-lg">
              <img src={~p"/images/logo.svg"} class="h-6 w-8 brightness-0 invert" alt="" />
            </span>
            <div class="hidden sm:block">
              <p class="text-lg font-black tracking-[-0.04em]">Clubeira</p>
              <p class="text-[9px] font-bold uppercase tracking-[0.24em] text-orange-600">
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
              class="flex cursor-pointer list-none items-center gap-2 rounded-xl border border-slate-200 bg-white p-1.5 pr-3 shadow-sm"
            >
              <span class="grid size-8 place-items-center rounded-lg bg-gradient-to-br from-blue-600 to-blue-800 text-[10px] font-black text-white">{@initials}</span>
              <span class="hidden max-w-40 truncate text-xs font-bold text-slate-700 sm:block">{@account_scope.user.email}</span>
              <.icon name="hero-chevron-down" class="size-4 text-slate-400" />
            </summary>
            <div class="absolute right-0 mt-2 w-56 overflow-hidden rounded-2xl border border-slate-200 bg-white p-2 shadow-2xl">
              <.link
                id="member-nav-profile"
                navigate={~p"/app/profile"}
                class="flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-semibold text-slate-700 hover:bg-slate-50"
              >
                <.icon name="hero-user-circle" class="size-5 text-blue-600" /> {gettext("Profile")}
              </.link>
              <.link
                id="member-nav-privacy"
                navigate={~p"/app/privacy"}
                class="flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-semibold text-slate-700 hover:bg-slate-50"
              >
                <.icon name="hero-shield-check" class="size-5 text-blue-600" /> {gettext("Privacy")}
              </.link>
              <.link
                href={~p"/app/logout"}
                method="delete"
                class="mt-1 flex items-center gap-3 border-t border-slate-100 px-3 py-3 text-sm font-semibold text-orange-700 hover:bg-orange-50"
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" /> {gettext(
                  "Sign out"
                )}
              </.link>
            </div>
          </details>
        </div>

        <nav
          id="member-mobile-navigation"
          class="mx-auto flex max-w-[1440px] gap-1 overflow-x-auto border-t border-slate-100 px-3 py-2 lg:hidden"
        >
          <.nav_link
            id="member-mobile-nav-overview"
            navigate={~p"/app"}
            label={gettext("Home")}
            active={@active_section == :overview}
          />
          <.nav_link
            id="member-mobile-nav-catalog"
            navigate={~p"/app/catalog"}
            label={gettext("Explore")}
            active={@active_section == :catalog}
          />
          <.nav_link
            id="member-mobile-nav-wallet"
            navigate={~p"/app/wallet"}
            label={gettext("Wallet")}
            active={@active_section == :wallet}
          />
          <.nav_link
            id="member-mobile-nav-subscriptions"
            navigate={~p"/app/subscriptions"}
            label={gettext("Subscriptions")}
            active={@active_section == :subscriptions}
          />
          <.nav_link
            id="member-mobile-nav-orders"
            navigate={~p"/app/orders"}
            label={gettext("Orders")}
            active={@active_section == :orders}
          />
        </nav>
      </header>

      <main class="mx-auto max-w-[1440px] px-4 py-7 sm:px-7 sm:py-9">
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
        "shrink-0 rounded-xl px-3.5 py-2 text-xs font-bold transition",
        @active && "bg-blue-50 text-blue-700",
        !@active && "text-slate-500 hover:bg-slate-50 hover:text-slate-900"
      ]}
    >
      {@label}
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
