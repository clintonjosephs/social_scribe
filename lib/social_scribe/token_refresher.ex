defmodule SocialScribe.TokenRefresher do
  @moduledoc """
  Refreshes OAuth tokens for various providers (Google, HubSpot).
  """

  require Logger

  @google_token_url "https://oauth2.googleapis.com/token"
  @hubspot_token_url "https://api.hubapi.com/oauth/v1/token"

  @behaviour SocialScribe.TokenRefresherApi

  def client do
    middlewares = [
      {Tesla.Middleware.FormUrlencoded,
       encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
      Tesla.Middleware.JSON
    ]

    Tesla.client(middlewares)
  end

  def refresh_token(refresh_token_string) do
    refresh_google_token(refresh_token_string)
  end

  @doc """
  Refreshes a Google OAuth token.
  """
  def refresh_google_token(refresh_token_string) do
    client_id = Application.fetch_env!(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_id]

    client_secret =
      Application.fetch_env!(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_secret]

    body = %{
      client_id: client_id,
      client_secret: client_secret,
      refresh_token: refresh_token_string,
      grant_type: "refresh_token"
    }

    # Use Tesla to make the POST request
    case Tesla.post(client(), @google_token_url, body, opts: [form_urlencoded: true]) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {status, error_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Refreshes a HubSpot OAuth token.
  """
  def refresh_hubspot_token(refresh_token_string) do
    client_id = System.get_env("HUBSPOT_CLIENT_ID")
    client_secret = System.get_env("HUBSPOT_CLIENT_SECRET")

    if is_nil(client_id) || is_nil(client_secret) do
      Logger.error("HubSpot client credentials not configured")
      {:error, :missing_credentials}
    else
      body = %{
        grant_type: "refresh_token",
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token_string
      }

      case Tesla.post(client(), @hubspot_token_url, body, opts: [form_urlencoded: true]) do
        {:ok, %Tesla.Env{status: 200, body: response_body}} ->
          {:ok, response_body}

        {:ok, %Tesla.Env{status: status, body: error_body}} ->
          Logger.error("HubSpot token refresh failed: #{status} - #{inspect(error_body)}")
          {:error, {status, error_body}}

        {:error, reason} ->
          Logger.error("HubSpot token refresh HTTP error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
