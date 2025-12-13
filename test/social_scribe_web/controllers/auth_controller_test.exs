defmodule SocialScribeWeb.AuthControllerTest do
  use SocialScribeWeb.ConnCase

  import SocialScribe.AccountsFixtures

  alias SocialScribe.Accounts

  describe "HubSpot OAuth" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      %{conn: conn, user: user}
    end

    test "GET /auth/hubspot redirects to HubSpot OAuth", %{conn: conn} do
      # Set environment variables for HubSpot OAuth
      System.put_env("HUBSPOT_CLIENT_ID", "test_client_id")
      System.put_env("HUBSPOT_REDIRECT_URI", "http://localhost:4000/auth/hubspot/callback")

      conn = get(conn, ~p"/auth/hubspot")

      assert redirected_to(conn) =~ "app.hubspot.com/oauth/authorize"
      assert redirected_to(conn) =~ "client_id=test_client_id"
      assert redirected_to(conn) =~ "scope="
    end

    test "GET /auth/hubspot/callback without code shows error", %{conn: conn} do
      conn = get(conn, ~p"/auth/hubspot/callback", %{"provider" => "hubspot"})

      assert redirected_to(conn) == ~p"/dashboard/settings"
      assert get_flash(conn, :error) == "HubSpot authentication failed. Please try again."
    end

    # Note: Full integration tests for OAuth callback with HTTP mocking
    # would require Bypass or similar HTTP mocking library.
    # The controller logic for successful OAuth flow is tested through
    # integration tests or manual testing.
  end
end
