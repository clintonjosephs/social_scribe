defmodule SocialScribe.Meetings do
  @moduledoc """
  The Meetings context.
  """

  import Ecto.Query, warn: false
  alias SocialScribe.Repo

  alias SocialScribe.Meetings.Meeting
  alias SocialScribe.Meetings.MeetingTranscript
  alias SocialScribe.Meetings.MeetingParticipant
  alias SocialScribe.Bots.RecallBot

  require Logger

  @doc """
  Returns the list of meetings.

  ## Examples

      iex> list_meetings()
      [%Meeting{}, ...]

  """
  def list_meetings do
    Repo.all(Meeting)
  end

  @doc """
  Gets a single meeting.

  Raises `Ecto.NoResultsError` if the Meeting does not exist.

  ## Examples

      iex> get_meeting!(123)
      %Meeting{}

      iex> get_meeting!(456)
      ** (Ecto.NoResultsError)

  """
  def get_meeting!(id), do: Repo.get!(Meeting, id)

  @doc """
  Gets a meeting by recall bot id.

  ## Examples

      iex> get_meeting_by_recall_bot_id(123)
      %Meeting{}

  """
  def get_meeting_by_recall_bot_id(recall_bot_id) do
    Repo.get_by(Meeting, recall_bot_id: recall_bot_id)
  end

  @doc """
  Creates a meeting.

  ## Examples

      iex> create_meeting(%{field: value})
      {:ok, %Meeting{}}

      iex> create_meeting(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_meeting(attrs \\ %{}) do
    %Meeting{}
    |> Meeting.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a meeting.

  ## Examples

      iex> update_meeting(meeting, %{field: new_value})
      {:ok, %Meeting{}}

      iex> update_meeting(meeting, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_meeting(%Meeting{} = meeting, attrs) do
    case meeting
         |> Meeting.changeset(attrs)
         |> Repo.update() do
      {:ok, updated_meeting} = result ->
        # Broadcast meeting update so LiveViews can refresh
        Phoenix.PubSub.broadcast(
          SocialScribe.PubSub,
          "meeting:#{updated_meeting.id}",
          {:meeting_updated, updated_meeting.id}
        )
        result

      error ->
        error
    end
  end

  @doc """
  Deletes a meeting.

  ## Examples

      iex> delete_meeting(meeting)
      {:ok, %Meeting{}}

      iex> delete_meeting(meeting)
      {:error, %Ecto.Changeset{}}

  """
  def delete_meeting(%Meeting{} = meeting) do
    Repo.delete(meeting)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking meeting changes.

  ## Examples

      iex> change_meeting(meeting)
      %Ecto.Changeset{data: %Meeting{}}

  """
  def change_meeting(%Meeting{} = meeting, attrs \\ %{}) do
    Meeting.changeset(meeting, attrs)
  end

  @doc """
  Lists all processed meetings for a user.
  """
  def list_user_meetings(user) do
    from(m in Meeting,
      join: ce in assoc(m, :calendar_event),
      where: ce.user_id == ^user.id,
      order_by: [desc: m.recorded_at],
      preload: [:meeting_transcript, :meeting_participants, :recall_bot]
    )
    |> Repo.all()
  end

  @doc """
  Gets a meeting with its details preloaded.

  ## Examples

      iex> get_meeting_with_details(123)
      %Meeting{}
  """
  def get_meeting_with_details(meeting_id) do
    Meeting
    |> Repo.get(meeting_id)
    |> Repo.preload([:calendar_event, :recall_bot, :meeting_transcript, :meeting_participants])
  end

  alias SocialScribe.Meetings.MeetingTranscript

  @doc """
  Returns the list of meeting_transcripts.

  ## Examples

      iex> list_meeting_transcripts()
      [%MeetingTranscript{}, ...]

  """
  def list_meeting_transcripts do
    Repo.all(MeetingTranscript)
  end

  @doc """
  Gets a single meeting_transcript.

  Raises `Ecto.NoResultsError` if the Meeting transcript does not exist.

  ## Examples

      iex> get_meeting_transcript!(123)
      %MeetingTranscript{}

      iex> get_meeting_transcript!(456)
      ** (Ecto.NoResultsError)

  """
  def get_meeting_transcript!(id), do: Repo.get!(MeetingTranscript, id)

  @doc """
  Creates a meeting_transcript.

  ## Examples

      iex> create_meeting_transcript(%{field: value})
      {:ok, %MeetingTranscript{}}

      iex> create_meeting_transcript(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_meeting_transcript(attrs \\ %{}) do
    case %MeetingTranscript{}
         |> MeetingTranscript.changeset(attrs)
         |> Repo.insert() do
      {:ok, transcript} = result ->
        # Broadcast meeting update so LiveViews can refresh
        if transcript.meeting_id do
          Phoenix.PubSub.broadcast(
            SocialScribe.PubSub,
            "meeting:#{transcript.meeting_id}",
            {:meeting_updated, transcript.meeting_id}
          )
        end
        result

      error ->
        error
    end
  end

  @doc """
  Updates a meeting_transcript.

  ## Examples

      iex> update_meeting_transcript(meeting_transcript, %{field: new_value})
      {:ok, %MeetingTranscript{}}

      iex> update_meeting_transcript(meeting_transcript, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_meeting_transcript(%MeetingTranscript{} = meeting_transcript, attrs) do
    case meeting_transcript
         |> MeetingTranscript.changeset(attrs)
         |> Repo.update() do
      {:ok, transcript} = result ->
        # Broadcast meeting update so LiveViews can refresh
        if transcript.meeting_id do
          Phoenix.PubSub.broadcast(
            SocialScribe.PubSub,
            "meeting:#{transcript.meeting_id}",
            {:meeting_updated, transcript.meeting_id}
          )
        end
        result

      error ->
        error
    end
  end

  @doc """
  Deletes a meeting_transcript.

  ## Examples

      iex> delete_meeting_transcript(meeting_transcript)
      {:ok, %MeetingTranscript{}}

      iex> delete_meeting_transcript(meeting_transcript)
      {:error, %Ecto.Changeset{}}

  """
  def delete_meeting_transcript(%MeetingTranscript{} = meeting_transcript) do
    Repo.delete(meeting_transcript)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking meeting_transcript changes.

  ## Examples

      iex> change_meeting_transcript(meeting_transcript)
      %Ecto.Changeset{data: %MeetingTranscript{}}

  """
  def change_meeting_transcript(%MeetingTranscript{} = meeting_transcript, attrs \\ %{}) do
    MeetingTranscript.changeset(meeting_transcript, attrs)
  end

  alias SocialScribe.Meetings.MeetingParticipant

  @doc """
  Returns the list of meeting_participants.

  ## Examples

      iex> list_meeting_participants()
      [%MeetingParticipant{}, ...]

  """
  def list_meeting_participants do
    Repo.all(MeetingParticipant)
  end

  @doc """
  Gets a single meeting_participant.

  Raises `Ecto.NoResultsError` if the Meeting participant does not exist.

  ## Examples

      iex> get_meeting_participant!(123)
      %MeetingParticipant{}

      iex> get_meeting_participant!(456)
      ** (Ecto.NoResultsError)

  """
  def get_meeting_participant!(id), do: Repo.get!(MeetingParticipant, id)

  @doc """
  Creates a meeting_participant.

  ## Examples

      iex> create_meeting_participant(%{field: value})
      {:ok, %MeetingParticipant{}}

      iex> create_meeting_participant(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_meeting_participant(attrs \\ %{}) do
    case %MeetingParticipant{}
         |> MeetingParticipant.changeset(attrs)
         |> Repo.insert() do
      {:ok, participant} = result ->
        # Broadcast meeting update so LiveViews can refresh
        if participant.meeting_id do
          Phoenix.PubSub.broadcast(
            SocialScribe.PubSub,
            "meeting:#{participant.meeting_id}",
            {:meeting_updated, participant.meeting_id}
          )
        end
        result

      error ->
        error
    end
  end

  @doc """
  Updates a meeting_participant.

  ## Examples

      iex> update_meeting_participant(meeting_participant, %{field: new_value})
      {:ok, %MeetingParticipant{}}

      iex> update_meeting_participant(meeting_participant, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_meeting_participant(%MeetingParticipant{} = meeting_participant, attrs) do
    meeting_participant
    |> MeetingParticipant.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a meeting_participant.

  ## Examples

      iex> delete_meeting_participant(meeting_participant)
      {:ok, %MeetingParticipant{}}

      iex> delete_meeting_participant(meeting_participant)
      {:error, %Ecto.Changeset{}}

  """
  def delete_meeting_participant(%MeetingParticipant{} = meeting_participant) do
    Repo.delete(meeting_participant)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking meeting_participant changes.

  ## Examples

      iex> change_meeting_participant(meeting_participant)
      %Ecto.Changeset{data: %MeetingParticipant{}}

  """
  def change_meeting_participant(%MeetingParticipant{} = meeting_participant, attrs \\ %{}) do
    MeetingParticipant.changeset(meeting_participant, attrs)
  end

  @doc """
  Creates a complete meeting record from Recall.ai bot info and transcript data.
  This should be called when a bot's status is "done".
  """
  def create_meeting_from_recall_data(%RecallBot{} = recall_bot, bot_api_info, transcript_data) do
    calendar_event = Repo.preload(recall_bot, :calendar_event).calendar_event

    Repo.transaction(fn ->
      meeting_attrs = parse_meeting_attrs(calendar_event, recall_bot, bot_api_info)

      {:ok, meeting} = create_meeting(meeting_attrs)

      transcript_attrs = parse_transcript_attrs(meeting, transcript_data)

      {:ok, _transcript} = create_meeting_transcript(transcript_attrs)

      # Extract participants from transcript data (transcripts contain participant info)
      # Also check bot_api_info for direct participant data
      transcript_participants = extract_participants_from_transcript(transcript_data)
      bot_info_participants = extract_participants_from_bot_info(bot_api_info)

      # Merge participants, preferring bot_info data (which has is_host) when IDs match
      # Group by ID and merge data
      all_participants = transcript_participants ++ bot_info_participants

      unique_participants =
        all_participants
        |> Enum.group_by(fn p -> Map.get(p, :id) || Map.get(p, "id") end)
        |> Enum.map(fn {_id, participant_list} ->
          # Merge all participant data, preferring bot_info data (last in list) for is_host
          Enum.reduce(participant_list, %{}, fn participant, acc ->
            Map.merge(acc, participant, fn
              _key, _val1, val2 -> val2  # Prefer later values (bot_info)
            end)
          end)
        end)

      # Create participants and log any errors
      Enum.each(unique_participants, fn participant_data ->
        participant_attrs = parse_participant_attrs(meeting, participant_data)

        case create_meeting_participant(participant_attrs) do
          {:ok, _participant} ->
            Logger.debug("Created participant: #{participant_attrs.name}")

          {:error, changeset} ->
            Logger.error(
              "Failed to create participant #{participant_attrs.name}: #{inspect(changeset.errors)}"
            )
        end
      end)

      updated_meeting = Repo.preload(meeting, [:meeting_transcript, :meeting_participants])

      # Broadcast meeting update so LiveViews can refresh
      Phoenix.PubSub.broadcast(
        SocialScribe.PubSub,
        "meeting:#{updated_meeting.id}",
        {:meeting_updated, updated_meeting.id}
      )

      updated_meeting
    end)
  end

  # --- Private Parser Functions ---

  defp parse_meeting_attrs(calendar_event, recall_bot, bot_api_info) do
    recordings = Map.get(bot_api_info, :recordings) || Map.get(bot_api_info, "recordings") || []
    recording_info = List.first(recordings) || %{}

    completed_at =
      case Map.get(recording_info, :completed_at) || Map.get(recording_info, "completed_at") do
        nil -> nil
        timestamp when is_binary(timestamp) ->
          case DateTime.from_iso8601(timestamp) do
            {:ok, parsed_completed_at, _} -> parsed_completed_at
            _ -> nil
          end
        _ -> nil
      end

    recorded_at =
      case Map.get(recording_info, :started_at) || Map.get(recording_info, "started_at") do
        nil -> nil
        timestamp when is_binary(timestamp) ->
          case DateTime.from_iso8601(timestamp) do
            {:ok, parsed_recorded_at, _} -> parsed_recorded_at
            _ -> nil
          end
        _ -> nil
      end

    duration_seconds =
      if recorded_at && completed_at do
        DateTime.diff(completed_at, recorded_at, :second)
      else
        nil
      end

    title =
      calendar_event.summary || Map.get(bot_api_info, [:meeting_metadata, :title]) ||
        "Recorded Meeting"

    %{
      title: title,
      recorded_at: recorded_at,
      duration_seconds: duration_seconds,
      calendar_event_id: calendar_event.id,
      recall_bot_id: recall_bot.id
    }
  end

  defp parse_transcript_attrs(meeting, transcript_data) do
    # Handle different transcript data formats
    transcript_list =
      cond do
        is_list(transcript_data) -> transcript_data
        is_map(transcript_data) -> Map.get(transcript_data, :data, [])
        true -> []
      end

    language =
      case List.first(transcript_list || []) do
        nil -> "unknown"
        first_segment when is_map(first_segment) -> Map.get(first_segment, :language, "unknown")
        _ -> "unknown"
      end

    %{
      meeting_id: meeting.id,
      content: %{data: transcript_list},
      language: language
    }
  end

  defp extract_participants_from_transcript(transcript_data) do
    # Extract unique participants from transcript segments
    transcript_list =
      cond do
        is_list(transcript_data) -> transcript_data
        is_map(transcript_data) -> Map.get(transcript_data, :data, []) || Map.get(transcript_data, "data", []) || []
        true -> []
      end

    if Enum.empty?(transcript_list) do
      Logger.debug("No transcript data to extract participants from")
      []
    else
      Logger.debug("Extracting participants from #{length(transcript_list)} transcript segments")

      participants =
        transcript_list
        |> Enum.map(fn segment ->
          # Handle different transcript formats:
          # 1. participant/speaker is a map with id/name
          # 2. speaker is a string with separate speaker_id field
          cond do
            # Case 1: participant/speaker is a map
            participant = Map.get(segment, :participant) || Map.get(segment, "participant") ->
              if is_map(participant), do: participant, else: nil

            speaker = Map.get(segment, :speaker) || Map.get(segment, "speaker") ->
              if is_map(speaker) do
                speaker
              else
                # Case 2: speaker is a string, construct participant map from segment
                speaker_id = Map.get(segment, :speaker_id) || Map.get(segment, "speaker_id")
                if is_binary(speaker) or is_integer(speaker_id) do
                  %{
                    id: speaker_id,
                    name: if(is_binary(speaker), do: speaker, else: nil),
                    is_host: Map.get(segment, :is_host, Map.get(segment, "is_host", false))
                  }
                else
                  nil
                end
              end

            true ->
              nil
          end
        end)
        |> Enum.filter(&(!is_nil(&1)))

      Logger.debug("Found #{length(participants)} participant references in transcript")

      unique_participants =
        participants
        |> Enum.uniq_by(fn p ->
          # Use id if available, otherwise use name
          case p do
            %{} = map -> Map.get(map, :id) || Map.get(map, "id") || Map.get(map, :name) || Map.get(map, "name")
            _ -> p
          end
        end)
        |> Enum.map(fn p ->
          # Normalize to atom keys
          case p do
            %{} = map ->
              %{
                id: Map.get(map, :id) || Map.get(map, "id"),
                name: Map.get(map, :name) || Map.get(map, "name") || "Unknown",
                is_host: Map.get(map, :is_host, Map.get(map, "is_host", false))
              }

            _ ->
              %{
                id: nil,
                name: "Unknown",
                is_host: false
              }
          end
        end)

      Logger.debug("Extracted #{length(unique_participants)} unique participants")
      unique_participants
    end
  end

  defp extract_participants_from_bot_info(bot_api_info) do
    # Check for participants in bot_api_info
    participants = Map.get(bot_api_info, :meeting_participants) || Map.get(bot_api_info, "meeting_participants") || []

    Enum.map(participants, fn p ->
      %{
        id: Map.get(p, :id) || Map.get(p, "id"),
        name: Map.get(p, :name) || Map.get(p, "name") || "Unknown",
        is_host: Map.get(p, :is_host, Map.get(p, "is_host", false))
      }
    end)
  end

  defp parse_participant_attrs(meeting, participant_data) do
    participant_id = Map.get(participant_data, :id) || Map.get(participant_data, "id")
    participant_name = Map.get(participant_data, :name) || Map.get(participant_data, "name") || "Unknown"
    is_host = Map.get(participant_data, :is_host, Map.get(participant_data, "is_host", false))

    %{
      meeting_id: meeting.id,
      recall_participant_id: if(participant_id, do: to_string(participant_id), else: nil),
      name: participant_name,
      is_host: is_host
    }
  end

  @doc """
  Generates a prompt for a meeting.
  """
  def generate_prompt_for_meeting(%Meeting{} = meeting) do
    case participants_to_string(meeting.meeting_participants) do
      {:error, :no_participants} ->
        {:error, :no_participants}

      {:ok, participants_string} ->
        case transcript_to_string(meeting.meeting_transcript) do
          {:error, :no_transcript} ->
            {:error, :no_transcript}

          {:ok, transcript_string} ->
            {:ok,
             generate_prompt(
               meeting.title,
               meeting.recorded_at,
               meeting.duration_seconds,
               participants_string,
               transcript_string
             )}
        end
    end
  end

  defp generate_prompt(title, date, duration, participants, transcript) do
    """
    ## Meeting Info:
    title: #{title}
    date: #{date}
    duration: #{duration} seconds

    ### Participants:
    #{participants}

    ### Transcript:
    #{transcript}
    """
  end

  defp participants_to_string(participants) do
    if Enum.empty?(participants) do
      {:error, :no_participants}
    else
      participants_string =
        participants
        |> Enum.map(fn participant ->
          "#{participant.name} (#{if participant.is_host, do: "Host", else: "Participant"})"
        end)
        |> Enum.join("\n")

      {:ok, participants_string}
    end
  end

  defp transcript_to_string(%MeetingTranscript{content: %{"data" => transcript_data}})
       when not is_nil(transcript_data) do
    {:ok, format_transcript_for_prompt(transcript_data)}
  end

  defp transcript_to_string(_), do: {:error, :no_transcript}

  defp format_transcript_for_prompt(transcript_segments) when is_list(transcript_segments) do
    Enum.map_join(transcript_segments, "\n", fn segment ->
      speaker =
        cond do
          # Recall.ai format: participant.name
          Map.has_key?(segment, "participant") ->
            get_in(segment, ["participant", "name"]) || "Unknown Speaker"

          # Alternative format: speaker field
          Map.has_key?(segment, "speaker") ->
            Map.get(segment, "speaker", "Unknown Speaker")

          true ->
            "Unknown Speaker"
        end

      words = Map.get(segment, "words", [])
      text = Enum.map_join(words, " ", fn word -> Map.get(word, "text", "") end)
      "#{speaker}: #{text}"
    end)
  end

  defp format_transcript_for_prompt(_), do: ""
end
