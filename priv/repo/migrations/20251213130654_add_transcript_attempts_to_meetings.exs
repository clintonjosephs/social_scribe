defmodule SocialScribe.Repo.Migrations.AddTranscriptAttemptsToMeetings do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :transcript_attempts, :integer, default: 0, null: false
    end
  end
end
