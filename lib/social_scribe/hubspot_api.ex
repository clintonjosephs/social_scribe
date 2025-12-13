defmodule SocialScribe.HubSpotApi do
  @moduledoc """
  Module for interacting with HubSpot API.

  This module handles:
  - Searching for contacts
  - Fetching contact details
  - Updating contact records

  All operations require a valid access token from a connected HubSpot account.
  Tokens are automatically refreshed if expired.
  """

  require Logger

  alias SocialScribe.Accounts
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.TokenRefresher

  @hubspot_api_base_url "https://api.hubapi.com"

  @doc """
  Searches for contacts in HubSpot by query string.

  Returns a list of contacts matching the search query.

  ## Examples

      iex> search_contacts(access_token, "John Doe")
      {:ok, [%{"id" => "123", "properties" => %{"firstname" => "John", ...}}, ...]}

      iex> search_contacts_with_credential(credential, "John Doe")
      {:ok, [%{"id" => "123", "properties" => %{"firstname" => "John", ...}}, ...]}
  """
  def search_contacts(access_token, query) when is_binary(query) do
    client = build_client(access_token)

    # HubSpot search API endpoint
    url = "#{@hubspot_api_base_url}/crm/v3/objects/contacts/search"

    # HubSpot search API uses filterGroups with filters
    # We'll search across multiple fields: firstname, lastname, email
    payload = %{
      filterGroups: [
        %{
          filters: [
            %{
              propertyName: "firstname",
              operator: "CONTAINS_TOKEN",
              value: query
            }
          ]
        },
        %{
          filters: [
            %{
              propertyName: "lastname",
              operator: "CONTAINS_TOKEN",
              value: query
            }
          ]
        },
        %{
          filters: [
            %{
              propertyName: "email",
              operator: "CONTAINS_TOKEN",
              value: query
            }
          ]
        }
      ],
      limit: 10,
      properties: [
        "firstname",
        "lastname",
        "email",
        "phone",
        "company",
        "jobtitle",
        "lifecyclestage",
        "hubspot_owner_id"
      ]
    }

    case Tesla.post(client, url, payload) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        contacts = Map.get(body, "results", [])
        {:ok, contacts}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("HubSpot search failed: #{status} - #{inspect(error_body)}")
        {:error, {:api_error, status, error_body}}

      {:error, reason} ->
        Logger.error("HubSpot search HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Gets a specific contact by ID from HubSpot.

  Returns the full contact record with all properties.

  ## Examples

      iex> get_contact(access_token, "123")
      {:ok, %{"id" => "123", "properties" => %{"firstname" => "John", ...}}}
  """
  def get_contact(access_token, contact_id) when is_binary(contact_id) do
    client = build_client(access_token)

    # Get contact with common properties
    properties = [
      "firstname",
      "lastname",
      "email",
      "phone",
      "mobilephone",
      "company",
      "jobtitle",
      "website",
      "address",
      "city",
      "state",
      "zip",
      "country",
      "lifecyclestage",
      "hubspot_owner_id",
      "createdate",
      "lastmodifieddate"
    ]

    properties_param = Enum.join(properties, ",")

    url =
      "#{@hubspot_api_base_url}/crm/v3/objects/contacts/#{contact_id}?properties=#{properties_param}"

    case Tesla.get(client, url) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: 404}} ->
        {:error, :not_found}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("HubSpot get contact failed: #{status} - #{inspect(error_body)}")
        {:error, {:api_error, status, error_body}}

      {:error, reason} ->
        Logger.error("HubSpot get contact HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Updates a contact in HubSpot with the provided properties.

  The properties map should contain HubSpot property names as keys.

  ## Examples

      iex> update_contact(access_token, "123", %{"phone" => "8885550000", "firstname" => "Tyler"})
      {:ok, %{"id" => "123", "properties" => %{"phone" => "8885550000", ...}}}
  """
  def update_contact(access_token, contact_id, properties) when is_map(properties) do
    client = build_client(access_token)

    url = "#{@hubspot_api_base_url}/crm/v3/objects/contacts/#{contact_id}"

    payload = %{
      properties: properties
    }

    case Tesla.patch(client, url, payload) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("HubSpot update contact failed: #{status} - #{inspect(error_body)}")
        {:error, {:api_error, status, error_body}}

      {:error, reason} ->
        Logger.error("HubSpot update contact HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Gets all available contact properties/schema from HubSpot.

  This is useful for understanding what fields can be updated.
  """
  def get_contact_properties(access_token) do
    client = build_client(access_token)

    url = "#{@hubspot_api_base_url}/crm/v3/properties/contacts"

    case Tesla.get(client, url) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        properties = Map.get(body, "results", [])
        {:ok, properties}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("HubSpot get properties failed: #{status} - #{inspect(error_body)}")
        {:error, {:api_error, status, error_body}}

      {:error, reason} ->
        Logger.error("HubSpot get properties HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Searches for contacts using a UserCredential (automatically refreshes token if needed).
  """
  def search_contacts_with_credential(%UserCredential{} = credential, query) do
    with {:ok, token} <- ensure_valid_token(credential) do
      search_contacts(token, query)
    end
  end

  @doc """
  Gets a contact using a UserCredential (automatically refreshes token if needed).
  """
  def get_contact_with_credential(%UserCredential{} = credential, contact_id) do
    with {:ok, token} <- ensure_valid_token(credential) do
      get_contact(token, contact_id)
    end
  end

  @doc """
  Updates a contact using a UserCredential (automatically refreshes token if needed).
  """
  def update_contact_with_credential(%UserCredential{} = credential, contact_id, properties) do
    with {:ok, token} <- ensure_valid_token(credential) do
      update_contact(token, contact_id, properties)
    end
  end

  @doc """
  Gets contact properties using a UserCredential (automatically refreshes token if needed).
  """
  def get_contact_properties_with_credential(%UserCredential{} = credential) do
    with {:ok, token} <- ensure_valid_token(credential) do
      get_contact_properties(token)
    end
  end

  @doc """
  Creates a custom property for contacts in HubSpot.

  ## Examples

      iex> create_contact_property(access_token, "account_balance", "Account Balance", "number")
      {:ok, %{"name" => "account_balance", ...}}
  """
  def create_contact_property(
        access_token,
        property_name,
        label,
        type \\ "string",
        field_type \\ "text"
      ) do
    client = build_client(access_token)
    url = "#{@hubspot_api_base_url}/crm/v3/properties/contacts"

    payload = %{
      groupName: "contactinformation",
      name: property_name,
      label: label,
      type: type,
      fieldType: field_type,
      hasUniqueValue: false
    }

    case Tesla.post(client, url, payload) do
      {:ok, %Tesla.Env{status: 201, body: body}} ->
        Logger.info("Successfully created HubSpot property: #{property_name}")
        {:ok, body}

      {:ok, %Tesla.Env{status: 409, body: _body}} ->
        # Property already exists
        Logger.info("HubSpot property #{property_name} already exists")
        {:ok, :already_exists}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("HubSpot create property failed: #{status} - #{inspect(error_body)}")
        {:error, {:api_error, status, error_body}}

      {:error, reason} ->
        Logger.error("HubSpot create property HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Creates a contact property using a UserCredential (automatically refreshes token if needed).
  """
  def create_contact_property_with_credential(
        %UserCredential{} = credential,
        property_name,
        label,
        type \\ "string",
        field_type \\ "text"
      ) do
    with {:ok, token} <- ensure_valid_token(credential) do
      create_contact_property(token, property_name, label, type, field_type)
    end
  end

  @doc """
  Ensures a property exists, creating it if necessary.
  Returns the property type and field type to use.
  """
  def ensure_property_exists(access_token, property_name, label, value) do
    # Standard HubSpot fields that always exist - don't try to create them
    standard_fields =
      MapSet.new([
        "firstname",
        "lastname",
        "email",
        "phone",
        "mobilephone",
        "company",
        "jobtitle",
        "website",
        "address",
        "city",
        "state",
        "zip",
        "country",
        "lifecyclestage",
        "hubspot_owner_id"
      ])

    property_name_lower = String.downcase(property_name)

    # Don't try to create standard fields
    if MapSet.member?(standard_fields, property_name_lower) do
      Logger.info("Property #{property_name} is a standard HubSpot field, skipping creation")
      {:ok, :exists}
    else
      # First check if property exists
      case get_contact_properties(access_token) do
        {:ok, properties} ->
          property_names =
            properties
            |> Enum.map(fn prop -> Map.get(prop, "name") |> String.downcase() end)
            |> MapSet.new()

          if MapSet.member?(property_names, property_name_lower) do
            {:ok, :exists}
          else
            # Determine property type from value
            {type, field_type} = infer_property_type(value)

            # Create the property
            case create_contact_property(access_token, property_name, label, type, field_type) do
              {:ok, _} -> {:ok, :created}
              {:error, reason} -> {:error, reason}
            end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Ensures a property exists using a UserCredential.
  """
  def ensure_property_exists_with_credential(
        %UserCredential{} = credential,
        property_name,
        label,
        value
      ) do
    with {:ok, token} <- ensure_valid_token(credential) do
      ensure_property_exists(token, property_name, label, value)
    end
  end

  # Infers the HubSpot property type from a value
  # Returns {type, fieldType} where fieldType must be one of HubSpot's valid field types:
  # calculation_equation, checkbox, phonenumber, number, textarea, booleancheckbox, file, text, date, html, select, radio
  defp infer_property_type(value) when is_binary(value) do
    # Check if it's a date
    cond do
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}/, value) ->
        {"date", "date"}

      Regex.match?(~r/^\d{1,2}\/\d{1,2}\/\d{4}/, value) ->
        {"date", "date"}

      # Check if it's a number (with currency symbols or commas)
      Regex.match?(~r/^[\$€£¥]?\s*\d+([.,]\d+)?%?$/, String.replace(value, ~r/[,]/, "")) ->
        {"number", "number"}

      # Check if it's a phone number - use "phonenumber" (no underscore) for HubSpot
      Regex.match?(~r/^[\d\s\-\(\)\+]+$/, value) &&
          String.length(String.replace(value, ~r/[\s\-\(\)\+]/, "")) >= 10 ->
        {"string", "phonenumber"}

      # Check if it's an email
      Regex.match?(~r/^[^\s]+@[^\s]+$/, value) ->
        {"string", "text"}

      # Default to text
      true ->
        {"string", "text"}
    end
  end

  defp infer_property_type(value) when is_number(value), do: {"number", "number"}
  defp infer_property_type(_), do: {"string", "text"}

  # Ensures the credential has a valid token, refreshing if necessary
  defp ensure_valid_token(%UserCredential{} = credential) do
    # Check if token is expired or will expire soon (within 5 minutes)
    expires_at = credential.expires_at || DateTime.utc_now()
    now = DateTime.utc_now()
    # 5 minutes buffer
    buffer_seconds = 300

    if DateTime.compare(expires_at, DateTime.add(now, buffer_seconds, :second)) == :lt do
      # Token is expired or will expire soon, refresh it
      if is_nil(credential.refresh_token) || credential.refresh_token == "" do
        Logger.warning(
          "HubSpot credential #{credential.id} has no refresh_token. Token expired and cannot be refreshed. User needs to re-authenticate."
        )

        {:error, {:no_refresh_token, "Token expired and no refresh token available"}}
      else
        case TokenRefresher.refresh_hubspot_token(credential.refresh_token) do
          {:ok, token_data} ->
            # Update the credential with new token
            updated_attrs = %{
              "access_token" => token_data["access_token"],
              "expires_in" => token_data["expires_in"] || 3600
            }

            # Preserve refresh_token if a new one is provided
            updated_attrs =
              if token_data["refresh_token"] do
                Map.put(updated_attrs, "refresh_token", token_data["refresh_token"])
              else
                updated_attrs
              end

            case Accounts.update_credential_tokens(credential, updated_attrs) do
              {:ok, updated_credential} ->
                Logger.info("Refreshed HubSpot token for credential #{credential.id}")
                {:ok, updated_credential.token}

              {:error, reason} ->
                Logger.error(
                  "Failed to update HubSpot credential after refresh: #{inspect(reason)}"
                )

                {:error, {:update_failed, reason}}
            end

          {:error, reason} ->
            Logger.error("Failed to refresh HubSpot token: #{inspect(reason)}")
            {:error, {:refresh_failed, reason}}
        end
      end
    else
      {:ok, credential.token}
    end
  end

  # Private helper function to build Tesla client with authentication
  defp build_client(access_token) do
    Tesla.client([
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers, [{"Authorization", "Bearer #{access_token}"}]}
    ])
  end
end
