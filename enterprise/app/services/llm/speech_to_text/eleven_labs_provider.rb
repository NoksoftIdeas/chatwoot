require 'faraday/multipart'

# Path-in, text-out adapter for ElevenLabs Scribe.
# Selected by Llm::SpeechToTextService when the resolved audio_transcription
# model belongs to the elevenlabs provider.
#
# https://elevenlabs.io/docs/api-reference/speech-to-text/convert
class Llm::SpeechToText::ElevenLabsProvider
  class Error < StandardError; end
  # The key is missing or unusable — retrying will not help.
  class ConfigurationError < Error; end
  # A 2xx that isn't the documented JSON body.
  class ResponseError < Error; end

  API_URL = 'https://api.elevenlabs.io/v1/speech-to-text'.freeze

  # ElevenLabs accepts up to 1 GB (~4.5 h of audio) on this endpoint, two orders
  # of magnitude above OpenAI's 25 MB. Long call recordings that the OpenAI path
  # skips outright (see Llm::SpeechToText::OpenAiProvider::BYTE_LIMIT) transcribe
  # here instead.
  BYTE_LIMIT = 1_000_000_000

  # Scribe is not streaming: the request holds open for the whole transcription,
  # so the default 60s read timeout is far too short. Audio long enough to
  # exceed even this wants ElevenLabs' webhook mode rather than a longer wait.
  TIMEOUT = 600
  OPEN_TIMEOUT = 60

  def self.byte_limit
    BYTE_LIMIT
  end

  # Billed directly by ElevenLabs against ELEVENLABS_API_KEY, so it never draws
  # down the account's Captain response balance.
  def self.consumes_captain_credits?
    false
  end

  pattr_initialize [:model!]

  def transcribe(file_path)
    File.open(file_path, 'rb') do |file|
      response = connection.post(API_URL, payload(file, file_path))
      extract_text(response)
    end
  end

  private

  def payload(file, file_path)
    file_name = File.basename(file_path)
    # Sniff the content as well as the name: fetch_audio_file can only append an
    # extension when the blob carried a content type, and Scribe rejects
    # application/octet-stream.
    mime_type = Marcel::MimeType.for(Pathname.new(file_path), name: file_name)

    {
      model_id: model,
      # Scribe tags laughter, background noise and the like inline as
      # "(laughs)". Useful for review, noise for FAQ matching and search —
      # which is what every consumer of this text does today.
      tag_audio_events: 'false',
      file: Faraday::Multipart::FilePart.new(file, mime_type, file_name)
    }
  end

  # Scribe also returns per-word timings and, with diarize enabled, speaker ids.
  # Both are dropped here: Call#transcript and Attachment#meta['transcribed_text']
  # are plain text columns with nowhere to put the structure.
  def extract_text(response)
    JSON.parse(response.body)['text']
  rescue JSON::ParserError => e
    raise ResponseError, "Unparseable ElevenLabs response (status #{response.status}): #{e.message}"
  end

  def connection
    Faraday.new(headers: { 'xi-api-key' => api_key }) do |f|
      f.request :multipart
      # Surfaces 401/400 as Faraday::UnauthorizedError / Faraday::BadRequestError,
      # which Messages::AudioTranscriptionService and AudioTranscriptionJob
      # already handle for the OpenAI path.
      f.response :raise_error
      f.options.timeout = TIMEOUT
      f.options.open_timeout = OPEN_TIMEOUT
    end
  end

  def api_key
    key = InstallationConfig.find_by(name: 'ELEVENLABS_API_KEY')&.value.presence
    raise ConfigurationError, 'ELEVENLABS_API_KEY is not configured' if key.blank?

    key
  end
end
