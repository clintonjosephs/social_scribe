defmodule SocialScribeWeb.MeetingLive.HubSpotUpdateComponent do
  @moduledoc """
  LiveView component for reviewing and submitting HubSpot contact updates.

  This component displays:
  - A search/select control for choosing a HubSpot contact
  - AI-generated suggestions for contact updates
  - A review interface showing existing vs suggested values
  - Ability to select/deselect updates before submitting
  """

  use SocialScribeWeb, :live_component

  alias SocialScribe.{HubSpotApi, HubSpotAISuggestions, Accounts, Meetings}
  require Logger

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h2 class="text-2xl font-semibold text-slate-800 mb-2">
          Update in eMoney
        </h2>
        <p class="text-slate-600">
          Here are suggested updates to sync with your integrations based on this meeting.
        </p>
      </div>
      
    <!-- Contact Selection -->
      <div class="mb-6">
        <label class="block text-sm font-medium text-slate-700 mb-2">
          Select Contact
        </label>
        <div class="relative">
          <input
            type="text"
            phx-target={@myself}
            phx-debounce="300"
            phx-keyup="search-contacts"
            phx-change="search-contacts"
            value={@search_query}
            placeholder="Search contacts..."
            class="w-full px-4 py-2 border border-slate-300 rounded-md focus:ring-2 focus:border-[rgb(9,114,242)]"
            style="--tw-ring-color: rgb(9, 114, 242);"
          />
          <%= if @searching_contacts do %>
            <div class="absolute right-3 top-2.5">
              <svg
                class="animate-spin h-5 w-5"
                style="color: rgb(9, 114, 242);"
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
            </div>
          <% end %>
        </div>
        
    <!-- Contact Dropdown -->
        <%= if @show_contact_dropdown && length(@contact_results) > 0 do %>
          <div class="mt-2 bg-white border border-slate-200 rounded-md shadow-lg max-h-60 overflow-y-auto">
            <ul class="py-1">
              <li
                :for={contact <- @contact_results}
                phx-click="select-contact"
                phx-value-contact-id={contact["id"]}
                phx-target={@myself}
                class="px-4 py-2 hover:bg-gray-50 cursor-pointer flex items-center gap-2"
              >
                <div
                  class="flex-shrink-0 w-8 h-8 rounded-full flex items-center justify-center font-semibold text-sm"
                  style="background-color: rgba(9, 114, 242, 0.1); color: rgb(9, 114, 242);"
                >
                  {get_contact_initials(contact)}
                </div>
                <div class="flex-1">
                  <div class="font-medium text-slate-700">
                    {get_contact_display_name(contact)}
                  </div>
                  <%= if get_contact_email(contact) do %>
                    <div class="text-sm text-slate-500">
                      {get_contact_email(contact)}
                    </div>
                  <% end %>
                </div>
              </li>
            </ul>
          </div>
        <% end %>
        
    <!-- Selected Contact Display -->
        <%= if @selected_contact do %>
          <div class="mt-3 flex items-center gap-2 p-3 bg-slate-50 rounded-md">
            <div
              class="flex-shrink-0 w-10 h-10 rounded-full flex items-center justify-center font-semibold"
              style="background-color: rgba(9, 114, 242, 0.1); color: rgb(9, 114, 242);"
            >
              {get_contact_initials(@selected_contact)}
            </div>
            <div class="flex-1">
              <div class="font-medium text-slate-700">
                {get_contact_display_name(@selected_contact)}
              </div>
              <%= if get_contact_email(@selected_contact) do %>
                <div class="text-sm text-slate-500">
                  {get_contact_email(@selected_contact)}
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
      
    <!-- Suggestions Loading -->
      <%= if @generating_suggestions do %>
        <div class="text-center py-8">
          <svg
            class="animate-spin h-8 w-8 mx-auto mb-2"
            style="color: rgb(9, 114, 242);"
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
          >
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
            </circle>
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            >
            </path>
          </svg>
          <p class="text-slate-600">Generating suggestions...</p>
        </div>
      <% end %>
      
    <!-- Suggestions Display -->
      <%= if @suggestions && length(@suggestions) > 0 do %>
        <div class="space-y-4 mb-6">
          <!-- Group suggestions by object/field group -->
          <%= for {group_name, group_suggestions} <- group_suggestions(@suggestions) do %>
            <div
              class="border border-slate-200 rounded-lg p-4"
              style="background-color: rgb(245, 248, 247);"
            >
              <!-- Group Header -->
              <div class="flex items-center justify-between mb-3">
                <div class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    checked={all_group_selected?(group_suggestions, @selected_updates)}
                    phx-click="toggle-group"
                    phx-value-group={group_name}
                    phx-target={@myself}
                    class="w-4 h-4 border-slate-300 rounded focus:ring-[rgb(9,114,242)]"
                    style="accent-color: rgb(9, 114, 242);"
                  />
                  <h3 class="text-base font-semibold text-slate-700">
                    {group_name}
                  </h3>
                </div>
                <div class="flex items-center gap-3">
                  <span
                    class="text-xs px-2 py-1 rounded"
                    style="background-color: rgb(225, 229, 233); color: rgb(71, 85, 105);"
                  >
                    {count_selected_in_group(group_suggestions, @selected_updates)} update{if count_selected_in_group(
                                                                                                group_suggestions,
                                                                                                @selected_updates
                                                                                              ) != 1,
                                                                                              do: "s",
                                                                                              else: ""} selected
                  </span>
                  <button
                    phx-click="toggle-group-details"
                    phx-value-group={group_name}
                    phx-target={@myself}
                    class="text-xs text-gray-600 hover:text-gray-800"
                  >
                    <%= if Map.get(@expanded_groups, group_name, true) do %>
                      Hide details
                    <% else %>
                      Show details
                    <% end %>
                  </button>
                </div>
              </div>
              
    <!-- Group Suggestions -->
              <%= if Map.get(@expanded_groups, group_name, true) do %>
                <div class="space-y-3">
                  <%= for suggestion <- group_suggestions do %>
                    <div>
                      <div class="text-sm font-medium text-slate-700 mb-2 ml-7">
                        {suggestion.field_label}
                      </div>
                      <div class="flex items-center gap-3">
                        <input
                          type="checkbox"
                          checked={MapSet.member?(@selected_updates, suggestion.field_name)}
                          phx-click="toggle-update"
                          phx-value-field={suggestion.field_name}
                          phx-target={@myself}
                          class="w-4 h-4 border-slate-300 rounded focus:ring-[rgb(9,114,242)]"
                          style="accent-color: rgb(9, 114, 242);"
                        />
                        <!-- Existing Value -->
                        <input
                          type="text"
                          value={format_value(suggestion.existing_value)}
                          readonly
                          class={[
                            "flex-1 px-3 py-1.5 text-sm bg-slate-50 border border-slate-200 rounded text-slate-600",
                            if(suggestion.existing_value && suggestion.existing_value != "",
                              do: "line-through",
                              else: ""
                            )
                          ]}
                        />
                        <!-- Arrow -->
                        <svg
                          class="w-8 h-5 text-slate-400 flex-shrink-0"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2.5"
                            d="M4 12h16m0 0l-6-6m6 6l-6 6"
                          >
                          </path>
                        </svg>
                        <!-- Suggested Value -->
                        <input
                          type="text"
                          value={suggestion.suggested_value}
                          class="flex-1 px-3 py-1.5 text-sm bg-white border border-slate-200 rounded text-slate-800"
                        />
                      </div>

                      <%= if suggestion.transcript_reference do %>
                        <p class="text-xs text-slate-500 mb-2">
                          {suggestion.transcript_reference}
                        </p>
                      <% end %>

                      <a href="#" class="text-xs hover:underline" style="color: rgb(9, 114, 242);">
                        Update mapping
                      </a>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
      
    <!-- Empty State -->
      <%= if @selected_contact && @suggestions && length(@suggestions) == 0 && !@generating_suggestions do %>
        <div class="text-center py-8 text-slate-500">
          <p>No suggested updates found for this contact.</p>
        </div>
      <% end %>
      
    <!-- Footer -->
      <div class="flex items-center justify-between pt-4 -mx-14 px-14 border-t border-slate-200">
        <div class="text-sm text-slate-600">
          <%= if @selected_updates && MapSet.size(@selected_updates) > 0 do %>
            {count_objects(@suggestions, @selected_updates)} objects, {MapSet.size(@selected_updates)} fields in {count_integrations(
              @suggestions,
              @selected_updates
            )} integrations selected to update
          <% else %>
            Select updates to sync
          <% end %>
        </div>
        <div class="flex gap-3">
          <button
            type="button"
            phx-click="cancel"
            phx-target={@myself}
            class="px-4 py-2 text-black border border-gray-300 rounded-lg hover:bg-gray-50"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="update-hubspot"
            phx-target={@myself}
            disabled={!@selected_contact || MapSet.size(@selected_updates) == 0 || @updating}
            class={[
              "px-4 py-2 rounded-lg text-white text-sm",
              if(@selected_contact && MapSet.size(@selected_updates) > 0 && !@updating,
                do: "hover:opacity-90",
                else: "bg-slate-300 text-slate-500 cursor-not-allowed"
              )
            ]}
            style={
              if(@selected_contact && MapSet.size(@selected_updates) > 0 && !@updating,
                do: "background-color: rgb(34, 197, 94);",
                else: ""
              )
            }
          >
            <%= if @updating do %>
              Updating...
            <% else %>
              Update eMoney
            <% end %>
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("search-contacts", %{"key" => "Enter"}, socket) do
    # Don't search on Enter key
    {:noreply, socket}
  end

  def handle_event("search-contacts", %{"value" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply, assign(socket, contact_results: [], show_contact_dropdown: false)}
    else
      search_contacts(socket, query)
    end
  end

  def handle_event("select-contact", %{"contact-id" => contact_id}, socket) do
    Logger.info("[HubSpot Component] select-contact event received for contact_id: #{contact_id}")

    # Find the contact in results
    contact =
      Enum.find(socket.assigns.contact_results, fn c -> c["id"] == contact_id end)

    if contact do
      Logger.info(
        "[HubSpot Component] Contact found: #{inspect(get_contact_display_name(contact))}"
      )

      socket =
        socket
        |> assign(selected_contact: contact)
        |> assign(selected_contact_id: contact_id)
        |> assign(show_contact_dropdown: false)
        |> assign(search_query: get_contact_display_name(contact))
        |> assign(generating_suggestions: true)

      # Generate suggestions asynchronously
      # Extract necessary data before passing to Task (socket is process-specific)
      pid = self()
      # Use the component's ID (like "hubspot-update-5"), not the LiveView socket ID
      component_id = socket.id
      meeting_id = socket.assigns.meeting.id
      credential = socket.assigns.hubspot_credential

      Logger.info(
        "[HubSpot Component] Starting async task - meeting_id: #{meeting_id}, component_id: #{component_id}, socket.id: #{socket.id}, has_credential: #{not is_nil(credential)}"
      )

      Task.start(fn ->
        Logger.info("[HubSpot Component] Task started for contact_id: #{contact_id}")
        result = generate_suggestions_async(meeting_id, credential, contact_id)

        Logger.info(
          "[HubSpot Component] Task completed with result: #{inspect(result, limit: 2)}"
        )

        send(pid, {:suggestions_generated, component_id, result})

        Logger.info(
          "[HubSpot Component] Message sent to pid: #{inspect(pid)} with component_id: #{component_id}"
        )
      end)

      {:noreply, socket}
    else
      Logger.warning(
        "[HubSpot Component] Contact not found in results for contact_id: #{contact_id}"
      )

      {:noreply, socket}
    end
  end

  def handle_event("toggle-update", %{"field" => field_name}, socket) do
    selected_updates =
      if MapSet.member?(socket.assigns.selected_updates, field_name) do
        MapSet.delete(socket.assigns.selected_updates, field_name)
      else
        MapSet.put(socket.assigns.selected_updates, field_name)
      end

    {:noreply, assign(socket, selected_updates: selected_updates)}
  end

  def handle_event("toggle-group", %{"group" => group_name}, socket) do
    group_suggestions = get_group_suggestions(socket.assigns.suggestions, group_name)
    all_selected = all_group_selected?(group_suggestions, socket.assigns.selected_updates)

    selected_updates =
      if all_selected do
        # Deselect all in group
        Enum.reduce(group_suggestions, socket.assigns.selected_updates, fn suggestion, acc ->
          MapSet.delete(acc, suggestion.field_name)
        end)
      else
        # Select all in group
        Enum.reduce(group_suggestions, socket.assigns.selected_updates, fn suggestion, acc ->
          MapSet.put(acc, suggestion.field_name)
        end)
      end

    {:noreply, assign(socket, selected_updates: selected_updates)}
  end

  def handle_event("toggle-group-details", %{"group" => group_name}, socket) do
    expanded_groups =
      Map.update(
        socket.assigns.expanded_groups,
        group_name,
        false,
        &(!&1)
      )

    {:noreply, assign(socket, expanded_groups: expanded_groups)}
  end

  def handle_event("cancel", _params, socket) do
    send(self(), {:close_hubspot_modal})
    {:noreply, socket}
  end

  def handle_event("update-hubspot", _params, socket) do
    if socket.assigns.selected_contact_id && MapSet.size(socket.assigns.selected_updates) > 0 do
      send(
        self(),
        {:update_hubspot_contact, socket.assigns.selected_contact_id,
         socket.assigns.selected_updates, socket.assigns.suggestions}
      )

      {:noreply, assign(socket, updating: true)}
    else
      {:noreply, socket}
    end
  end

  # Helper function to generate suggestions asynchronously
  # Takes extracted values instead of socket to avoid process-specific issues
  defp generate_suggestions_async(meeting_id, credential, contact_id) do
    Logger.info(
      "[HubSpot Component] generate_suggestions_async called - meeting_id: #{meeting_id}, contact_id: #{contact_id}"
    )

    case credential do
      nil ->
        Logger.error("[HubSpot Component] No credential found")
        {:error, :no_credential}

      credential ->
        Logger.info("[HubSpot Component] Fetching meeting with details...")
        # Ensure meeting has transcript and participants loaded
        meeting = Meetings.get_meeting_with_details(meeting_id)

        if is_nil(meeting) do
          Logger.error("[HubSpot Component] Meeting not found for id: #{meeting_id}")
          {:error, :meeting_not_found}
        else
          Logger.info(
            "[HubSpot Component] Meeting found - has_transcript: #{not is_nil(meeting.meeting_transcript)}, has_participants: #{length(meeting.meeting_participants || [])}"
          )

          Logger.info("[HubSpot Component] Fetching HubSpot contact...")

          case HubSpotApi.get_contact_with_credential(credential, contact_id) do
            {:ok, contact} ->
              Logger.info(
                "[HubSpot Component] Contact fetched successfully, fetching available properties..."
              )

              # Fetch available HubSpot properties to validate suggestions
              available_properties =
                case HubSpotApi.get_contact_properties_with_credential(credential) do
                  {:ok, props} ->
                    props

                  {:error, _} ->
                    Logger.warning(
                      "[HubSpot Component] Failed to fetch properties, proceeding without validation"
                    )

                    nil
                end

              Logger.info(
                "[HubSpot Component] Generating suggestions with #{if available_properties, do: length(available_properties), else: 0} available properties..."
              )

              result =
                HubSpotAISuggestions.generate_suggestions(meeting, contact, available_properties)

              Logger.info(
                "[HubSpot Component] Suggestions generated - result: #{inspect(result, limit: 1)}"
              )

              result

            {:error, reason} ->
              Logger.error("[HubSpot Component] Failed to fetch contact: #{inspect(reason)}")
              {:error, {:fetch_contact_failed, reason}}
          end
        end
    end
  end

  @impl true
  def update(assigns, socket) do
    # Ensure assigns is always a map
    assigns = assigns || %{}

    Logger.info(
      "[HubSpot Component] update/2 called - socket.id: #{socket.id}, has_suggestions_result: #{Map.has_key?(assigns, :suggestions_result)}, has_meeting: #{Map.has_key?(assigns, :meeting)}, assigns keys: #{inspect(Map.keys(assigns))}"
    )

    # Handle suggestions result if present
    # Map.pop returns {value, updated_map}, so we need to get the value first, then the updated map
    {suggestions_result, assigns} = Map.pop(assigns, :suggestions_result, nil)

    Logger.info(
      "[HubSpot Component] After pop - suggestions_result present: #{not is_nil(suggestions_result)}"
    )

    # Ensure meeting has transcript and participants preloaded
    # Use existing meeting from socket if not in assigns (for send_update calls)
    meeting =
      cond do
        Map.has_key?(assigns, :meeting) && assigns.meeting ->
          Logger.info("[HubSpot Component] Loading meeting from assigns: #{assigns.meeting.id}")
          Meetings.get_meeting_with_details(assigns.meeting.id)

        socket.assigns[:meeting] ->
          Logger.info(
            "[HubSpot Component] Loading meeting from socket: #{socket.assigns.meeting.id}"
          )

          Meetings.get_meeting_with_details(socket.assigns.meeting.id)

        true ->
          Logger.warning("[HubSpot Component] No meeting found in assigns or socket")
          nil
      end

    # Get current_user from assigns or socket
    current_user = assigns[:current_user] || socket.assigns[:current_user]

    # Preserve existing state (selected_contact, suggestions, etc.) unless explicitly overridden
    socket =
      socket
      |> assign(assigns)
      |> assign(:meeting, meeting)
      |> assign_new(:search_query, fn -> socket.assigns[:search_query] || "" end)
      |> assign_new(:contact_results, fn -> socket.assigns[:contact_results] || [] end)
      |> assign_new(:show_contact_dropdown, fn ->
        socket.assigns[:show_contact_dropdown] || false
      end)
      |> assign_new(:searching_contacts, fn -> socket.assigns[:searching_contacts] || false end)
      |> assign_new(:selected_contact, fn -> socket.assigns[:selected_contact] end)
      |> assign_new(:selected_contact_id, fn -> socket.assigns[:selected_contact_id] end)
      |> assign_new(:suggestions, fn -> socket.assigns[:suggestions] || [] end)
      |> assign_new(:generating_suggestions, fn ->
        socket.assigns[:generating_suggestions] || false
      end)
      |> assign_new(:selected_updates, fn -> socket.assigns[:selected_updates] || MapSet.new() end)
      |> assign_new(:expanded_groups, fn -> socket.assigns[:expanded_groups] || %{} end)
      |> assign_new(:updating, fn -> socket.assigns[:updating] || false end)
      |> assign_new(:hubspot_credential, fn ->
        socket.assigns[:hubspot_credential] ||
          if current_user, do: get_hubspot_credential(current_user), else: nil
      end)

    # Process suggestions result if present
    socket =
      if suggestions_result do
        Logger.info(
          "[HubSpot Component] Processing suggestions_result - socket.id: #{socket.id}, suggestions_result: #{inspect(suggestions_result, limit: 1)}"
        )

        {component_id, result} = suggestions_result

        Logger.info(
          "[HubSpot Component] Component ID match check - expected: #{component_id}, actual socket.id: #{socket.id}, match: #{socket.id == component_id}"
        )

        # Only process if this message is for this component instance
        # socket.id is the component's ID (e.g., "hubspot-update-5")
        if socket.id == component_id do
          Logger.info("[HubSpot Component] Component IDs match, processing result...")

          case result do
            {:ok, suggestions} ->
              Logger.info("[HubSpot Component] Success! Got #{length(suggestions)} suggestions")
              # Auto-select all suggestions initially
              selected_updates =
                suggestions
                |> Enum.map(& &1.field_name)
                |> MapSet.new()

              expanded_groups =
                suggestions
                |> group_suggestions()
                |> Enum.map(fn {group_name, _} -> {group_name, true} end)
                |> Map.new()

              Logger.info(
                "[HubSpot Component] Assigning suggestions to socket - count: #{length(suggestions)}"
              )

              socket
              |> assign(suggestions: suggestions)
              |> assign(selected_updates: selected_updates)
              |> assign(expanded_groups: expanded_groups)
              |> assign(generating_suggestions: false)

            {:error, reason} ->
              Logger.error(
                "[HubSpot Component] Failed to generate suggestions: #{inspect(reason)}"
              )

              error_message = format_error_message(reason)

              socket
              |> put_flash(:error, error_message)
              |> assign(generating_suggestions: false)
              |> assign(:selected_contact, socket.assigns.selected_contact)
              |> assign(:selected_contact_id, socket.assigns.selected_contact_id)
          end
        else
          Logger.warning(
            "[HubSpot Component] Component ID mismatch - ignoring result. Expected: #{component_id}, Got: #{socket.id}"
          )

          Logger.warning(
            "[HubSpot Component] However, processing anyway since we have a result and component might have re-mounted"
          )

          # Process anyway if we have a result - component might have re-mounted
          case result do
            {:ok, suggestions} ->
              Logger.info(
                "[HubSpot Component] Processing suggestions despite ID mismatch - Got #{length(suggestions)} suggestions"
              )

              selected_updates =
                suggestions
                |> Enum.map(& &1.field_name)
                |> MapSet.new()

              expanded_groups =
                suggestions
                |> group_suggestions()
                |> Enum.map(fn {group_name, _} -> {group_name, true} end)
                |> Map.new()

              socket
              |> assign(suggestions: suggestions)
              |> assign(selected_updates: selected_updates)
              |> assign(expanded_groups: expanded_groups)
              |> assign(generating_suggestions: false)

            _ ->
              socket
              |> assign(generating_suggestions: false)
          end
        end
      else
        Logger.info("[HubSpot Component] No suggestions_result to process")
        socket
      end

    Logger.info(
      "[HubSpot Component] Final socket state - generating_suggestions: #{socket.assigns[:generating_suggestions]}, suggestions count: #{length(socket.assigns[:suggestions] || [])}"
    )

    {:ok, socket}
  end

  defp format_error_message(:no_credential),
    do: "No HubSpot account connected. Please connect a HubSpot account in settings."

  defp format_error_message(:meeting_not_found), do: "Meeting not found."

  defp format_error_message({:fetch_contact_failed, reason}),
    do: "Failed to fetch contact details: #{inspect(reason)}"

  defp format_error_message(reason), do: "Failed to generate suggestions: #{inspect(reason)}"

  # Helper functions

  defp search_contacts(socket, query) do
    case socket.assigns.hubspot_credential do
      nil ->
        {:noreply,
         socket
         |> assign(contact_results: [])
         |> assign(show_contact_dropdown: false)
         |> put_flash(:error, "No HubSpot account connected.")}

      credential ->
        socket = assign(socket, searching_contacts: true, show_contact_dropdown: true)

        # Search contacts (token will be refreshed automatically if needed)
        case HubSpotApi.search_contacts_with_credential(credential, query) do
          {:ok, contacts} ->
            {:noreply,
             socket
             |> assign(contact_results: contacts)
             |> assign(searching_contacts: false)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(contact_results: [])
             |> assign(searching_contacts: false)
             |> put_flash(:error, "Failed to search contacts: #{inspect(reason)}")}
        end
    end
  end

  defp get_hubspot_credential(user) do
    Accounts.list_user_credentials(user, provider: "hubspot")
    |> List.first()
  end

  defp get_contact_display_name(contact) do
    props = Map.get(contact, "properties", %{})
    firstname = Map.get(props, "firstname", "")
    lastname = Map.get(props, "lastname", "")

    cond do
      firstname != "" && lastname != "" -> "#{firstname} #{lastname}"
      firstname != "" -> firstname
      lastname != "" -> lastname
      true -> "Unknown Contact"
    end
  end

  defp get_contact_email(contact) do
    contact
    |> Map.get("properties", %{})
    |> Map.get("email")
  end

  defp get_contact_initials(contact) do
    props = Map.get(contact, "properties", %{})
    firstname = Map.get(props, "firstname", "")
    lastname = Map.get(props, "lastname", "")

    initials =
      cond do
        firstname != "" && lastname != "" ->
          String.first(firstname) <> String.first(lastname)

        firstname != "" ->
          String.first(firstname)

        lastname != "" ->
          String.first(lastname)

        true ->
          "?"
      end

    String.upcase(initials)
  end

  defp format_value(nil), do: "No existing value"
  defp format_value(""), do: "No existing value"
  defp format_value(value), do: to_string(value)

  defp group_suggestions(suggestions) do
    # Group suggestions by logical categories
    # Map field names to group names based on common HubSpot field patterns
    suggestions
    |> Enum.group_by(fn s ->
      case s.field_name do
        name when name in ["firstname", "lastname"] -> "Client name"
        name when name in ["phone", "mobilephone"] -> "Phone number"
        name when name in ["email"] -> "Email"
        name when name in ["company"] -> "Company"
        name when name in ["jobtitle"] -> "Job title"
        name when name in ["website"] -> "Website"
        name when name in ["address", "city", "state", "zip", "country"] -> "Address"
        _ -> s.field_label
      end
    end)
  end

  defp get_group_suggestions(suggestions, group_name) do
    group_suggestions(suggestions)
    |> Map.get(group_name, [])
  end

  defp all_group_selected?(group_suggestions, selected_updates) do
    Enum.all?(group_suggestions, fn suggestion ->
      MapSet.member?(selected_updates, suggestion.field_name)
    end)
  end

  defp count_selected_in_group(group_suggestions, selected_updates) do
    Enum.count(group_suggestions, fn suggestion ->
      MapSet.member?(selected_updates, suggestion.field_name)
    end)
  end

  defp count_objects(suggestions, selected_updates) do
    # Count unique groups that have at least one selected update
    suggestions
    |> group_suggestions()
    |> Enum.count(fn {_group_name, group_suggestions} ->
      Enum.any?(group_suggestions, fn s ->
        MapSet.member?(selected_updates, s.field_name)
      end)
    end)
  end

  defp count_integrations(_suggestions, _selected_updates) do
    # For now, we'll return 1 (HubSpot)
    # In a real implementation, you might have multiple integrations
    1
  end
end
