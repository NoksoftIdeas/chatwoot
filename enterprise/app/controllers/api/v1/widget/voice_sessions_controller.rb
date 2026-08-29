# Hands the widget a short-lived WebRTC token for a voice conversation with the
# account's ElevenLabs agent. The workspace API key never leaves the server.
class Api::V1::Widget::VoiceSessionsController < Api::V1::Widget::BaseController
  def create
    session = Voice::Agent::WidgetSessionService.new(conversation: target_conversation).perform

    render json: session
  rescue Voice::Agent::WidgetSessionService::NotConfiguredError
    render json: { error: 'voice_not_available' }, status: :not_found
  rescue ElevenLabs::ConversationTokenClient::Error => e
    Rails.logger.error("WIDGET_VOICE_SESSION_FAILED account=#{inbox&.account_id} #{e.class}: #{e.message}")
    render json: { error: 'voice_unavailable' }, status: :service_unavailable
  end

  private

  # A visitor can open a voice session before they have typed anything, so the
  # conversation may not exist yet.
  #
  # Built here rather than through BaseController#create_conversation: that path
  # reads permitted_params[:message][:timestamp], and a voice session carries no
  # message to read it from.
  def target_conversation
    conversation || ::Conversation.create!(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: { initiated_by: 'voice_session' }
    )
  end
end
