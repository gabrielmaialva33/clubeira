defmodule ClubeiraWeb.PublicComponents do
  @moduledoc "Shared navigation and presentation primitives for public discovery."

  use ClubeiraWeb, :html

  attr :navigate, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :back?, :boolean, default: false
  attr :show_terms?, :boolean, default: false

  def header(assigns) do
    ~H"""
    <header class="sticky top-0 z-20 border-b border-clubeira-line bg-white/95 backdrop-blur">
      <div class="mx-auto flex h-[68px] max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8">
        <.link navigate={@navigate} class="flex items-center gap-3" aria-label={@title}>
          <span class="clubeira-brand-mark">
            <.icon :if={@back?} name="hero-arrow-left" class="size-4 text-clubeira-orange" />
            <img :if={!@back?} src={~p"/images/logo.svg"} class="h-5 w-7" alt="" />
          </span>
          <span>
            <span class="block text-[17px] font-black leading-none tracking-[-0.04em]">
              {@title}
            </span>
            <span class="mt-1 block text-[9px] font-bold uppercase tracking-[0.2em] text-clubeira-orange">
              {@subtitle}
            </span>
          </span>
        </.link>

        <div class="flex items-center gap-1.5">
          <.link
            :if={@show_terms?}
            navigate={~p"/termos"}
            class="hidden rounded-lg px-3 py-2 text-xs font-bold text-clubeira-muted transition hover:bg-clubeira-canvas hover:text-clubeira-ink sm:inline-flex"
          >
            {gettext("Terms")}
          </.link>
          <.link navigate={~p"/app/login"} class="clubeira-button-primary h-9 px-4 text-xs">
            {gettext("Sign in")}
          </.link>
        </div>
      </div>
    </header>
    """
  end

  def footer(assigns) do
    ~H"""
    <footer class="mt-auto border-t border-clubeira-line bg-white">
      <div class="mx-auto flex max-w-7xl flex-col gap-4 px-4 py-6 sm:flex-row sm:items-center sm:justify-between sm:px-6 lg:px-8">
        <div class="flex items-center gap-2.5">
          <span class="clubeira-brand-mark size-8">
            <img src={~p"/images/logo.svg"} class="h-4 w-6" alt="" />
          </span>
          <div>
            <p class="text-sm font-black tracking-[-0.03em] text-clubeira-ink">Clubeira</p>
            <p class="text-[9px] font-bold uppercase tracking-[0.18em] text-clubeira-orange">
              {gettext("Benefits near you")}
            </p>
          </div>
        </div>
        <nav class="flex items-center gap-5 text-xs font-bold text-clubeira-muted">
          <.link navigate={~p"/termos"} class="hover:text-clubeira-ink">{gettext("Terms")}</.link>
          <.link navigate={~p"/app/login"} class="text-clubeira-blue hover:text-blue-800">
            {gettext("Sign in")}
          </.link>
        </nav>
      </div>
    </footer>
    """
  end
end
