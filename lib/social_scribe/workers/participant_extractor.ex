defmodule SocialScribe.Workers.ParticipantExtractor do
  @moduledoc """
  Worker to extract and add participants from transcript data to existing meetings.
  """

  alias SocialScribe.{Repo, Meetings}
  require Logger

  def extract_participants_for_all_meetings do
    Logger.info("Starting participant extraction for all meetings...")

    meetings =
      Repo.all(Meetings.Meeting)
      |> Repo.preload([:meeting_transcript, :meeting_participants])

    results =
      Enum.map(meetings, fn meeting ->
        extract_participants_for_meeting(meeting)
      end)

    successful = Enum.count(results, fn {status, _} -> status == :ok end)
    skipped = Enum.count(results, fn {status, _} -> status == :skipped end)
    failed = Enum.count(results, fn {status, _} -> status == :error end)

    Logger.info(
      "Participant extraction complete. Successful: #{successful}, Skipped: #{skipped}, Failed: #{failed}"
    )

    results
  end

  def extract_participants_for_meeting(meeting) do
    # Skip if meeting already has participants
    if Enum.any?(meeting.meeting_participants || []) do
      Logger.debug(
        "Meeting #{meeting.id} already has #{length(meeting.meeting_participants)} participants. Skipping."
      )

      {:skipped, "Already has participants"}
    else
      # Check if meeting has transcript
      if meeting.meeting_transcript do
        transcript_content = Map.get(meeting.meeting_transcript.content || %{}, "data", [])

        if Enum.any?(transcript_content) do
          # Extract participants from transcript
          participants = extract_participants_from_transcript(transcript_content)

          if Enum.any?(participants) do
            Logger.info(
              "Extracting #{length(participants)} participants for meeting #{meeting.id}"
            )

            Enum.each(participants, fn participant_data ->
              participant_attrs = %{
                meeting_id: meeting.id,
                recall_participant_id:
                  if(participant_data.id, do: to_string(participant_data.id), else: nil),
                name: participant_data.name || "Unknown",
                is_host: participant_data.is_host || false
              }

              case Meetings.create_meeting_participant(participant_attrs) do
                {:ok, _participant} ->
                  Logger.debug("Created participant: #{participant_attrs.name}")

                {:error, reason} ->
                  Logger.warning("Failed to create participant: #{inspect(reason)}")
              end
            end)

            {:ok, length(participants)}
          else
            Logger.debug("No participants found in transcript for meeting #{meeting.id}")
            {:skipped, "No participants in transcript"}
          end
        else
          Logger.debug("Meeting #{meeting.id} has empty transcript")
          {:skipped, "Empty transcript"}
        end
      else
        Logger.debug("Meeting #{meeting.id} has no transcript")
        {:skipped, "No transcript"}
      end
    end
  end

  defp extract_participants_from_transcript(transcript_data) do
    transcript_data
    |> Enum.map(fn segment ->
      # Handle both atom and string keys
      participant =
        Map.get(segment, :participant) ||
          Map.get(segment, "participant") ||
          Map.get(segment, :speaker) ||
          Map.get(segment, "speaker")

      participant
    end)
    |> Enum.filter(&(!is_nil(&1)))
    |> Enum.uniq_by(fn p ->
      Map.get(p, :id) || Map.get(p, "id") || Map.get(p, :name) || Map.get(p, "name")
    end)
    |> Enum.map(fn p ->
      # Normalize to struct-like map
      %{
        id: Map.get(p, :id) || Map.get(p, "id"),
        name: Map.get(p, :name) || Map.get(p, "name") || "Unknown",
        is_host: Map.get(p, :is_host, Map.get(p, "is_host", false))
      }
    end)
  end
end
