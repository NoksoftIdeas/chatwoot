# Sets up a browser voice session for a widget conversation.
#
# The transcript comes back through ElevenLabs' post-call webhook, which only
# echoes whatever the browser told it. A conversation id supplied by the client
# would therefore be spoofable — any visitor could post a transcript into
# someone else's conversation. So the browser is handed a signed reference
# instead, and the webhook resolves the conversation by verifying it.
class Voice::Agent::WidgetSessionService
  class NotConfiguredError < StandardError; end

  VERIFIER_SALT = 'elevenlabs_voice_session'.freeze
  REFERENCE_TTL = 2.hours

  pattr_initialize [:conversation!]

  def self.verifier
    Rails.application.message_verifier(VERIFIER_SALT)
  end

  # Returns { conversation_id:, account_id: } or nil when the reference is
  # forged, expired or malformed.
  def self.resolve_reference(reference)
    return if reference.blank?

    verifier.verified(reference, purpose: :voice_session)&.symbolize_keys
  end

  def perform
    raise NotConfiguredError, 'no voice widget agent configured' if agent_id.blank?

    {
      token: ElevenLabs::ConversationTokenClient.new(agent_id: agent_id).webrtc_token,
      agent_id: agent_id,
      voice_reference: signed_reference
    }
  end

  private

  def account
    @account ||= conversation.account
  end

  def agent_id
    @agent_id ||= account.voice_widget_agent_id.presence
  end

  def signed_reference
    self.class.verifier.generate(
      { conversation_id: conversation.id, account_id: account.id },
      purpose: :voice_session,
      expires_in: REFERENCE_TTL
    )
  end
end
