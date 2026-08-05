defmodule ClubeiraWeb.RegistrationJSON do
  @moduledoc false

  alias ClubeiraWeb.AuthSessionJSON

  defdelegate create(assigns), to: AuthSessionJSON
end
