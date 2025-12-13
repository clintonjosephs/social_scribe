defmodule SocialScribe.HubSpotAISuggestions do
  @moduledoc """
  Module for generating AI-powered suggestions for HubSpot contact updates based on meeting transcripts.

  This module analyzes meeting transcripts and suggests updates to HubSpot contact fields
  such as phone numbers, names, company information, etc.

  It uses Google Gemini AI to extract relevant information from the transcript and
  format it as structured suggestions that can be reviewed and applied to HubSpot contacts.
  """

  alias SocialScribe.Meetings
  require Logger

  @gemini_model "gemini-2.0-flash-lite"
  @gemini_api_base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @doc """
  Generates suggested updates for a HubSpot contact based on a meeting transcript.

  Returns a list of suggested updates, each containing:
  - field_name: The HubSpot property name (e.g., "phone", "firstname")
  - field_label: Human-readable label (e.g., "Phone number", "First name")
  - existing_value: Current value in HubSpot (or nil if not set)
  - suggested_value: AI-suggested new value from transcript
  - confidence: Optional confidence indicator
  - transcript_reference: Optional reference to where in transcript this was found

  ## Examples

      iex> generate_suggestions(meeting, hubspot_contact)
      {:ok, [
        %{
          field_name: "phone",
          field_label: "Phone number",
          existing_value: "5551234567",
          suggested_value: "8885550000",
          transcript_reference: "Found in transcript (15:46)"
        },
        ...
      ]}
  """
  def generate_suggestions(%Meetings.Meeting{} = meeting, hubspot_contact) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        # Format HubSpot contact info for context
        contact_info = format_contact_info(hubspot_contact)

        prompt = build_suggestion_prompt(meeting_prompt, contact_info)

        case call_gemini(prompt) do
          {:ok, ai_response} ->
            parse_ai_response(ai_response)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Formats HubSpot contact data into a readable string for the AI prompt
  defp format_contact_info(hubspot_contact) when is_map(hubspot_contact) do
    properties = Map.get(hubspot_contact, "properties", %{})

    # Standard fields
    standard_fields = [
      {"firstname", "First Name"},
      {"lastname", "Last Name"},
      {"email", "Email"},
      {"phone", "Phone"},
      {"mobilephone", "Mobile Phone"},
      {"company", "Company"},
      {"jobtitle", "Job Title"},
      {"website", "Website"},
      {"address", "Address"},
      {"city", "City"},
      {"state", "State"},
      {"zip", "ZIP"},
      {"country", "Country"}
    ]

    standard_info =
      standard_fields
      |> Enum.map(fn {key, label} ->
        "- #{label}: #{Map.get(properties, key, "Not set")}"
      end)
      |> Enum.join("\n")

    # Include all other properties (custom fields) that have values
    custom_fields =
      properties
      |> Map.drop(Enum.map(standard_fields, &elem(&1, 0)))
      |> Enum.filter(fn {_key, value} -> value != nil && value != "" end)
      |> Enum.map(fn {key, value} ->
        "- #{key}: #{value}"
      end)

    custom_info = if Enum.empty?(custom_fields), do: "", else: "\n\nCustom Fields:\n#{Enum.join(custom_fields, "\n")}"

    """
    Current HubSpot Contact Information:
    #{standard_info}#{custom_info}
    """
  end

  defp format_contact_info(_), do: "No HubSpot contact information available."

  # Builds the AI prompt for generating suggestions
  defp build_suggestion_prompt(meeting_prompt, contact_info) do
    """
    You are analyzing a meeting transcript to identify updates that should be made to a HubSpot CRM contact record.

    #{contact_info}

    #{meeting_prompt}

    Please analyze the transcript and identify ANY information mentioned that should update the HubSpot contact record above.

    Look for:
    - Phone numbers (mobile, office, etc.)
    - Name changes or corrections (first name, last name)
    - Email addresses
    - Company information
    - Job titles
    - Address information
    - Website URLs
    - Financial information (account balances, retirement accounts, investment details, etc.)
    - Personal information (birthdates, anniversaries, preferences, etc.)
    - Business information (revenue, employee count, industry details, etc.)
    - Any other relevant information that should be stored in the CRM

    For each update you find:
    1. Identify the HubSpot field name:
       - For standard fields, use EXACT HubSpot property names (no underscores or hyphens): "phone", "mobilephone", "firstname", "lastname", "email", "company", "jobtitle", "website", "address", "city", "state", "zip", "country"
       - IMPORTANT: Use "mobilephone" (not "mobile_phone" or "mobile-phone"), "firstname" (not "first_name"), "lastname" (not "last_name"), "jobtitle" (not "job_title"), "zip" (not "zip_code")
       - For custom fields or new information, create a descriptive field name using lowercase letters and underscores (e.g., "account_balance", "retirement_date", "investment_portfolio_value", "preferred_contact_method")
       - If the contact already has custom fields listed above, use those exact field names
    2. Provide a human-readable label for the field
    3. Note the current value in HubSpot (or "No existing value" if not set)
    4. Provide the suggested new value from the transcript
    5. If possible, note approximately where in the transcript this was mentioned (timestamp or context)

    Return your response as a JSON array of objects, where each object has:
    - "field_name": The HubSpot property name (e.g., "phone", "firstname")
    - "field_label": Human-readable label (e.g., "Phone number", "First name")
    - "existing_value": Current value in HubSpot or null
    - "suggested_value": The new value suggested from transcript
    - "transcript_reference": Optional note about where this was found (e.g., "Found in transcript (15:46)")

    Only suggest updates where:
    - The information is clearly stated in the transcript
    - The suggested value is different from the existing value (or there's no existing value)
    - The information is relevant to contact management

    Return ONLY valid JSON, no additional text or explanation. Example format:
    [
      {
        "field_name": "phone",
        "field_label": "Phone number",
        "existing_value": "5551234567",
        "suggested_value": "8885550000",
        "transcript_reference": "Found in transcript (15:46)"
      },
      {
        "field_name": "firstname",
        "field_label": "First name",
        "existing_value": "Ty",
        "suggested_value": "Tyler",
        "transcript_reference": "Mentioned by participant"
      },
      {
        "field_name": "account_balance",
        "field_label": "Account Balance",
        "existing_value": null,
        "suggested_value": "$250,000",
        "transcript_reference": "Mentioned at 12:30"
      },
      {
        "field_name": "retirement_date",
        "field_label": "Retirement Date",
        "existing_value": null,
        "suggested_value": "2026-06-15",
        "transcript_reference": "Discussed retirement plans"
      }
    ]
    """
  end

  # Calls the Gemini API with the prompt
  defp call_gemini(prompt_text) do
    api_key = Application.fetch_env!(:social_scribe, :gemini_api_key)
    url = "#{@gemini_api_base_url}/#{@gemini_model}:generateContent?key=#{api_key}"

    payload = %{
      contents: [
        %{
          parts: [%{text: prompt_text}]
        }
      ]
    }

    client = build_client()

    case Tesla.post(client, url, payload) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        # Extract text content from response
        text_path = [
          "candidates",
          Access.at(0),
          "content",
          "parts",
          Access.at(0),
          "text"
        ]

        case get_in(body, text_path) do
          nil ->
            {:error, {:parsing_error, "No text content found in Gemini response", body}}

          text_content ->
            {:ok, text_content}
        end

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("Gemini API error: #{status} - #{inspect(error_body)}")
        {:error, {:api_error, status, error_body}}

      {:error, reason} ->
        Logger.error("Gemini HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  # Parses the AI response JSON into structured suggestions
  defp parse_ai_response(ai_response) do
    try do
      # Try to extract JSON from the response (AI might wrap it in markdown code blocks)
      json_text =
        ai_response
        |> String.replace(~r/```json\s*/, "")
        |> String.replace(~r/```\s*/, "")
        |> String.trim()

      case Jason.decode(json_text) do
        {:ok, suggestions} when is_list(suggestions) ->
          # Validate and normalize suggestions
          normalized =
            suggestions
            |> Enum.filter(&is_valid_suggestion/1)
            |> Enum.map(&normalize_suggestion/1)

          {:ok, normalized}

        {:ok, _} ->
          {:error, :invalid_format}

        {:error, reason} ->
          Logger.error("Failed to parse AI response JSON: #{inspect(reason)}")
          Logger.error("Response was: #{ai_response}")
          {:error, {:json_parse_error, reason}}
      end
    rescue
      e ->
        Logger.error("Error parsing AI response: #{inspect(e)}")
        {:error, {:parse_error, e}}
    end
  end

  # Validates that a suggestion has required fields
  defp is_valid_suggestion(suggestion) when is_map(suggestion) do
    Map.has_key?(suggestion, "field_name") &&
      Map.has_key?(suggestion, "suggested_value") &&
      is_binary(Map.get(suggestion, "field_name")) &&
      Map.get(suggestion, "suggested_value") != nil &&
      Map.get(suggestion, "suggested_value") != ""
  end

  defp is_valid_suggestion(_), do: false

  # Normalizes a suggestion to ensure all fields are present and field names are correct
  defp normalize_suggestion(suggestion) do
    raw_field_name = Map.get(suggestion, "field_name", "")
    normalized_field_name = normalize_field_name(raw_field_name)

    %{
      field_name: normalized_field_name,
      field_label: Map.get(suggestion, "field_label", raw_field_name),
      existing_value: Map.get(suggestion, "existing_value"),
      suggested_value: Map.get(suggestion, "suggested_value", ""),
      transcript_reference: Map.get(suggestion, "transcript_reference")
    }
  end

  # Maps common field name variations to correct HubSpot property names
  defp normalize_field_name(field_name) when is_binary(field_name) do
    field_name_lower = String.downcase(field_name)

    # Map common variations to HubSpot standard property names
    field_mapping = %{
      "mobile_phone" => "mobilephone",
      "mobile-phone" => "mobilephone",
      "mobile phone" => "mobilephone",
      "cell_phone" => "mobilephone",
      "cell-phone" => "mobilephone",
      "cell phone" => "mobilephone",
      "cellphone" => "mobilephone",
      "first_name" => "firstname",
      "first-name" => "firstname",
      "first name" => "firstname",
      "last_name" => "lastname",
      "last-name" => "lastname",
      "last name" => "lastname",
      "job_title" => "jobtitle",
      "job-title" => "jobtitle",
      "job title" => "jobtitle",
      "postal_code" => "zip",
      "postal-code" => "zip",
      "postal code" => "zip",
      "zip_code" => "zip",
      "zip-code" => "zip",
      "zip code" => "zip",
      "lifecycle_stage" => "lifecyclestage",
      "lifecycle-stage" => "lifecyclestage",
      "lifecycle stage" => "lifecyclestage"
    }

    Map.get(field_mapping, field_name_lower, field_name)
  end

  defp normalize_field_name(field_name), do: field_name

  # Builds Tesla client for API calls
  defp build_client do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @gemini_api_base_url},
      Tesla.Middleware.JSON
    ])
  end
end
