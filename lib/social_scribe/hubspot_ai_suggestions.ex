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
  def generate_suggestions(
        %Meetings.Meeting{} = meeting,
        hubspot_contact,
        available_properties \\ nil
      ) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        # Format HubSpot contact info for context
        contact_info = format_contact_info(hubspot_contact, available_properties)

        prompt = build_suggestion_prompt(meeting_prompt, contact_info, available_properties)

        case call_gemini(prompt) do
          {:ok, ai_response} ->
            # Parse AI response - don't filter here, show all suggestions
            # Filtering will happen at update time when we can create missing properties
            parse_ai_response(ai_response)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Formats HubSpot contact data into a readable string for the AI prompt
  defp format_contact_info(hubspot_contact, _available_properties) when is_map(hubspot_contact) do
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

    custom_info =
      if Enum.empty?(custom_fields),
        do: "",
        else: "\n\nCustom Fields:\n#{Enum.join(custom_fields, "\n")}"

    """
    Current HubSpot Contact Information:
    #{standard_info}#{custom_info}
    """
  end

  defp format_contact_info(_, _), do: "No HubSpot contact information available."

  # Builds the AI prompt for generating suggestions
  defp build_suggestion_prompt(meeting_prompt, contact_info, available_properties) do
    available_fields_info = format_available_fields(available_properties)

    """
    You are analyzing a meeting transcript to identify updates that should be made to a HubSpot CRM contact record.

    #{contact_info}

    #{available_fields_info}

    #{meeting_prompt}

    Please analyze the transcript CAREFULLY and identify EVERY piece of information mentioned that should update the HubSpot contact record above.

    IMPORTANT: Extract ALL information from the transcript, even if it seems minor or if it's mentioned casually. Be thorough and comprehensive.

    CRITICAL: DO NOT suggest updates for HubSpot system fields. These fields are automatically managed by HubSpot and cannot be updated manually:
    - Fields starting with "hs_" (e.g., hs_object_id, hs_owner_id, hs_analytics_*, hs_email_*, hs_sales_email_*, hs_sequences_*)
    - System fields: hubspot_owner_id, lastmodifieddate, createdate, lifecyclestage
    - Analytics and tracking fields (any field that tracks HubSpot internal data, analytics, or system metadata)
    Only suggest fields that contain user-provided contact information, not HubSpot's internal tracking data.

    Look for and extract:
    - Phone numbers (mobile, office, home, work, cell, etc.) - ANY phone number mentioned
    - Name changes or corrections (first name, last name, nicknames, preferred names)
    - Email addresses (work, personal, alternate emails)
    - Company information (company name, business name, employer)
    - Job titles (current title, previous titles, role changes)
    - Address information (street address, city, state, zip, country, mailing address)
    - Website URLs (company website, personal website, LinkedIn profile)
    - Financial information (account balances, retirement accounts, investment details, savings amounts, income, expenses, credit scores, account numbers, etc.) - PAY SPECIAL ATTENTION TO NUMBERS AND AMOUNTS MENTIONED
    - Personal information (birthdates, anniversaries, preferences, family information, etc.)
    - Business information (revenue, employee count, industry details, business type, etc.)
    - Dates (important dates, deadlines, milestones, appointments)
    - Goals and objectives (personal or business goals mentioned)
    - Preferences (communication preferences, contact preferences, etc.)
    - Notes and comments (any relevant notes or comments about the contact)
    - Relationships (family members, business partners, referrals mentioned)
    - Any other relevant information that should be stored in the CRM

    For each piece of information you find:
    1. Identify the HubSpot field name:
       - For standard fields, use EXACT HubSpot property names (no underscores or hyphens): "phone", "mobilephone", "firstname", "lastname", "email", "company", "jobtitle", "website", "address", "city", "state", "zip", "country"
       - IMPORTANT: Use "mobilephone" (not "mobile_phone" or "mobile-phone"), "firstname" (not "first_name"), "lastname" (not "last_name"), "jobtitle" (not "job_title"), "zip" (not "zip_code")
       - For custom fields or new information, create a descriptive field name using lowercase letters and underscores (e.g., "account_balance", "retirement_date", "investment_portfolio_value", "preferred_contact_method", "spouse_name", "children_names", "annual_income", etc.)
       - If the contact already has custom fields listed above, use those exact field names
    2. Provide a human-readable label for the field
    3. Note the current value in HubSpot (or null if not set)
    4. Provide the suggested new value from the transcript (extract the exact value mentioned)
    5. If possible, note approximately where in the transcript this was mentioned (timestamp or context)

    Return your response as a JSON array of objects, where each object has:
    - "field_name": The HubSpot property name (e.g., "phone", "firstname")
    - "field_label": Human-readable label (e.g., "Phone number", "First name")
    - "existing_value": Current value in HubSpot or null
    - "suggested_value": The new value suggested from transcript
    - "transcript_reference": Optional note about where this was found (e.g., "Found in transcript (15:46)")

    Suggest updates for:
    - ANY information mentioned in the transcript, even if mentioned casually or in passing
    - Information that is different from the existing value (or if there's no existing value)
    - Information that is relevant to contact management or relationship building
    - Don't filter out information - if it's mentioned, include it as a suggestion

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
          Logger.info("AI returned #{length(suggestions)} raw suggestions")

          # Validate and normalize suggestions
          valid_suggestions = Enum.filter(suggestions, &is_valid_suggestion/1)
          invalid_count = length(suggestions) - length(valid_suggestions)

          if invalid_count > 0 do
            Logger.warning("Filtered out #{invalid_count} invalid suggestions")
          end

          # Standard HubSpot fields that always exist
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
              "country"
            ])

          normalized =
            valid_suggestions
            |> Enum.map(&normalize_suggestion/1)
            # Filter out HubSpot system fields
            |> Enum.reject(fn suggestion ->
              field_name = String.downcase(suggestion.field_name)
              is_hubspot_system_field?(field_name)
            end)
            # Ensure field names are unique - if duplicates exist, keep only the first one
            |> Enum.reduce({[], MapSet.new()}, fn suggestion, {acc, seen} ->
              field_name = suggestion.field_name
              field_name_lower = String.downcase(field_name)

              cond do
                # If it's a standard field and we've already seen it, skip duplicates
                MapSet.member?(standard_fields, field_name_lower) &&
                    MapSet.member?(seen, field_name_lower) ->
                  Logger.info("Skipping duplicate standard field '#{field_name}'")
                  {acc, seen}

                # If it's a duplicate custom field, skip it (don't rename - just keep first)
                MapSet.member?(seen, field_name_lower) ->
                  Logger.warning(
                    "Found duplicate field name '#{field_name}', keeping first occurrence only"
                  )

                  {acc, seen}

                # New field - add it
                true ->
                  {[suggestion | acc], MapSet.put(seen, field_name_lower)}
              end
            end)
            |> elem(0)
            |> Enum.reverse()

          Logger.info("Returning #{length(normalized)} normalized suggestions")
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
  # IMPORTANT: Only normalize standard HubSpot fields, not custom fields
  defp normalize_field_name(field_name) when is_binary(field_name) do
    field_name_lower = String.downcase(field_name)

    # Map common variations to HubSpot standard property names
    # Only normalize known standard fields to avoid merging different custom fields
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

    # Only apply mapping if it's a known standard field variation
    # For custom fields (like account_balance, credit_score, etc.), keep as-is
    case Map.get(field_mapping, field_name_lower) do
      # Custom field or already correct - keep original
      nil -> field_name
      # Standard field variation - normalize it
      normalized -> normalized
    end
  end

  defp normalize_field_name(field_name), do: field_name

  # Checks if a field is a HubSpot system field that shouldn't be shown as suggestions
  defp is_hubspot_system_field?(field_name) when is_binary(field_name) do
    # HubSpot system fields that start with "hs_" or are known system fields
    system_fields =
      MapSet.new([
        "hs_object_id",
        "hubspot_owner_id",
        "hs_owner_id",
        "lastmodifieddate",
        "createdate",
        "lifecyclestage",
        "hs_analytics_source",
        "hs_analytics_source_data_1",
        "hs_analytics_source_data_2",
        "hs_created_by_user_id",
        "hs_updated_by_user_id",
        "hs_lead_status",
        "hs_all_contact_vids",
        "hs_analytics_first_touch_converting_campaign",
        "hs_analytics_last_touch_converting_campaign",
        "recent_deal_amount",
        "total_revenue",
        "num_associated_deals",
        "num_notes",
        "num_contacted_notes",
        "num_notes_created",
        "num_activities",
        "num_unique_conversion_events",
        "hs_analytics_num_visits",
        "hs_analytics_num_page_views",
        "hs_analytics_first_timestamp",
        "hs_analytics_last_timestamp",
        "hs_analytics_first_visit_timestamp",
        "hs_analytics_last_visit_timestamp",
        "hs_email_domain",
        "hs_email_quota",
        "hs_email_recipient",
        "hs_email_sender",
        "hs_email_sender_domain",
        "hs_email_sender_first_name",
        "hs_email_sender_last_name",
        "hs_email_sender_name",
        "hs_email_subject",
        "hs_email_text",
        "hs_email_to_firstname",
        "hs_email_to_lastname",
        "hs_email_to_name",
        "hs_latest_sequence_ended_date",
        "hs_latest_sequence_enrolled",
        "hs_latest_sequence_enrolled_date",
        "hs_latest_sequence_finished_date",
        "hs_latest_sequence_unenrolled_date",
        "hs_sales_email_last_clicked",
        "hs_sales_email_last_opened",
        "hs_sales_email_last_replied",
        "hs_sequences_enrolled_count",
        "hs_sequences_is_enrolled",
        "hs_sequences_is_unenrolled",
        "hs_sequences_unenrolled_count",
        "hs_analytics_source",
        "hs_analytics_source_data_1",
        "hs_analytics_source_data_2",
        "hs_created_by_user_id",
        "hs_updated_by_user_id",
        "hs_lead_status",
        "hs_all_contact_vids",
        "hs_analytics_first_touch_converting_campaign",
        "hs_analytics_last_touch_converting_campaign"
      ])

    # Check if it's a system field or starts with "hs_"
    MapSet.member?(system_fields, field_name) || String.starts_with?(field_name, "hs_")
  end

  defp is_hubspot_system_field?(_), do: false

  # Formats available HubSpot properties for the AI prompt
  defp format_available_fields(nil), do: ""

  defp format_available_fields(available_properties) when is_list(available_properties) do
    property_names =
      available_properties
      |> Enum.map(fn prop ->
        case prop do
          %{"name" => name} -> name
          name when is_binary(name) -> name
          _ -> nil
        end
      end)
      |> Enum.filter(&(!is_nil(&1)))
      |> Enum.sort()

    if Enum.empty?(property_names) do
      ""
    else
      """

      Available HubSpot Properties:
      You can ONLY use these property names when creating suggestions. Do NOT create new property names.
      Standard properties: firstname, lastname, email, phone, mobilephone, company, jobtitle, website, address, city, state, zip, country
      Custom properties: #{Enum.join(property_names, ", ")}

      IMPORTANT: Only use property names from the list above. If information from the transcript doesn't match any existing property, you can still suggest it, but it will need to be created in HubSpot first.
      """
    end
  end

  defp format_available_fields(_), do: ""

  # Builds Tesla client for API calls
  defp build_client do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @gemini_api_base_url},
      Tesla.Middleware.JSON
    ])
  end
end
