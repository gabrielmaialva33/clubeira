defmodule ClubeiraWeb.PublicLocale do
  @moduledoc "Sets the browser-negotiated locale for unauthenticated public LiveViews."

  import Phoenix.Component, only: [assign: 3]

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:set_locale, _params, session, socket) do
    locale = Map.get(session, "locale", "pt_BR")
    Gettext.put_locale(ClubeiraWeb.Gettext, locale)

    {:cont, assign(socket, :locale, locale)}
  end
end
