defmodule Mix.Tasks.GenerateAutomations do
  @moduledoc """
  Generates automations for a specific meeting by title or ID.

  Usage:
    mix generate_automations "Meeting Title"
    mix generate_automations --id 123
    mix generate_automations "Meeting Title" --process-now  # Process job immediately
  """

  use Mix.Task

  alias SocialScribe.{Meetings, Repo}
  alias SocialScribe.Automations
  alias SocialScribe.Workers.AIContentGenerationWorker
  alias Oban

  @shortdoc "Generate automations for a meeting"

  @impl Mix.Task
  def run(args) do
    # Ensure all applications are started
    Mix.Task.run("app.start", [])

    # Ensure Oban is started
    {:ok, _} = Application.ensure_all_started(:oban)

    {process_now, clean_args} = extract_process_flag(args)

    case parse_args(clean_args) do
      {:id, meeting_id} ->
        generate_for_meeting_id(meeting_id, process_now)

      {:title, title_pattern} ->
        generate_for_meeting_title(title_pattern, process_now)

      :error ->
        IO.puts("""
        Usage:
          mix generate_automations "Meeting Title"
          mix generate_automations --id 123
          mix generate_automations "Meeting Title" --process-now
        """)
    end
  end

  defp extract_process_flag(args) do
    if "--process-now" in args do
      {true, List.delete(args, "--process-now")}
    else
      {false, args}
    end
  end

  defp parse_args(["--id", id]) do
    {:id, String.to_integer(id)}
  end

  defp parse_args([title]) when is_binary(title) do
    {:title, title}
  end

  defp parse_args(_), do: :error

  defp generate_for_meeting_id(meeting_id, process_now) do
    meeting = Meetings.get_meeting_with_details(meeting_id)

    if meeting do
      generate_automations(meeting, process_now)
    else
      IO.puts("Meeting with ID #{meeting_id} not found")
    end
  end

  defp generate_for_meeting_title(title_pattern, process_now) do
    import Ecto.Query

    meetings =
      Repo.all(
        from m in SocialScribe.Meetings.Meeting,
          where: ilike(m.title, ^"%#{title_pattern}%"),
          preload: [:calendar_event, :meeting_transcript, :meeting_participants],
          order_by: [desc: m.inserted_at],
          limit: 10
      )

    case meetings do
      [] ->
        IO.puts("No meetings found matching '#{title_pattern}'")

      [meeting] ->
        IO.puts("Found meeting: #{meeting.id} - #{meeting.title}")
        generate_automations(meeting, process_now)

      multiple ->
        IO.puts("Found #{length(multiple)} meetings matching '#{title_pattern}':")
        Enum.each(multiple, fn m -> IO.puts("  #{m.id}: #{m.title}") end)
        IO.puts("\nPlease use: mix generate_automations --id <meeting_id>")
    end
  end

  defp generate_automations(meeting, process_now) do
    IO.puts("\n=== Generating Automations ===")
    IO.puts("Meeting ID: #{meeting.id}")
    IO.puts("Title: #{meeting.title}")
    IO.puts("User ID: #{meeting.calendar_event.user_id}")

    # Check if meeting has transcript
    has_transcript =
      meeting.meeting_transcript &&
        meeting.meeting_transcript.content &&
        Map.get(meeting.meeting_transcript.content, "data", []) != []

    has_participants = Enum.any?(meeting.meeting_participants || [])

    IO.puts("Has transcript: #{has_transcript}")
    IO.puts("Has participants: #{has_participants}")

    if !has_transcript do
      IO.puts("\n⚠️  Warning: Meeting does not have a transcript. Automation generation may fail.")
    end

    if !has_participants do
      IO.puts("\n⚠️  Warning: Meeting does not have participants. Automation generation may fail.")
    end

    # Check active automations
    automations = Automations.list_active_user_automations(meeting.calendar_event.user_id)

    if Enum.empty?(automations) do
      IO.puts("\n⚠️  No active automations found for this user.")
      IO.puts("   Automations must be created and activated in the UI first.")
    else
      IO.puts("\nActive automations: #{Enum.count(automations)}")
      Enum.each(automations, fn a -> IO.puts("  - #{a.name} (#{a.platform})") end)

      # Enqueue the job
      IO.puts("\nEnqueuing AI content generation job...")

      job = AIContentGenerationWorker.new(%{meeting_id: meeting.id})

      case Oban.insert(job) do
        {:ok, job} ->
          IO.puts("✅ Job enqueued successfully!")
          IO.puts("   Job ID: #{job.id}")
          IO.puts("   Queue: #{job.queue}")

          if process_now do
            IO.puts("\nProcessing job immediately...")
            # Process the job synchronously for development
            case perform_job(job) do
              :ok ->
                IO.puts("✅ Job processed successfully!")
                IO.puts("   Check the meeting page to see the generated automations.")

              {:error, reason} ->
                IO.puts("❌ Error processing job: #{inspect(reason)}")
            end
          else
            IO.puts(
              "\nThe job will process automatically. Check the meeting page to see results."
            )

            IO.puts("Note: In development, ensure Oban is running or use --process-now flag")
          end

        {:error, reason} ->
          IO.puts("❌ Error enqueuing job: #{inspect(reason)}")
      end
    end
  end

  defp perform_job(%Oban.Job{} = job) do
    # Execute the worker's perform function directly
    case AIContentGenerationWorker.perform(job) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
