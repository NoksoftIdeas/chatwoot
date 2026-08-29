# Mints a short-lived WebRTC token so the browser can talk to an agent without
# ever seeing the workspace API key.
#
# https://elevenlabs.io/docs/eleven-agents/libraries/java-script
class ElevenLabs::ConversationTokenClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class TokenError < Error; end

  API_URL = 'https://api.elevenlabs.io/v1/convai/conversation/token'.freeze

  TIMEOUT = 10
  OPEN_TIMEOUT = 5

  pattr_initialize [:agent_id!]

  def webrtc_token
    response = connection.get(API_URL, { agent_id: agent_id })
    token = JSON.parse(response.body)['token'].presence
    raise TokenError, 'ElevenLabs returned no conversation token' if token.blank?

    token
  rescue JSON::ParserError => e
    raise TokenError, "Unparseable ElevenLabs token response: #{e.message}"
  end

  private

  def connection
    Faraday.new(headers: { 'xi-api-key' => api_key }) do |f|
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
