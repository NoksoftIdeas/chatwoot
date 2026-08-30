# Text in, MP3 bytes out.
#
# https://elevenlabs.io/docs/api-reference/text-to-speech/convert
class ElevenLabs::TextToSpeechClient
  class Error < StandardError; end
  class ConfigurationError < Error; end

  API_ROOT = 'https://api.elevenlabs.io/v1/text-to-speech'.freeze

  # Sarah, from ElevenLabs' `premade` set. Deliberately not one of the "library"
  # voices (Rachel and friends): the API rejects those for accounts without a
  # paid plan with 402 paid_plan_required, so a library default would make the
  # feature look broken on exactly the accounts most likely to be trialling it.
  # Overridable per installation and per account.
  DEFAULT_VOICE_ID = 'EXAVITQu4vr4xnSDxMaL'.freeze
  DEFAULT_MODEL = 'eleven_flash_v2_5'.freeze

  # ElevenLabs returns mp3/pcm/ulaw; there is no opus output. That matters
  # downstream: WhatsApp only renders a true push-to-talk voice note for
  # audio/ogg, so an MP3 reply arrives as an ordinary audio attachment.
  OUTPUT_FORMAT = 'mp3_44100_128'.freeze
  CONTENT_TYPE = 'audio/mpeg'.freeze

  # Long replies are not worth voicing and risk the model's own input ceiling.
  MAX_CHARACTERS = 5000

  TIMEOUT = 60
  OPEN_TIMEOUT = 10

  pattr_initialize [{ voice_id: nil, model: nil }]

  def self.too_long?(text)
    text.to_s.length > MAX_CHARACTERS
  end

  def synthesize(text)
    raise ArgumentError, 'text is required' if text.blank?
    raise ArgumentError, "text exceeds #{MAX_CHARACTERS} characters" if self.class.too_long?(text)

    response = connection.post(endpoint, { text: text, model_id: resolved_model }.to_json)
    response.body
  end

  def resolved_voice_id
    voice_id.presence || configured(:tts_voice_id) || DEFAULT_VOICE_ID
  end

  def resolved_model
    model.presence || configured(:tts_model) || DEFAULT_MODEL
  end

  private

  def endpoint
    "#{API_ROOT}/#{resolved_voice_id}?output_format=#{OUTPUT_FORMAT}"
  end

  def configured(key)
    InstallationConfig.find_by(name: "ELEVENLABS_#{key.to_s.upcase}")&.value.presence
  end

  def connection
    Faraday.new(headers: { 'xi-api-key' => api_key, 'Content-Type' => 'application/json', 'Accept' => CONTENT_TYPE }) do |f|
      f.response :raise_error
      f.options.timeout = TIMEOUT
      f.options.open_timeout = OPEN_TIMEOUT
    end
  end

  def api_key
    ElevenLabs::Credentials.api_key!
  rescue ElevenLabs::Credentials::MissingApiKeyError => e
    raise ConfigurationError, e.message
  end
end
