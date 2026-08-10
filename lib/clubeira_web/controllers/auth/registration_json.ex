defmodule ClubeiraWeb.Auth.RegistrationJSON do
  @moduledoc false

  alias ClubeiraWeb.Auth.SessionJSON

  defdelegate create(assigns), to: SessionJSON
end
