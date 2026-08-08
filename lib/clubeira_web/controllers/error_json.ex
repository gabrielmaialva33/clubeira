defmodule ClubeiraWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  alias ClubeiraWeb.Gettext, as: GettextBackend

  def render(template, %{code: code}) when is_binary(code) do
    %{errors: %{code: code, detail: translated_status(template)}}
  end

  def render(template, _assigns) do
    %{errors: %{detail: translated_status(template)}}
  end

  defp translated_status(template) do
    Gettext.dgettext(
      GettextBackend,
      "api_errors",
      Phoenix.Controller.status_message_from_template(template)
    )
  end
end
