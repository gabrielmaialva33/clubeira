defmodule ClubeiraWeb.Gettext.Plural do
  @moduledoc false

  @behaviour Gettext.Plural

  @impl true
  defdelegate nplurals(locale), to: Gettext.Plural

  @impl true
  defdelegate plural(locale, count), to: Gettext.Plural

  @impl true
  defdelegate plural_forms_header(locale), to: Gettext.Plural
end
