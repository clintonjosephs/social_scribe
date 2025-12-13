defmodule SocialScribe.Recall do
  @moduledoc "The real implementation for the Recall.ai API client."
  @behaviour SocialScribe.RecallApi

  require Logger

  defp client do
    api_key = Application.fetch_env!(:social_scribe, :recall_api_key)
    recall_region = Application.fetch_env!(:social_scribe, :recall_region)

    Tesla.client([
      {Tesla.Middleware.BaseUrl, "https://#{recall_region}.recall.ai/api/v1"},
      {Tesla.Middleware.JSON, engine_opts: [keys: :atoms]},
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Token #{api_key}"},
         {"Content-Type", "application/json"},
         {"Accept", "application/json"}
       ]}
    ])
  end

  @impl SocialScribe.RecallApi
  def create_bot(meeting_url, join_at) do
    # Recall.ai API requires only meeting_url and join_at
    # Transcription is handled automatically by the API
    body = %{
      meeting_url: meeting_url,
      join_at: Timex.format!(join_at, "{ISO:Extended}")
    }

    Tesla.post(client(), "/bot", body)
  end

  @impl SocialScribe.RecallApi
  def update_bot(recall_bot_id, meeting_url, join_at) do
    body = %{
      meeting_url: meeting_url,
      join_at: Timex.format!(join_at, "{ISO:Extended}")
    }

    Tesla.patch(client(), "/bot/#{recall_bot_id}", body)
  end

  @impl SocialScribe.RecallApi
  def delete_bot(recall_bot_id) do
    Tesla.delete(client(), "/bot/#{recall_bot_id}")
  end

  @impl SocialScribe.RecallApi
  def get_bot(recall_bot_id) do
    Tesla.get(client(), "/bot/#{recall_bot_id}")
  end

  @impl SocialScribe.RecallApi
  def create_transcript(recording_id) do
    # Create async transcript using Recall.ai provider
    # According to docs: https://docs.recall.ai/docs/async-transcription#/
    body = %{
      provider: %{
        recallai_async: %{
          language_code: "en"
        }
      }
    }

    Tesla.post(client(), "/recording/#{recording_id}/create_transcript/", body)
  end

  @impl SocialScribe.RecallApi
  def get_transcript(transcript_id) do
    # Retrieve transcript by ID
    # According to docs: https://docs.recall.ai/docs/async-transcription#/
    Tesla.get(client(), "/transcript/#{transcript_id}/")
  end

  @impl SocialScribe.RecallApi
  def get_bot_transcript(recall_bot_id) do
    # First get the bot to find the recording ID and check for transcript download URL
    case get_bot(recall_bot_id) do
      {:ok, %Tesla.Env{body: bot_info}} ->
        recordings = Map.get(bot_info, :recordings, [])

        case List.first(recordings) do
          nil ->
            # No recording found, return empty transcript
            {:ok, %Tesla.Env{status: 200, body: []}}

          recording ->
            # Check if transcript is available via download URL in media_shortcuts
            media_shortcuts = Map.get(recording, :media_shortcuts, %{})
            transcript_shortcut = Map.get(media_shortcuts, :transcript)

            if transcript_shortcut && Map.get(transcript_shortcut, :data) do
              # Try to download transcript from URL
              download_url = get_in(transcript_shortcut, [:data, :download_url])

              if download_url do
                # Download transcript from URL
                case download_transcript_from_url(download_url) do
                  {:ok, transcript_data} ->
                    {:ok, %Tesla.Env{status: 200, body: transcript_data}}

                  {:error, reason} ->
                    Logger.warning("Failed to download transcript from URL: #{inspect(reason)}")
                    # Fall back to API endpoint
                    try_api_transcript_endpoint(recording)
                end
              else
                # No download URL, try API endpoint
                try_api_transcript_endpoint(recording)
              end
            else
              # No transcript shortcut, try API endpoint
              try_api_transcript_endpoint(recording)
            end
        end

      error ->
        error
    end
  end

  defp try_api_transcript_endpoint(recording) do
    recording_id = Map.get(recording, :id)

    # Try GET with recording_id as path parameter
    case Tesla.get(client(), "/transcript/#{recording_id}") do
      {:ok, %Tesla.Env{status: status, body: body} = response} when status in 200..299 ->
        # Check if results are empty
        results = if is_map(body), do: Map.get(body, :results, []), else: []

        if Enum.empty?(results) do
          Logger.info("Transcript endpoint returned empty results for recording #{recording_id}. Transcript may still be processing.")
        else
          Logger.info("Successfully fetched transcript with #{length(results)} segments for recording #{recording_id}")
        end

        {:ok, response}

      # If that fails, try with query parameter
      _ ->
        case Tesla.get(client(), "/transcript", query: [recording_id: recording_id]) do
          {:ok, %Tesla.Env{status: status, body: body} = response} when status in 200..299 ->
            results = if is_map(body), do: Map.get(body, :results, []), else: []

            if Enum.empty?(results) do
              Logger.info("Transcript endpoint returned empty results for recording #{recording_id}. Transcript may still be processing.")
            end

            {:ok, response}

          # If both fail, return empty transcript
          _ ->
            Logger.warning("Failed to fetch transcript from API for recording #{recording_id}")
            {:ok, %Tesla.Env{status: 200, body: []}}
        end
    end
  end

  defp download_transcript_from_url(url) do
    require Logger

    # Create a client without base URL for absolute URLs
    download_client =
      Tesla.client([
        {Tesla.Middleware.JSON, engine_opts: [keys: :atoms]},
        {Tesla.Middleware.Headers,
         [
           {"Accept", "application/json"}
         ]}
      ])

    case Tesla.get(download_client, url) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        # Transcript might be a list or wrapped in a structure
        transcript_data =
          cond do
            is_list(body) -> body
            is_map(body) -> Map.get(body, :results) || Map.get(body, :data) || []
            true -> []
          end

        {:ok, transcript_data}

      {:ok, %Tesla.Env{status: status}} ->
        Logger.warning("Transcript download returned HTTP #{status}")
        {:error, :http_error}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
