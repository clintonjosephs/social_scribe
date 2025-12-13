defmodule SocialScribeWeb.HomeLive do
  use SocialScribeWeb, :live_view

  alias SocialScribe.Calendar
  alias SocialScribe.CalendarSyncronizer
  alias SocialScribe.Bots

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :sync_calendars)

      # Subscribe to credential expiration notifications
      Phoenix.PubSub.subscribe(
        SocialScribe.PubSub,
        "user:#{socket.assigns.current_user.id}:credentials"
      )
    end

    socket =
      socket
      |> assign(:page_title, "Upcoming Meetings")
      |> assign(:events, Calendar.list_upcoming_events(socket.assigns.current_user))
      |> assign(:loading, true)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_record", %{"id" => event_id}, socket) do
    event = Calendar.get_calendar_event!(event_id)

    {:ok, event} =
      Calendar.update_calendar_event(event, %{record_meeting: not event.record_meeting})

    send(self(), {:schedule_bot, event})

    updated_events =
      Enum.map(socket.assigns.events, fn e ->
        if e.id == event.id, do: event, else: e
      end)

    {:noreply, assign(socket, :events, updated_events)}
  end

  @impl true
  def handle_info({:schedule_bot, event}, socket) do
    if event.record_meeting do
      case Bots.create_and_dispatch_bot(socket.assigns.current_user, event) do
        {:ok, _} ->
          Logger.info("Successfully created bot for event #{event.id}")
        {:error, reason} ->
          Logger.error("Failed to create bot for event #{event.id}: #{inspect(reason)}")
      end
    else
      case Bots.cancel_and_delete_bot(event) do
        {:ok, _} ->
          Logger.info("Successfully cancelled bot for event #{event.id}")
        {:error, reason} ->
          Logger.error("Failed to cancel bot for event #{event.id}: #{inspect(reason)}")
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:sync_calendars, socket) do
    CalendarSyncronizer.sync_events_for_user(socket.assigns.current_user)

    events = Calendar.list_upcoming_events(socket.assigns.current_user)

    socket =
      socket
      |> assign(:events, events)
      |> assign(:loading, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:credential_expired, _credential_id, provider}, socket) do
    provider_name = String.capitalize(provider)

    socket =
      socket
      |> put_flash(
        :error,
        "Your #{provider_name} account connection has expired. Please reconnect in Settings to continue syncing calendar events."
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:credential_updated, _credential_id, provider}, socket) do
    provider_name = String.capitalize(provider)

    socket =
      socket
      |> put_flash(
        :info,
        "#{provider_name} account reconnected successfully."
      )

    {:noreply, socket}
  end
end
