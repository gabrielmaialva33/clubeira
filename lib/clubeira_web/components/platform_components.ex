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
    <div id="platform-shell" class="min-h-screen bg-[#f4f7fb] text-slate-950">
      <aside class="fixed inset-y-0 left-0 hidden w-[278px] overflow-hidden bg-[#071b33] text-white lg:flex lg:flex-col">
        <div class="absolute inset-0 opacity-30 [background-image:radial-gradient(circle_at_top_right,rgba(59,130,246,.38),transparent_36%),radial-gradient(circle_at_bottom_left,rgba(249,115,22,.24),transparent_32%)]" />

        <div class="relative flex h-[76px] items-center border-b border-white/[0.07] px-6">
          <.link navigate={~p"/platform"} class="flex items-center gap-3" aria-label="Clubeira">
            <span class="grid size-10 place-items-center rounded-xl bg-white shadow-lg">
              <img src={~p"/images/logo.svg"} class="h-6 w-8" alt="" />
            </span>
            <div>
              <p class="text-lg font-black tracking-[-0.04em]">Clubeira</p>
              <p class="text-[9px] font-bold uppercase tracking-[0.26em] text-orange-300">
                {gettext("Platform")}
              </p>
            </div>
          </.link>
        </div>

        <nav id="platform-navigation" class="relative flex-1 px-4 py-6">
          <p class="px-3 text-[10px] font-bold uppercase tracking-[0.22em] text-slate-500">
            {gettext("Global control plane")}
          </p>
          <div class="mt-3">
            <.link
              id="platform-nav-overview"
              navigate={~p"/platform"}
              aria-current={@active_section == :overview && "page"}
              class={[
                "flex h-11 items-center gap-3 rounded-xl px-3 text-sm font-semibold transition",
                @active_section == :overview &&
                  "bg-blue-500 text-white shadow-[0_10px_24px_rgba(37,99,235,.24)]"
              ]}
            >
              <span class="grid size-7 place-items-center rounded-lg bg-white/10">
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
                "mt-1 flex h-11 items-center gap-3 rounded-xl px-3 text-sm font-semibold transition",
                @active_section == :privacy &&
                  "bg-blue-500 text-white shadow-[0_10px_24px_rgba(37,99,235,.24)]",
                @active_section != :privacy && "text-slate-300 hover:bg-white/[0.06] hover:text-white"
              ]}
            >
              <span class="grid size-7 place-items-center rounded-lg bg-white/10">
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
                "mt-1 flex h-11 items-center gap-3 rounded-xl px-3 text-sm font-semibold transition",
                @active_section == :billing &&
                  "bg-blue-500 text-white shadow-[0_10px_24px_rgba(37,99,235,.24)]",
                @active_section != :billing && "text-slate-300 hover:bg-white/[0.06] hover:text-white"
              ]}
            >
              <span class="grid size-7 place-items-center rounded-lg bg-white/10">
                <.icon name="hero-banknotes" class="size-[18px]" />
              </span>
              <span>{gettext("Platform billing")}</span>
            </.link>
          </div>
        </nav>

        <div class="relative border-t border-white/[0.07] p-4">
          <div class="rounded-2xl border border-white/[0.08] bg-white/[0.055] p-3.5">
            <div class="flex items-center gap-3">
              <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-orange-500 text-xs font-black text-white shadow-[0_8px_20px_rgba(249,115,22,.24)]">
                {@initials}
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-semibold">{gettext("Platform operator")}</p>
                <p id="platform-user-email" class="truncate text-[11px] text-slate-400">
                  {@account_scope.user.email}
                </p>
              </div>
              <.link
                id="platform-logout"
                href={~p"/platform/logout"}
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
            <div>
              <p class="text-[10px] font-bold uppercase tracking-[0.2em] text-slate-400">
                {gettext("Global operation")}
              </p>
              <p class="text-sm font-bold text-slate-900">{gettext("Clubeira Platform")}</p>
            </div>
            <span class="rounded-xl border border-blue-100 bg-blue-50 px-3 py-2 text-xs font-bold text-blue-700">
              {ngettext("%{count} capability", "%{count} capabilities", @capability_count,
                count: @capability_count
              )}
            </span>
          </div>
        </header>

        <main class="px-5 py-7 sm:px-7 lg:px-9 lg:py-9">
          {render_slot(@inner_block)}
        </main>
      </div>

      <Layouts.flash_group id="platform-flash-group" flash={@flash} />
    </div>
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
