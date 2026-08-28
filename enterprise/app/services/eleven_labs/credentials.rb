# Single source of truth for the ElevenLabs workspace credentials, shared by
# transcription (Llm::SpeechToText::ElevenLabsProvider) and the voice agent
# (Voice::Agent::ElevenLabsClient).
module ElevenLabs::Credentials
  class MissingApiKeyError < StandardError; end
  class MissingWebhookSecretError < StandardError; end

  API_KEY_CONFIG = 'ELEVENLABS_API_KEY'.freeze
  WEBHOOK_SECRET_CONFIG = 'ELEVENLABS_WEBHOOK_SECRET'.freeze

  class << self
    def api_key
      config_value(API_KEY_CONFIG)
    end

    def api_key!
      api_key.presence || raise(MissingApiKeyError, "#{API_KEY_CONFIG} is not configured")
    end

    def configured?
      api_key.present?
    end

    # Shared secret for verifying the ElevenLabs-Signature header on post-call
    # webhooks. Distinct from the API key: ElevenLabs generates it per webhook.
    def webhook_secret
      config_value(WEBHOOK_SECRET_CONFIG)
    end

    def webhook_secret!
      webhook_secret.presence || raise(MissingWebhookSecretError, "#{WEBHOOK_SECRET_CONFIG} is not configured")
    end

    private

    def config_value(name)
      InstallationConfig.find_by(name: name)&.value.presence
    end
  end
end
