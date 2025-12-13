defmodule SocialScribeWeb.MeetingLive.Show do
  use SocialScribeWeb, :live_view

  import SocialScribeWeb.PlatformLogo
  import SocialScribeWeb.ClipboardButton

  alias SocialScribe.{Meetings, RecallApi, Accounts, HubSpotApi}
  alias SocialScribe.Automations
  require Logger

  @impl true
  def mount(%{"id" => meeting_id}, _session, socket) do
    meeting = Meetings.get_meeting_with_details(meeting_id)

    user_has_automations =
      Automations.list_active_user_automations(socket.assigns.current_user.id)
      |> length()
      |> Kernel.>(0)

    automation_results = Automations.list_automation_results_for_meeting(meeting_id)

    # Check if user has HubSpot account connected
    has_hubspot_account =
      Accounts.list_user_credentials(socket.assigns.current_user, provider: "hubspot")
      |> length()
      |> Kernel.>(0)

    if meeting.calendar_event.user_id != socket.assigns.current_user.id do
      socket =
        socket
        |> put_flash(:error, "You do not have permission to view this meeting.")
        |> redirect(to: ~p"/dashboard/meetings")

      {:error, socket}
    else
      # Check recording status
      {has_recording, recording_status} = check_recording_status(meeting.recall_bot.recall_bot_id)

      # Check if transcript exists but is empty (meaning we've already tried to create it)
      transcript_exists_but_empty =
        meeting.meeting_transcript &&
          meeting.meeting_transcript.content &&
          Map.get(meeting.meeting_transcript.content, "data", []) == []

      socket =
        socket
        |> assign(:page_title, "Meeting Details: #{meeting.title}")
        |> assign(:meeting, meeting)
        |> assign(:automation_results, automation_results)
        |> assign(:user_has_automations, user_has_automations)
        |> assign(:has_hubspot_account, has_hubspot_account)
        |> assign(:has_recording, has_recording)
        |> assign(:recording_status, recording_status)
        |> assign(:transcript_exists_but_empty, transcript_exists_but_empty)
        |> assign(:transcript_loading, false)
        |> assign(:email_generating, false)
        |> assign(:participants_loading, false)
        |> assign(
          :follow_up_email_form,
          to_form(%{
            "follow_up_email" => meeting.follow_up_email || ""
          })
        )

      # Subscribe to meeting updates via PubSub
      if connected?(socket) do
        Phoenix.PubSub.subscribe(SocialScribe.PubSub, "meeting:#{meeting_id}")
      end

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"automation_result_id" => automation_result_id}, _uri, socket) do
    automation_result = Automations.get_automation_result!(automation_result_id)
    automation = Automations.get_automation!(automation_result.automation_id)

    socket =
      socket
      |> assign(:automation_result, automation_result)
      |> assign(:automation, automation)

    {:noreply, socket}
  end

  @impl true
  def handle_params(%{"id" => _meeting_id}, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate-follow-up-email", params, socket) do
    socket =
      socket
      |> assign(:follow_up_email_form, to_form(params))

    {:noreply, socket}
  end

  @impl true
  def handle_event("generate-follow-up-email", _params, socket) do
    meeting = socket.assigns.meeting

    # Check if meeting has transcript and participants
    has_transcript =
      meeting.meeting_transcript &&
        meeting.meeting_transcript.content &&
        Map.get(meeting.meeting_transcript.content, "data", []) != []

    has_participants = Enum.any?(meeting.meeting_participants || [])

    if has_transcript && has_participants do
      socket = assign(socket, :email_generating, true)

      # Enqueue AI content generation worker
      %{meeting_id: meeting.id}
      |> SocialScribe.Workers.AIContentGenerationWorker.new()
      |> Oban.insert()

      Logger.info("Enqueued AI content generation for meeting #{meeting.id}")

      socket =
        socket
        |> assign(:email_generating, false)
        |> put_flash(
          :info,
          "Follow-up email generation started. It may take a few moments. The page will refresh automatically when ready."
        )

      # Refresh meeting data after a delay
      send(self(), {:refresh_meeting, meeting.id})

      {:noreply, socket}
    else
      socket =
        socket
        |> put_flash(
          :error,
          "Cannot generate follow-up email: Meeting must have both transcript and participants."
        )

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("extract-participants", _params, socket) do
    meeting = socket.assigns.meeting

    # Check if meeting has transcript
    has_transcript =
      meeting.meeting_transcript &&
        meeting.meeting_transcript.content &&
        Map.get(meeting.meeting_transcript.content, "data", []) != []

    has_participants = Enum.any?(meeting.meeting_participants || [])

    if has_transcript do
      if has_participants do
        socket =
          socket
          |> put_flash(:info, "This meeting already has participants extracted.")

        {:noreply, socket}
      else
        socket = assign(socket, :participants_loading, true)

        # Extract participants synchronously
        alias SocialScribe.Workers.ParticipantExtractor

        case ParticipantExtractor.extract_participants_for_meeting(meeting) do
          {:ok, count} ->
            Logger.info("Successfully extracted #{count} participants for meeting #{meeting.id}")

            socket =
              socket
              |> assign(:participants_loading, false)
              |> put_flash(
                :info,
                "Successfully extracted #{count} participant(s). Refreshing page..."
              )

            # Refresh meeting data
            send(self(), {:refresh_meeting, meeting.id})

            {:noreply, socket}

          {:skipped, reason} ->
            socket =
              socket
              |> assign(:participants_loading, false)
              |> put_flash(:warning, "Could not extract participants: #{reason}")

            {:noreply, socket}
        end
      end
    else
      socket =
        socket
        |> put_flash(:error, "Cannot extract participants: Meeting must have a transcript.")

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create-transcript", _params, socket) do
    socket = assign(socket, :transcript_loading, true)

    # Get bot to find recording
    case RecallApi.get_bot(socket.assigns.meeting.recall_bot.recall_bot_id) do
      {:ok, %Tesla.Env{body: bot_info}} ->
        recordings = Map.get(bot_info, :recordings, [])

        case List.first(recordings) do
          nil ->
            socket =
              socket
              |> assign(:transcript_loading, false)
              |> put_flash(:error, "No recording found for this meeting.")

            {:noreply, socket}

          recording ->
            recording_id = Map.get(recording, :id)
            recording_status = Map.get(recording, :status, %{})

            if Map.get(recording_status, :code) == "done" do
              # Create transcript
              case RecallApi.create_transcript(recording_id) do
                {:ok, %Tesla.Env{status: status, body: transcript_response}}
                when status in 200..299 ->
                  transcript_id = Map.get(transcript_response, :id)
                  Logger.info("Transcript creation initiated. Transcript ID: #{transcript_id}")

                  socket =
                    socket
                    |> assign(:transcript_loading, false)
                    |> put_flash(
                      :info,
                      "Transcript creation started. It may take a few minutes to process. The page will refresh automatically when ready."
                    )

                  # Refresh meeting data after a short delay to update button visibility
                  send(self(), {:refresh_meeting, socket.assigns.meeting.id})

                  {:noreply, socket}

                {:ok, %Tesla.Env{status: 409}} ->
                  socket =
                    socket
                    |> assign(:transcript_loading, false)
                    |> put_flash(
                      :info,
                      "Transcript is already being processed. Please wait a few minutes and refresh the page."
                    )

                  {:noreply, socket}

                {:ok, %Tesla.Env{status: status, body: error_body}} ->
                  Logger.error(
                    "Failed to create transcript: HTTP #{status} - #{inspect(error_body)}"
                  )

                  socket =
                    socket
                    |> assign(:transcript_loading, false)
                    |> put_flash(:error, "Failed to create transcript. Please try again later.")

                  {:noreply, socket}

                {:error, reason} ->
                  Logger.error("Failed to create transcript: #{inspect(reason)}")

                  socket =
                    socket
                    |> assign(:transcript_loading, false)
                    |> put_flash(:error, "Failed to create transcript. Please try again later.")

                  {:noreply, socket}
              end
            else
              socket =
                socket
                |> assign(:transcript_loading, false)
                |> put_flash(
                  :error,
                  "Recording is not ready yet. Please wait for the recording to complete."
                )

              {:noreply, socket}
            end
        end

      {:error, reason} ->
        Logger.error("Failed to get bot info: #{inspect(reason)}")

        socket =
          socket
          |> assign(:transcript_loading, false)
          |> put_flash(:error, "Failed to check recording status. Please try again later.")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open-hubspot-modal", _params, socket) do
    # Check if meeting has transcript
    has_transcript =
      socket.assigns.meeting.meeting_transcript &&
        socket.assigns.meeting.meeting_transcript.content &&
        Map.get(socket.assigns.meeting.meeting_transcript.content || %{}, "data", []) != []

    if has_transcript do
      {:noreply,
       push_patch(socket, to: ~p"/dashboard/meetings/#{socket.assigns.meeting}/hubspot_update")}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Cannot update HubSpot: Meeting must have a transcript.")}
    end
  end

  @impl true
  def handle_info({:refresh_meeting, meeting_id}, socket) do
    # Refresh meeting data (manual refresh)
    refresh_meeting_data(socket, meeting_id)
  end

  def handle_info({:meeting_updated, meeting_id}, socket) do
    # Auto-refresh when meeting is updated via PubSub
    Logger.info("[MeetingLive] Received meeting_updated PubSub message for meeting #{meeting_id}")
    refresh_meeting_data(socket, meeting_id)
  end

  def handle_info({:close_hubspot_modal}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard/meetings/#{socket.assigns.meeting}")}
  end

  def handle_info({:suggestions_generated, component_id, result}, socket) do
    Logger.info(
      "[Show LiveView] Received suggestions_generated message - component_id: #{component_id}, result: #{inspect(result, limit: 1)}"
    )

    # Forward the message to the component with all required assigns
    # component_id should be "hubspot-update-5" (the component's ID)
    component_update_id = "hubspot-update-#{socket.assigns.meeting.id}"

    Logger.info(
      "[Show LiveView] Calling send_update for component #{component_update_id}, received component_id: #{component_id}"
    )

    send_update(SocialScribeWeb.MeetingLive.HubSpotUpdateComponent,
      id: component_update_id,
      meeting: socket.assigns.meeting,
      current_user: socket.assigns.current_user,
      suggestions_result: {component_update_id, result}
    )

    Logger.info("[Show LiveView] send_update completed")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:update_hubspot_contact, contact_id, selected_updates, suggestions}, socket) do
    # Get HubSpot credential
    credential =
      Accounts.list_user_credentials(socket.assigns.current_user, provider: "hubspot")
      |> List.first()

    if credential do
      # Build update properties from selected suggestions
      selected_suggestions =
        suggestions
        |> Enum.filter(fn suggestion ->
          MapSet.member?(selected_updates, suggestion.field_name)
        end)

      # Note: update_properties will be built after filtering read-only properties

      # Ensure all properties exist before updating
      # Get available properties to check which ones need to be created
      case HubSpotApi.get_contact_properties_with_credential(credential) do
        {:ok, available_properties} ->
          property_names =
            available_properties
            |> Enum.map(fn prop -> Map.get(prop, "name") end)
            |> MapSet.new()

          # Standard fields that always exist
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

          valid_properties = MapSet.union(property_names, standard_fields)

          # Filter out read-only properties
          read_only_properties =
            available_properties
            |> Enum.filter(fn prop ->
              Map.get(prop, "modificationMetadata", %{}) |> Map.get("readOnlyValue", false)
            end)
            |> Enum.map(fn prop -> Map.get(prop, "name") end)
            |> MapSet.new()

          # Also filter out HubSpot system properties (they start with "hs_")
          system_properties =
            property_names
            |> Enum.filter(fn name -> String.starts_with?(name, "hs_") end)
            |> MapSet.new()

          read_only_properties = MapSet.union(read_only_properties, system_properties)

          # Filter out read-only properties from selected suggestions
          writable_suggestions =
            selected_suggestions
            |> Enum.reject(fn suggestion ->
              field_name = String.downcase(suggestion.field_name)
              MapSet.member?(read_only_properties, field_name)
            end)

          # Build update properties from writable suggestions (validate emails)
          update_properties =
            writable_suggestions
            |> Enum.reduce(%{}, fn suggestion, acc ->
              # Validate email format if it's an email field
              value =
                if suggestion.field_name == "email" do
                  validate_email(suggestion.suggested_value)
                else
                  suggestion.suggested_value
                end

              if value do
                Map.put(acc, suggestion.field_name, value)
              else
                acc
              end
            end)

          # Find properties that don't exist and create them
          missing_properties =
            writable_suggestions
            |> Enum.filter(fn suggestion ->
              field_name = String.downcase(suggestion.field_name)
              not MapSet.member?(valid_properties, field_name)
            end)

          # Create missing properties
          created_properties =
            missing_properties
            |> Enum.map(fn suggestion ->
              case HubSpotApi.ensure_property_exists_with_credential(
                     credential,
                     suggestion.field_name,
                     suggestion.field_label,
                     suggestion.suggested_value
                   ) do
                {:ok, :created} ->
                  Logger.info("Created HubSpot property: #{suggestion.field_name}")
                  {:ok, suggestion.field_name}

                {:ok, :exists} ->
                  Logger.info("Property already exists: #{suggestion.field_name}")
                  {:ok, suggestion.field_name}

                {:error, reason} ->
                  Logger.error(
                    "Failed to create property #{suggestion.field_name}: #{inspect(reason)}"
                  )

                  {:error, suggestion.field_name, reason}
              end
            end)

          # Check if any property creation failed
          failed_creations = Enum.filter(created_properties, &match?({:error, _, _}, &1))

          if Enum.empty?(failed_creations) do
            # update_properties already excludes read-only properties (built from writable_suggestions)
            # All properties created successfully, proceed with update
            update_contact_with_retry(credential, contact_id, update_properties, socket)
          else
            failed_fields = Enum.map(failed_creations, fn {:error, field, _} -> field end)
            fields_list = Enum.join(failed_fields, ", ")

            {:noreply,
             socket
             |> put_flash(
               :error,
               "Failed to create some custom properties: #{fields_list}. Please try again or create them manually in HubSpot."
             )}
          end

        {:error, reason} ->
          Logger.warning(
            "Failed to fetch properties, attempting update anyway: #{inspect(reason)}"
          )

          # Build update properties from selected suggestions (validate emails)
          update_properties =
            selected_suggestions
            |> Enum.reduce(%{}, fn suggestion, acc ->
              # Validate email format if it's an email field
              value =
                if suggestion.field_name == "email" do
                  validate_email(suggestion.suggested_value)
                else
                  suggestion.suggested_value
                end

              if value do
                Map.put(acc, suggestion.field_name, value)
              else
                acc
              end
            end)

          # Filter out known read-only properties (HubSpot system properties)
          filtered_update_properties =
            update_properties
            |> Enum.reject(fn {field_name, _value} ->
              String.starts_with?(String.downcase(field_name), "hs_")
            end)
            |> Enum.into(%{})

          # If we can't fetch properties, try updating anyway (might work if all are standard fields)
          update_contact_with_retry(credential, contact_id, filtered_update_properties, socket)
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "No HubSpot account connected.")}
    end
  end

  # Validates email format
  defp validate_email(email) when is_binary(email) do
    # Basic email validation - check for @ symbol and basic format
    trimmed = String.trim(email)

    if Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, trimmed) do
      trimmed
    else
      nil
    end
  end

  defp validate_email(_), do: nil

  defp update_contact_with_retry(credential, contact_id, update_properties, socket) do
    # Update contact (token will be refreshed automatically if needed)
    case HubSpotApi.update_contact_with_credential(credential, contact_id, update_properties) do
      {:ok, _updated_contact} ->
        Logger.info("Successfully updated HubSpot contact #{contact_id}")

        {:noreply,
         socket
         |> put_flash(:info, "Successfully updated HubSpot contact!")
         |> push_patch(to: ~p"/dashboard/meetings/#{socket.assigns.meeting}")}

      {:error, {:api_error, 400, error_body}} ->
        Logger.error("Failed to update HubSpot contact: #{inspect(error_body)}")

        # Extract different types of errors
        errors = Map.get(error_body, "errors", [])

        read_only_fields =
          errors
          |> Enum.filter(&(&1["code"] == "READ_ONLY_VALUE"))
          |> Enum.map(fn error ->
            case error do
              %{"context" => %{"propertyName" => [field_name]}} ->
                field_name

              %{"context" => %{"propertyName" => field_name}} when is_binary(field_name) ->
                field_name

              _ ->
                nil
            end
          end)
          |> Enum.filter(&(!is_nil(&1)))

        invalid_emails =
          errors
          |> Enum.filter(&(&1["code"] == "INVALID_EMAIL"))
          |> Enum.map(fn error ->
            case error do
              %{"context" => %{"propertyName" => [field_name]}} ->
                field_name

              %{"context" => %{"propertyName" => field_name}} when is_binary(field_name) ->
                field_name

              _ ->
                nil
            end
          end)
          |> Enum.filter(&(!is_nil(&1)))

        missing_fields =
          errors
          |> Enum.filter(&(&1["code"] == "PROPERTY_DOESNT_EXIST"))
          |> Enum.map(fn error ->
            case error do
              %{"context" => %{"propertyName" => [field_name]}} ->
                field_name

              %{"context" => %{"propertyName" => field_name}} when is_binary(field_name) ->
                field_name

              _ ->
                nil
            end
          end)
          |> Enum.filter(&(!is_nil(&1)))

        error_parts = []

        error_parts =
          if Enum.empty?(read_only_fields),
            do: error_parts,
            else: ["Read-only fields: #{Enum.join(read_only_fields, ", ")}"]

        error_parts =
          if Enum.empty?(invalid_emails),
            do: error_parts,
            else: ["Invalid email format: #{Enum.join(invalid_emails, ", ")}"]

        error_parts =
          if Enum.empty?(missing_fields),
            do: error_parts,
            else: ["Missing fields: #{Enum.join(missing_fields, ", ")}"]

        error_message =
          if Enum.empty?(error_parts) do
            "Failed to update HubSpot contact. Please check the values and try again."
          else
            "Failed to update HubSpot contact. " <> Enum.join(error_parts, ". ")
          end

        {:noreply,
         socket
         |> put_flash(:error, error_message)}

      {:error, reason} ->
        Logger.error("Failed to update HubSpot contact: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to update HubSpot contact. Please try again.")}
    end
  end

  defp refresh_meeting_data(socket, meeting_id) do
    # Refresh meeting data
    meeting = Meetings.get_meeting_with_details(meeting_id)
    {has_recording, recording_status} = check_recording_status(meeting.recall_bot.recall_bot_id)

    # Check if transcript exists but is empty
    transcript_exists_but_empty =
      meeting.meeting_transcript &&
        meeting.meeting_transcript.content &&
        Map.get(meeting.meeting_transcript.content, "data", []) == []

    # Refresh automation results
    automation_results = Automations.list_automation_results_for_meeting(meeting_id)

    socket =
      socket
      |> assign(:meeting, meeting)
      |> assign(:automation_results, automation_results)
      |> assign(:has_recording, has_recording)
      |> assign(:recording_status, recording_status)
      |> assign(:transcript_exists_but_empty, transcript_exists_but_empty)
      |> assign(:participants_loading, false)
      |> assign(:transcript_loading, false)
      |> assign(:email_generating, false)
      |> assign(
        :follow_up_email_form,
        to_form(%{
          "follow_up_email" => meeting.follow_up_email || ""
        })
      )

    {:noreply, socket}
  end

  defp check_recording_status(recall_bot_id) do
    case RecallApi.get_bot(recall_bot_id) do
      {:ok, %Tesla.Env{body: bot_info}} ->
        recordings = Map.get(bot_info, :recordings, [])

        case List.first(recordings) do
          nil ->
            {false, nil}

          recording ->
            recording_status = Map.get(recording, :status, %{})
            {true, Map.get(recording_status, :code)}
        end

      {:error, _reason} ->
        {false, nil}
    end
  end

  defp format_duration(nil), do: "N/A"

  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    cond do
      minutes > 0 && remaining_seconds > 0 -> "#{minutes} min #{remaining_seconds} sec"
      minutes > 0 -> "#{minutes} min"
      seconds > 0 -> "#{seconds} sec"
      true -> "Less than a second"
    end
  end

  defp get_speaker_name(segment) do
    cond do
      # Recall.ai format: participant.name
      Map.has_key?(segment, "participant") ->
        get_in(segment, ["participant", "name"]) || "Unknown Speaker"

      # Alternative format: speaker field
      Map.has_key?(segment, "speaker") ->
        segment["speaker"] || "Unknown Speaker"

      true ->
        "Unknown Speaker"
    end
  end

  defp get_segment_text(segment) do
    words = segment["words"] || []

    Enum.map_join(words, " ", fn word ->
      if is_map(word), do: word["text"] || "", else: ""
    end)
  end

  attr :meeting_transcript, :map, required: true
  attr :has_recording, :boolean, required: true
  attr :recording_status, :string, default: nil
  attr :transcript_loading, :boolean, default: false
  attr :transcript_exists_but_empty, :boolean, default: false

  defp transcript_content(assigns) do
    has_transcript =
      assigns.meeting_transcript &&
        assigns.meeting_transcript.content &&
        Map.get(assigns.meeting_transcript.content, "data") &&
        Enum.any?(Map.get(assigns.meeting_transcript.content, "data"))

    # Show button only if:
    # - No transcript data exists
    # - Recording exists and is done
    # - We haven't already tried creating a transcript (transcript doesn't exist OR exists but isn't empty)
    show_generate_button =
      !has_transcript &&
        assigns.has_recording &&
        assigns.recording_status == "done" &&
        !assigns.transcript_exists_but_empty

    assigns =
      assigns
      |> assign(:has_transcript, has_transcript)
      |> assign(:show_generate_button, show_generate_button)

    ~H"""
    <div class="bg-white shadow-xl rounded-lg p-6 md:p-8">
      <div class="flex justify-between items-center mb-4">
        <h2 class="text-2xl font-semibold text-slate-700">
          Meeting Transcript
        </h2>
        <%= if @show_generate_button do %>
          <button
            phx-click="create-transcript"
            disabled={@transcript_loading}
            class={[
              "inline-flex items-center justify-center px-4 py-2 border border-transparent text-sm font-medium rounded-md",
              "text-white bg-indigo-600 hover:bg-indigo-700",
              "disabled:opacity-50 disabled:cursor-not-allowed"
            ]}
          >
            <%= if @transcript_loading do %>
              <svg
                class="animate-spin -ml-1 mr-2 h-4 w-4 text-white"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                >
                </circle>
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                >
                </path>
              </svg>
              Creating...
            <% else %>
              Generate Transcript
            <% end %>
          </button>
        <% end %>
      </div>
      <div class="prose prose-sm sm:prose max-w-none h-96 overflow-y-auto pr-2">
        <%= if @has_transcript do %>
          <div :for={segment <- @meeting_transcript.content["data"]} class="mb-3">
            <p>
              <span class="font-semibold text-indigo-600">
                {get_speaker_name(segment)}:
              </span>
              {get_segment_text(segment)}
            </p>
          </div>
        <% else %>
          <div class="text-center py-8">
            <%= cond do %>
              <% !@has_recording -> %>
                <p class="text-slate-500 text-lg mb-2">No recording found</p>
                <p class="text-slate-400 text-sm">
                  This meeting does not have a recording available.
                </p>
              <% @recording_status != "done" -> %>
                <p class="text-slate-500 text-lg mb-2">Recording in progress</p>
                <p class="text-slate-400 text-sm">
                  The recording is still being processed. Please check back later.
                </p>
              <% @transcript_exists_but_empty -> %>
                <p class="text-slate-500 text-lg mb-2">Transcript unavailable</p>
                <p class="text-slate-400 text-sm">
                  A transcript was created for this meeting but no transcript data was available from the recording.
                </p>
              <% true -> %>
                <p class="text-slate-500 text-lg mb-2">Transcript not available</p>
                <p class="text-slate-400 text-sm mb-4">
                  Click the "Generate Transcript" button above to create a transcript for this meeting.
                </p>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
