defmodule ClubeiraWeb.Backoffice.PartnerAgreementJSON do
  @moduledoc false

  def show(%{agreement: agreement}), do: %{data: agreement}

  def index(%{agreements: agreements, page: page}) do
    %{data: agreements, page: page}
  end
end
