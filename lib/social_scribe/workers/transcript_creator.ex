defmodule SocialScribe.Workers.TranscriptCreator do
  @moduledoc """
  Worker to manually create transcripts for existing recordings.
  This can be run manually via mix task or scheduled job.
  """

  alias SocialScribe.{Repo, Bots, Meetings, RecallApi}
  alias SocialScribe.Meetings.Meeting
  import Ecto.Query
  require Logger

  def create_transcripts_for_all_recordings do
    Logger.info("Starting manual transcript creation for all recordings...")

    all_bots = Repo.all(Bots.RecallBot)

    results =
      Enum.map(all_bots, fn bot ->
        create_transcript_for_bot(bot)
      end)

    successful = Enum.count(results, fn {status, _} -> status == :ok end)
    failed = Enum.count(results, fn {status, _} -> status == :error end)
    skipped = Enum.count(results, fn {status, _} -> status == :skipped end)

    Logger.info(
      "Transcript creation complete. Successful: #{successful}, Failed: #{failed}, Skipped: #{skipped}"
    )

    results
  end

  def create_transcript_for_bot(bot) do
    case RecallApi.get_bot(bot.recall_bot_id) do
      {:ok, %Tesla.Env{body: bot_info}} ->
        recordings = Map.get(bot_info, :recordings, [])

        case List.first(recordings) do
          nil ->
            Logger.warning("Bot #{bot.recall_bot_id} has no recordings")
            {:skipped, "No recordings"}

          recording ->
            recording_id = Map.get(recording, :id)
            recording_status = Map.get(recording, :status, %{})

            if Map.get(recording_status, :code) == "done" do
              # Check if meeting already has transcript
              meeting = Meetings.get_meeting_by_recall_bot_id(bot.id)

              if meeting do
                # Preload transcript association
                meeting = Repo.preload(meeting, :meeting_transcript)

                if meeting.meeting_transcript do
                  transcript_content = Map.get(meeting.meeting_transcript.content || %{}, "data", [])
                  if Enum.any?(transcript_content) do
                    Logger.info(
                      "Bot #{bot.recall_bot_id} already has transcript with #{length(transcript_content)} segments. Skipping."
                    )
                    {:skipped, "Transcript already exists"}
                  else
                    Logger.info("Bot #{bot.recall_bot_id} has empty transcript. Creating new transcript...")
                    create_transcript_for_recording(recording_id, bot.recall_bot_id)
                  end
                else
                  Logger.info("Bot #{bot.recall_bot_id} has meeting but no transcript. Creating transcript...")
                  create_transcript_for_recording(recording_id, bot.recall_bot_id)
                end
              else
                Logger.info("Bot #{bot.recall_bot_id} has no meeting yet. Creating transcript...")
                create_transcript_for_recording(recording_id, bot.recall_bot_id)
              end
            else
              Logger.info(
                "Recording #{recording_id} is not done yet (status: #{Map.get(recording_status, :code)}). Skipping."
              )
              {:skipped, "Recording not done"}
            end
        end

      {:error, reason} ->
        Logger.error("Failed to get bot info for #{bot.recall_bot_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_transcript_for_recording(recording_id, bot_id) do
    Logger.info("Creating transcript for recording #{recording_id} (bot: #{bot_id})...")

    case RecallApi.create_transcript(recording_id) do
      {:ok, %Tesla.Env{status: status, body: transcript_response}} when status in 200..299 ->
        transcript_id = Map.get(transcript_response, :id)
        Logger.info("✓ Successfully created transcript job. Transcript ID: #{transcript_id}")
        {:ok, transcript_id}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        error_msg = "HTTP #{status}: #{inspect(error_body)}"
        Logger.error("✗ Failed to create transcript for recording #{recording_id}: #{error_msg}")

        # Check if transcript already exists (409 conflict)
        if status == 409 do
          Logger.info("Transcript may already exist for this recording. Checking...")
          {:skipped, "Transcript may already exist"}
        else
          {:error, error_msg}
        end

      {:error, reason} ->
        Logger.error("✗ Failed to create transcript for recording #{recording_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @max_transcript_attempts 5

  @doc """
  Checks transcript status and updates meetings when transcripts are ready.
  This should be called periodically to fetch completed transcripts.
  Stops trying after @max_transcript_attempts attempts.
  """
  def check_and_update_transcripts do
    Logger.info("Checking transcript status for all meetings...")

    meetings_with_empty_transcripts =
      from(m in Meeting,
        join: mt in assoc(m, :meeting_transcript),
        where:
          (fragment("?->'data' = '[]'::jsonb OR ?->'data' IS NULL", mt.content, mt.content) or
             is_nil(fragment("?->'data'", mt.content))) and
            (is_nil(m.transcript_attempts) or m.transcript_attempts < @max_transcript_attempts),
        preload: [:meeting_transcript, :recall_bot]
      )
      |> Repo.all()

    if Enum.empty?(meetings_with_empty_transcripts) do
      Logger.info("No meetings with empty transcripts found (or all exceeded max attempts).")
      []
    else
      Logger.info("Found #{Enum.count(meetings_with_empty_transcripts)} meetings with empty transcripts.")

      Enum.map(meetings_with_empty_transcripts, fn meeting ->
        check_transcript_for_meeting(meeting)
      end)
    end
  end

  defp check_transcript_for_meeting(meeting) do
    # Increment attempt counter
    attempts = (meeting.transcript_attempts || 0) + 1

    # Get bot info to find recording
    result =
      case RecallApi.get_bot(meeting.recall_bot.recall_bot_id) do
        {:ok, %Tesla.Env{body: bot_info}} ->
          recordings = Map.get(bot_info, :recordings, [])

          case List.first(recordings) do
            nil ->
              Logger.warning("Meeting #{meeting.id} has no recordings (attempt #{attempts})")
              {:skipped, "No recordings"}

            recording ->
              # Check if transcript exists in media_shortcuts
              media_shortcuts = Map.get(recording, :media_shortcuts, %{})
              transcript_shortcut = Map.get(media_shortcuts, :transcript)

              if transcript_shortcut do
                transcript_id = get_in(transcript_shortcut, [:id])

                if transcript_id do
                  # Check transcript status
                  case RecallApi.get_transcript(transcript_id) do
                    {:ok, %Tesla.Env{status: status, body: transcript_info}} when status in 200..299 ->
                      transcript_status = Map.get(transcript_info, :status, %{})

                      case Map.get(transcript_status, :code) do
                        "done" ->
                          # Transcript is ready, download and update
                          download_url = get_in(transcript_info, [:data, :download_url])

                          if download_url do
                            case download_transcript_from_url(download_url) do
                              {:ok, transcript_data} ->
                                # Reset attempts on success
                                Meetings.update_meeting(meeting, %{transcript_attempts: 0})
                                update_meeting_transcript(meeting, transcript_data)

                              {:error, reason} ->
                                Logger.error(
                                  "Failed to download transcript #{transcript_id}: #{inspect(reason)}"
                                )
                                {:error, reason}
                            end
                          else
                            Logger.warning("Transcript #{transcript_id} has no download URL")
                            {:error, :no_download_url}
                          end

                        _ ->
                          Logger.debug(
                            "Transcript #{transcript_id} still processing (status: #{Map.get(transcript_status, :code)}, attempt #{attempts})"
                          )
                          {:pending, transcript_id}
                      end

                    {:error, reason} ->
                      Logger.error("Failed to get transcript #{transcript_id}: #{inspect(reason)}")
                      {:error, reason}
                  end
                else
                  Logger.debug("No transcript ID found in media_shortcuts for meeting #{meeting.id} (attempt #{attempts})")
                  {:skipped, "No transcript ID"}
                end
              else
                Logger.debug("No transcript shortcut found for meeting #{meeting.id} (attempt #{attempts})")
                {:skipped, "No transcript shortcut"}
              end
          end

        {:error, reason} ->
          Logger.error("Failed to get bot info for meeting #{meeting.id}: #{inspect(reason)}")
          {:error, reason}
      end

    # Update attempt counter (unless we got transcript data)
    case result do
      {:ok, _} ->
        # Success - attempts already reset above
        result

      _ ->
        # Increment attempts and check if we should stop
        Meetings.update_meeting(meeting, %{transcript_attempts: attempts})

        if attempts >= @max_transcript_attempts do
          Logger.warning(
            "Meeting #{meeting.id} has exceeded max transcript attempts (#{@max_transcript_attempts}). Stopping transcript checks."
          )
        end

        result
    end
  end

  defp download_transcript_from_url(url) do
    download_client =
      Tesla.client([
        {Tesla.Middleware.JSON, engine_opts: [keys: :atoms]},
        {Tesla.Middleware.Headers, [{"Accept", "application/json"}]}
      ])

    case Tesla.get(download_client, url) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        transcript_data =
          cond do
            is_list(body) -> body
            is_map(body) -> Map.get(body, :results) || Map.get(body, :data) || []
            true -> []
          end

        {:ok, transcript_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_meeting_transcript(meeting, transcript_data) do
    if Enum.any?(transcript_data) do
      Logger.info(
        "Updating transcript for meeting #{meeting.id} with #{length(transcript_data)} segments"
      )

      case Meetings.update_meeting_transcript(meeting.meeting_transcript, %{
             content: %{data: transcript_data}
           }) do
        {:ok, _updated} ->
          Logger.info("✓ Successfully updated transcript for meeting #{meeting.id}")
          {:ok, meeting.id}

        {:error, reason} ->
          Logger.error("Failed to update transcript for meeting #{meeting.id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.warning("Transcript data is empty for meeting #{meeting.id}")
      {:skipped, "Empty transcript data"}
    end
  end
end
