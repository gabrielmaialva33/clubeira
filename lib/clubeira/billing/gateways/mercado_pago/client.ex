defmodule Clubeira.Billing.Gateways.MercadoPago.Client do
  @moduledoc false

  alias Clubeira.Billing.Gateways.MercadoPago.Configuration

  @default_options [retry: false, receive_timeout: 10_000]

  @spec get(keyword()) :: {:ok, Req.Response.t()} | {:error, atom()}
  def get(options), do: request(:get, options, 200..200)

  @spec post(keyword()) :: {:ok, Req.Response.t()} | {:error, atom()}
  def post(options), do: request(:post, options, 200..299)

  defp request(method, options, success_statuses) do
    options =
      @default_options
      |> Keyword.merge(options)
      |> Keyword.merge(Configuration.request_options())

    case Req.request([method: method] ++ options) do
      {:ok, %Req.Response{} = response} -> classify_response(response, success_statuses)
      {:error, _reason} -> {:error, :payment_gateway_unavailable}
    end
  end

  defp classify_response(%Req.Response{status: status} = response, success_statuses) do
    cond do
      status in success_statuses -> {:ok, response}
      status == 429 or status >= 500 -> {:error, :payment_gateway_unavailable}
      true -> {:error, :payment_gateway_rejected}
    end
  end
end
