defmodule SocialScribeWeb.AuthController do
  use SocialScribeWeb, :controller

  alias SocialScribe.FacebookApi
  alias SocialScribe.Accounts
  alias SocialScribeWeb.UserAuth
  plug Ueberauth

  require Logger

  @doc """
  Handles the initial request to the provider (e.g., Google).
  Ueberauth's plug will redirect the user to the provider's consent page.
  """
  def request(conn, %{"provider" => "hubspot"}) do
    # HubSpot OAuth flow (manual implementation since no Ueberauth strategy)
    client_id = System.get_env("HUBSPOT_CLIENT_ID")
    redirect_uri = System.get_env("HUBSPOT_REDIRECT_URI") || "#{get_base_url(conn)}/auth/hubspot/callback"
    # HubSpot scopes for contact management:
    # - crm.objects.contacts.read: Read contact records via CRM API
    # - crm.objects.contacts.write: Write/update contact records via CRM API
    # - crm.schemas.contacts.read: Read contact schemas/properties (to see available fields)
    # - crm.objects.contacts.search: Search contacts (optional, for search functionality)
    scopes = "crm.objects.contacts.read crm.objects.contacts.write crm.schemas.contacts.read crm.schemas.contacts.write"

    auth_url =
      "https://app.hubspot.com/oauth/authorize?" <>
        URI.encode_query(%{
          client_id: client_id,
          redirect_uri: redirect_uri,
          scope: scopes
        })

    redirect(conn, external: auth_url)
  end

  def request(conn, _params) do
    render(conn, :request)
  end

  defp get_base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host
    port = conn.port

    if port in [80, 443] do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  @doc """
  Handles the callback from the provider after the user has granted consent.
  """
  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "google"
      })
      when not is_nil(user) do
    Logger.info("Google OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, _credential} ->
        conn
        |> put_flash(:info, "Google account added successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not add Google account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "linkedin"
      }) do
    Logger.info("LinkedIn OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, credential} ->
        Logger.info("credential")
        Logger.info(credential)

        conn
        |> put_flash(:info, "LinkedIn account added successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, reason} ->
        Logger.error(reason)

        conn
        |> put_flash(:error, "Could not add LinkedIn account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "facebook"
      })
      when not is_nil(user) do
    Logger.info("Facebook OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, credential} ->
        case FacebookApi.fetch_user_pages(credential.uid, credential.token) do
          {:ok, facebook_pages} ->
            facebook_pages
            |> Enum.each(fn page ->
              Accounts.link_facebook_page(user, credential, page)
            end)

          _ ->
            :ok
        end

        conn
        |> put_flash(
          :info,
          "Facebook account added successfully. Please select a page to connect."
        )
        |> redirect(to: ~p"/dashboard/settings/facebook_pages")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not add Facebook account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  # HubSpot OAuth callback (manual implementation)
  def callback(%{assigns: %{current_user: user}} = conn, %{
        "provider" => "hubspot",
        "code" => code
      })
      when not is_nil(user) do
    Logger.info("HubSpot OAuth callback")

    # Exchange authorization code for access token
    case exchange_hubspot_code(code, conn) do
      {:ok, token_data} ->
        # Fetch user info from HubSpot
        case fetch_hubspot_user_info(token_data["access_token"]) do
          {:ok, user_info} ->
            # Create auth struct similar to Ueberauth format
            auth = %Ueberauth.Auth{
              provider: :hubspot,
              uid: to_string(user_info["portalId"] || user_info["user_id"] || ""),
              info: %Ueberauth.Auth.Info{
                email: user_info["user"] || user_info["email"],
                name: user_info["user"] || user_info["hub_domain"]
              },
              credentials: %Ueberauth.Auth.Credentials{
                token: token_data["access_token"],
                refresh_token: token_data["refresh_token"],
                expires_at: token_data["expires_in"] && DateTime.add(DateTime.utc_now(), token_data["expires_in"], :second)
              }
            }

            case Accounts.find_or_create_user_credential(user, auth) do
              {:ok, _credential} ->
                conn
                |> put_flash(:info, "HubSpot account added successfully.")
                |> redirect(to: ~p"/dashboard/settings")

              {:error, reason} ->
                Logger.error("Failed to create HubSpot credential: #{inspect(reason)}")
                conn
                |> put_flash(:error, "Could not add HubSpot account.")
                |> redirect(to: ~p"/dashboard/settings")
            end

          {:error, reason} ->
            Logger.error("Failed to fetch HubSpot user info: #{inspect(reason)}")
            conn
            |> put_flash(:error, "Could not fetch HubSpot account information.")
            |> redirect(to: ~p"/dashboard/settings")
        end

      {:error, reason} ->
        Logger.error("Failed to exchange HubSpot code: #{inspect(reason)}")
        conn
        |> put_flash(:error, "Could not authenticate with HubSpot.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{current_user: _user}} = conn, %{
        "provider" => "hubspot"
      }) do
    Logger.error("HubSpot OAuth callback missing code parameter")
    conn
    |> put_flash(:error, "HubSpot authentication failed. Please try again.")
    |> redirect(to: ~p"/dashboard/settings")
  end

  defp exchange_hubspot_code(code, conn) do
    client_id = System.get_env("HUBSPOT_CLIENT_ID")
    client_secret = System.get_env("HUBSPOT_CLIENT_SECRET")
    redirect_uri = System.get_env("HUBSPOT_REDIRECT_URI") || "#{get_base_url(conn)}/auth/hubspot/callback"

    # HubSpot requires form-urlencoded format, not JSON
    body = %{
      grant_type: "authorization_code",
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      code: code
    }

    client =
      Tesla.client([
        {Tesla.Middleware.FormUrlencoded,
         encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
        Tesla.Middleware.JSON
      ])

    case Tesla.post(client, "https://api.hubapi.com/oauth/v1/token", body) do
      {:ok, %Tesla.Env{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %Tesla.Env{status: status, body: error}} ->
        Logger.error("HubSpot token exchange failed: #{status} - #{inspect(error)}")
        {:error, {status, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_hubspot_user_info(access_token) do
    client =
      Tesla.client([
        Tesla.Middleware.JSON,
        {Tesla.Middleware.Headers, [{"Authorization", "Bearer #{access_token}"}]}
      ])

    case Tesla.get(client, "https://api.hubapi.com/oauth/v1/access-tokens/#{access_token}") do
      {:ok, %Tesla.Env{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %Tesla.Env{status: status, body: error}} ->
        Logger.error("HubSpot user info fetch failed: #{status} - #{inspect(error)}")
        {:error, {status, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    Logger.info("Google OAuth Login")
    Logger.info(auth)

    case Accounts.find_or_create_user_from_oauth(auth) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)

      {:error, reason} ->
        Logger.info("error")
        Logger.info(reason)

        conn
        |> put_flash(:error, "There was an error signing you in.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    Logger.error("OAuth Login")
    Logger.error(conn)

    conn
    |> put_flash(:error, "There was an error signing you in. Please try again.")
    |> redirect(to: ~p"/")
  end
end
