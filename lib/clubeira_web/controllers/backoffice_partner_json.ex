defmodule ClubeiraWeb.BackofficePartnerJSON do
  @moduledoc false

  def create(%{result: result}) do
    %{
      data: %{
        organization: %{
          id: result.organization.id,
          legal_name: result.organization.legal_name,
          trade_name: result.organization.trade_name,
          status: result.organization.status
        },
        place: %{
          id: result.place.id,
          slug: result.place.slug,
          name: result.place.name,
          status: result.place.status
        },
        participation: %{
          id: result.participation.id,
          status: result.participation.status
        }
      }
    }
  end
end
