# Path-in, text-out adapter for OpenAI's transcription endpoint.
# Selected by Llm::SpeechToTextService when the resolved audio_transcription
# model belongs to the openai provider.
class Llm::SpeechToText::OpenAiProvider
  # OpenAI's transcription endpoint hard limit is 25 MB *decimal* (25_000_000), not
  # binary (25.megabytes = 26_214_400) — using the binary form leaks the 25.0–26.2 MB
  # range to the API as 413s. Long audio (~70+ min Opus) keeps the source audio but
  # skips transcription.
  BYTE_LIMIT = 25_000_000

  def self.byte_limit
    BYTE_LIMIT
  end

  # Runs on CAPTAIN_OPEN_AI_API_KEY — the same key and quota Captain itself
  # bills against, so a transcription really does spend a response credit.
  def self.consumes_captain_credits?
    true
  end

  pattr_initialize [:model!]

  def transcribe(file_path)
    File.open(file_path, 'rb') do |file|
      # temperature: 0.0 minimises hallucinations on silence / near-silent
      # audio; non-zero values trigger spiraling repeats — well-documented
      # behaviour across OpenAI transcription models.
      response = client.audio.transcribe(
        parameters: {
          model: model,
          file: file,
          temperature: 0.0
        }
      )
      response['text']
    end
  end

  private

  # Built lazily so an installation transcribing through another provider does
  # not need CAPTAIN_OPEN_AI_API_KEY present just to load this class.
  def client
    @client ||= OpenAI::Client.new(
      access_token: InstallationConfig.find_by!(name: 'CAPTAIN_OPEN_AI_API_KEY').value,
      uri_base: uri_base,
      log_errors: Rails.env.development?
    )
  end

  def uri_base
    endpoint = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    endpoint.presence || 'https://api.openai.com/'
  end
end
