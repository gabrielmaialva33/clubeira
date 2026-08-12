defmodule ClubeiraWeb.PlatformComponents do
  @moduledoc "Reusable visual primitives for the global platform control plane."

  use ClubeiraWeb, :html

  attr :account_scope, :map, required: true
  attr :access, :map, required: true
  attr :flash, :map, required: true
  attr :active_section, :atom, values: [:overview, :billing, :privacy], default: :overview

  slot :inner_block, required: true

  def shell(assigns) do
    assigns =
      assigns
      |> assign(:initials, initials(assigns.account_scope.user.email))
      |> assign(:capability_count, length(assigns.access.capabilities))

    ~H"""
    <div id="platform-shell" class="clubeira-canvas min-h-screen text-clubeira-ink">
      <aside class="fixed inset-y-0 left-0 hidden w-[252px] overflow-hidden border-r border-clubeira-line bg-white lg:flex lg:flex-col">
        <div class="flex h-[68px] items-center border-b border-clubeira-line px-5">
          <.link navigate={~p"/platform"} class="flex items-center gap-3" aria-label="Clubeira">
            <span class="clubeira-brand-mark">
              <img src={~p"/images/logo.svg"} class="h-5 w-7" alt="" />
            </span>
            <div>
              <p class="text-[17px] font-black tracking-[-0.04em]">Clubeira</p>
              <p class="text-[9px] font-bold uppercase tracking-[0.22em] text-clubeira-orange">
                {gettext("Platform")}
              </p>
            </div>
          </.link>
        </div>

        <nav id="platform-navigation" class="flex-1 px-3 py-5">
          <p class="px-3 text-[10px] font-bold uppercase tracking-[0.18em] text-clubeira-muted">
            {gettext("Global control plane")}
          </p>
          <div class="mt-2 space-y-0.5">
            <.link
              id="platform-nav-overview"
              navigate={~p"/platform"}
              aria-current={@active_section == :overview && "page"}
              class={[
                "clubeira-nav-link",
                @active_section == :overview &&
                  "clubeira-nav-link-active",
                @active_section != :overview &&
                  "text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
              ]}
            >
              <span class="grid size-7 place-items-center rounded-lg bg-white text-clubeira-blue">
                <.icon name="hero-squares-2x2" class="size-[18px]" />
              </span>
              <span>{gettext("Overview")}</span>
            </.link>

            <.link
              :if={:manage_privacy in @access.capabilities}
              id="platform-nav-privacy"
              navigate={~p"/platform/privacy/requests"}
              aria-current={@active_section == :privacy && "page"}
              class={[
                "clubeira-nav-link",
                @active_section == :privacy &&
                  "clubeira-nav-link-active",
                @active_section != :privacy &&
                  "text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
              ]}
            >
              <span class="grid size-7 place-items-center rounded-lg bg-white text-clubeira-blue">
                <.icon name="hero-shield-check" class="size-[18px]" />
              </span>
              <span>{gettext("Privacy")}</span>
            </.link>

            <.link
              :if={:manage_platform_billing in @access.capabilities}
              id="platform-nav-billing"
              navigate={~p"/platform/billing/plans"}
              aria-current={@active_section == :billing && "page"}
              class={[
                "clubeira-nav-link",
                @active_section == :billing &&
                  "clubeira-nav-link-active",
                @active_section != :billing &&
                  "text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
              ]}
            >
              <span class="grid size-7 place-items-center rounded-lg bg-white text-clubeira-blue">
                <.icon name="hero-banknotes" class="size-[18px]" />
              </span>
              <span>{gettext("Platform billing")}</span>
            </.link>
          </div>
        </nav>

        <div class="border-t border-clubeira-line p-3">
          <div class="rounded-xl bg-clubeira-canvas p-3">
            <div class="flex items-center gap-3">
              <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-clubeira-blue text-[11px] font-black text-white">
                {@initials}
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate text-xs font-bold text-clubeira-ink">
                  {gettext("Platform operator")}
                </p>
                <p id="platform-user-email" class="truncate text-[10px] text-clubeira-muted">
                  {@account_scope.user.email}
                </p>
              </div>
              <.link
                id="platform-logout"
                href={~p"/platform/logout"}
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
              <div>
                <p class="text-[10px] font-bold uppercase tracking-[0.16em] text-clubeira-muted">
                  {gettext("Global operation")}
                </p>
                <p class="text-sm font-bold text-clubeira-ink">{gettext("Clubeira Platform")}</p>
              </div>
            </div>
            <span class="rounded-lg border border-blue-100 bg-clubeira-blue-soft px-3 py-2 text-xs font-bold text-clubeira-blue">
              {ngettext("%{count} capability", "%{count} capabilities", @capability_count,
                count: @capability_count
              )}
            </span>
          </div>
        </header>

        <nav
          id="platform-mobile-navigation"
          class="flex gap-1 overflow-x-auto border-b border-clubeira-line bg-white px-3 py-2 lg:hidden"
          aria-label={gettext("Global control plane")}
        >
          <.mobile_nav_item
            id="platform-mobile-nav-overview"
            navigate={~p"/platform"}
            label={gettext("Overview")}
            active={@active_section == :overview}
          />
          <.mobile_nav_item
            :if={:manage_privacy in @access.capabilities}
            id="platform-mobile-nav-privacy"
            navigate={~p"/platform/privacy/requests"}
            label={gettext("Privacy")}
            active={@active_section == :privacy}
          />
          <.mobile_nav_item
            :if={:manage_platform_billing in @access.capabilities}
            id="platform-mobile-nav-billing"
            navigate={~p"/platform/billing/plans"}
            label={gettext("Platform billing")}
            active={@active_section == :billing}
          />
        </nav>

        <main class="mx-auto max-w-[1540px] px-4 py-6 sm:px-6 lg:px-8 lg:py-7">
          <div class="min-w-0">{render_slot(@inner_block)}</div>
        </main>
      </div>

      <Layouts.flash_group id="platform-flash-group" flash={@flash} />
    </div>
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
        "shrink-0 rounded-lg px-3.5 py-2 text-xs font-bold transition",
        @active && "bg-clubeira-blue-soft text-clubeira-blue",
        !@active && "text-clubeira-muted hover:bg-clubeira-canvas hover:text-clubeira-ink"
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
    |> String.split(~r/[._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&(&1 |> String.first() |> String.upcase()))
    |> case do
      "" -> "CL"
      value -> value
    end
  end
end
