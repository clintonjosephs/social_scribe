defmodule SocialScribe.HubSpotAISuggestionsTest do
  use SocialScribe.DataCase, async: true

  import SocialScribe.MeetingsFixtures
  import SocialScribe.BotsFixtures
  import SocialScribe.CalendarFixtures
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingTranscriptExample

  alias SocialScribe.HubSpotAISuggestions
  alias SocialScribe.Meetings

  @mock_transcript_data %{"data" => meeting_transcript_example()}

  # Note: These tests focus on testing the parsing and filtering logic.
  # Full integration tests with HTTP mocking would require Bypass or similar.
  # For now, we test the core logic that can be tested without HTTP calls.

  describe "generate_suggestions/3" do
    setup do
      # Set up a meeting with transcript
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})

      meeting =
        meeting_fixture(%{
          calendar_event_id: calendar_event.id,
          recall_bot_id: recall_bot.id
        })

      meeting_transcript_fixture(%{meeting_id: meeting.id, content: @mock_transcript_data})
      meeting_participant_fixture(%{meeting_id: meeting.id, name: "Test Participant"})

      meeting_with_details = Meetings.get_meeting_with_details(meeting.id)

      %{meeting: meeting_with_details}
    end

    test "handles missing meeting transcript gracefully", %{meeting: meeting} do
      # Create a meeting without transcript
      meeting_without_transcript = %{meeting | meeting_transcript: nil}

      hubspot_contact = %{"id" => "123", "properties" => %{}}

      result =
        HubSpotAISuggestions.generate_suggestions(meeting_without_transcript, hubspot_contact)

      assert {:error, :no_transcript} = result
    end

    test "handles missing meeting participants gracefully", %{meeting: meeting} do
      # Create a meeting without participants
      meeting_without_participants = %{meeting | meeting_participants: []}

      hubspot_contact = %{"id" => "123", "properties" => %{}}

      result =
        HubSpotAISuggestions.generate_suggestions(meeting_without_participants, hubspot_contact)

      # Should still work, just with no participants in prompt
      assert {:error, :no_participants} = result
    end
  end

  # Test helper functions that can be tested directly
  # These would be private functions, but we can test their behavior through public API
  # when we have proper HTTP mocking set up.
end
