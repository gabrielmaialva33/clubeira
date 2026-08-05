defmodule ClubeiraWeb.RedemptionDeviceJSON do
  @moduledoc false

  def create(%{enrollment: enrollment}) do
    %{device: device, contract_device: contract_device} = enrollment

    %{
      data: %{
        id: device.id,
        access_contract_id: contract_device.access_contract_id,
        platform: device.platform,
        status: device.status,
        authorized_at: DateTime.to_iso8601(contract_device.inserted_at)
      }
    }
  end
end
