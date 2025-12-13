defmodule SocialScribe.Workers.BotStatusPoller do
  use Oban.Worker, queue: :polling, max_attempts: 3

  alias SocialScribe.Bots
  alias SocialScribe.RecallApi
  alias SocialScribe.Meetings

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    bots_to_poll = Bots.list_pending_bots()
    done_bots_without_meetings = Bots.list_done_bots_without_meetings()

    if Enum.any?(bots_to_poll) do
      Logger.info("Polling #{Enum.count(bots_to_poll)} pending Recall.ai bots...")
    end

    if Enum.any?(done_bots_without_meetings) do
      Logger.info("Processing #{Enum.count(done_bots_without_meetings)} done bots without meetings...")
    end

    # Process pending bots (check status and update)
    for bot_record <- bots_to_poll do
      poll_and_process_bot(bot_record)
    end

    # Process done bots that don't have meetings yet
    for bot_record <- done_bots_without_meetings do
      Logger.info("Bot #{bot_record.recall_bot_id} is done but has no meeting record. Creating meeting...")

      # Get fresh bot info from API
      case RecallApi.get_bot(bot_record.recall_bot_id) do
        {:ok, %Tesla.Env{body: bot_api_info}} ->
          process_completed_bot(bot_record, bot_api_info)

        {:error, reason} ->
          Logger.error("Failed to get bot info for #{bot_record.recall_bot_id}: #{inspect(reason)}")
      end
    end

    # Check and update transcripts for meetings with empty transcripts
    alias SocialScribe.Workers.TranscriptCreator
    TranscriptCreator.check_and_update_transcripts()

    :ok
  end

  defp poll_and_process_bot(bot_record) do
    case RecallApi.get_bot(bot_record.recall_bot_id) do
      {:ok, %Tesla.Env{status: http_status, body: bot_api_info}} ->
        if http_status not in 200..299 do
          Logger.error(
            "Bot #{bot_record.recall_bot_id} returned HTTP #{http_status}: #{inspect(bot_api_info)}"
          )
          Bots.update_recall_bot(bot_record, %{status: "polling_error"})
        else
          status_changes = Map.get(bot_api_info, :status_changes, [])

          new_status =
            cond do
              is_nil(status_changes) ->
                Logger.warning("Bot #{bot_record.recall_bot_id} has nil status_changes")
                "pending"

              Enum.empty?(status_changes) ->
                # Check if bot was cancelled or never started
                # If recordings exist but are empty, bot might be done
                recordings = Map.get(bot_api_info, :recordings, [])
                if Enum.empty?(recordings) do
                  Logger.debug("Bot #{bot_record.recall_bot_id} has no status_changes and no recordings - keeping as pending")
                  "pending"
                else
                  # Has recordings but no status changes - check recording status
                  recording = List.first(recordings)
                  case Map.get(recording, :status) do
                    %{code: code} -> code
                    _ -> "pending"
                  end
                end

              is_list(status_changes) ->
                case List.last(status_changes) do
                  nil ->
                    Logger.warning("Bot #{bot_record.recall_bot_id} status_changes list is empty")
                    "pending"

                  last_status ->
                    Map.get(last_status, :code, "pending")
                end

              true ->
                Logger.warning("Bot #{bot_record.recall_bot_id} has unexpected status_changes format: #{inspect(status_changes)}")
                "pending"
            end

          Logger.debug("Bot #{bot_record.recall_bot_id}: #{bot_record.status} -> #{new_status}")

          {:ok, updated_bot_record} = Bots.update_recall_bot(bot_record, %{status: new_status})

          if new_status == "done" &&
               is_nil(Meetings.get_meeting_by_recall_bot_id(updated_bot_record.id)) do
            Logger.info("Processing completed bot #{bot_record.recall_bot_id}")
            process_completed_bot(updated_bot_record, bot_api_info)
          else
            if new_status != bot_record.status do
              Logger.info("Bot #{bot_record.recall_bot_id} status updated to: #{new_status}")
            else
              Logger.debug("Bot #{bot_record.recall_bot_id} status unchanged: #{new_status}")
            end
          end
        end

      {:error, reason} ->
        Logger.error(
          "Failed to poll bot status for #{bot_record.recall_bot_id}: #{inspect(reason)}"
        )

        Bots.update_recall_bot(bot_record, %{status: "polling_error"})
    end
  end

  defp process_completed_bot(bot_record, bot_api_info) do
    Logger.info("Bot #{bot_record.recall_bot_id} is done. Processing recording...")

    # Get recording ID from bot info
    recordings = Map.get(bot_api_info, :recordings, [])

    case List.first(recordings) do
      nil ->
        Logger.warning("Bot #{bot_record.recall_bot_id} has no recordings")
        # Create meeting without transcript
        create_meeting_without_transcript(bot_record, bot_api_info)

      recording ->
        recording_id = Map.get(recording, :id)
        recording_status = Map.get(recording, :status, %{})

        # Check if recording is done
        if Map.get(recording_status, :code) == "done" do
          Logger.info("Recording #{recording_id} is done. Creating transcript...")

          # Create async transcript
          case RecallApi.create_transcript(recording_id) do
            {:ok, %Tesla.Env{status: status, body: transcript_response}} when status in 200..299 ->
              transcript_id = Map.get(transcript_response, :id)
              Logger.info("Transcript creation initiated. Transcript ID: #{transcript_id}")

              # Check if transcript is already done (unlikely but possible)
              case check_and_fetch_transcript(transcript_id) do
                {:ok, transcript_data} ->
                  Logger.info("Transcript #{transcript_id} is ready. Creating meeting...")
                  create_meeting_with_transcript(bot_record, bot_api_info, transcript_data)

                {:pending, transcript_id} ->
                  Logger.info("Transcript #{transcript_id} is still processing. Creating meeting without transcript for now.")
                  # Create meeting record, transcript will be fetched later
                  create_meeting_without_transcript(bot_record, bot_api_info)

                {:error, reason} ->
                  Logger.error("Failed to check transcript status: #{inspect(reason)}")
                  create_meeting_without_transcript(bot_record, bot_api_info)
              end

            {:ok, %Tesla.Env{status: status, body: error_body}} ->
              Logger.error("Failed to create transcript: HTTP #{status} - #{inspect(error_body)}")
              create_meeting_without_transcript(bot_record, bot_api_info)

            {:error, reason} ->
              Logger.error("Failed to create transcript: #{inspect(reason)}")
              create_meeting_without_transcript(bot_record, bot_api_info)
          end
        else
          Logger.info("Recording #{recording_id} is not done yet (status: #{Map.get(recording_status, :code)}). Waiting...")
          # Recording not done yet, skip for now
          :ok
        end
    end
  end

  defp check_and_fetch_transcript(transcript_id) do
    case RecallApi.get_transcript(transcript_id) do
      {:ok, %Tesla.Env{status: status, body: transcript_info}} when status in 200..299 ->
        transcript_status = Map.get(transcript_info, :status, %{})

        case Map.get(transcript_status, :code) do
          "done" ->
            # Transcript is ready, download it
            download_url = get_in(transcript_info, [:data, :download_url])

            if download_url do
              case download_transcript_from_url(download_url) do
                {:ok, transcript_data} ->
                  {:ok, transcript_data}

                {:error, reason} ->
                  Logger.error("Failed to download transcript from URL: #{inspect(reason)}")
                  {:error, :download_failed}
              end
            else
              Logger.warning("Transcript #{transcript_id} is done but has no download URL")
              {:error, :no_download_url}
            end

          _ ->
            # Transcript still processing
            {:pending, transcript_id}
        end

      {:error, reason} ->
        {:error, reason}
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

  defp create_meeting_with_transcript(bot_record, bot_api_info, transcript_data) do
    case Meetings.create_meeting_from_recall_data(bot_record, bot_api_info, transcript_data) do
      {:ok, meeting} ->
        Logger.info("Successfully created meeting record #{meeting.id} from bot #{bot_record.recall_bot_id}")

        # Reset transcript attempts if we have transcript data, otherwise set to 1
        has_transcript_data = Enum.any?(transcript_data || [])
        transcript_attempts = if has_transcript_data, do: 0, else: 1

        Meetings.update_meeting(meeting, %{transcript_attempts: transcript_attempts})

        # Only enqueue AI content generation if we have transcript data
        if has_transcript_data do
          SocialScribe.Workers.AIContentGenerationWorker.new(%{meeting_id: meeting.id})
          |> Oban.insert()

          Logger.info("Enqueued AI content generation for meeting #{meeting.id}")
        end

        {:ok, meeting}

      {:error, reason} ->
        Logger.error("Failed to create meeting record from bot #{bot_record.recall_bot_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_meeting_without_transcript(bot_record, bot_api_info) do
    # Create meeting with empty transcript - transcript can be fetched later
    # create_meeting_with_transcript will handle setting transcript_attempts to 1
    create_meeting_with_transcript(bot_record, bot_api_info, [])
  end
end
