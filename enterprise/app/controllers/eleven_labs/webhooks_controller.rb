# Endpoints ElevenLabs calls back on. Not Twilio webhooks and not the dashboard
# API, so they authenticate on their own shared secret rather than a session.
class ElevenLabs::WebhooksController < ApplicationController
  before_action :authenticate_webhook!, only: [:escalate]
  before_action :verify_signature!, only: [:post_call]

  # Custom tool the agent invokes to hand the caller to a person. The agent
  # identifies the call with the chatwoot_call_id dynamic variable it was
  # registered with; it has no other handle on the Twilio leg.
  def escalate
    call = find_call!
    Voice::Agent::EscalationService.new(call: call, reason: params[:reason]).perform

    render json: { status: 'escalated', conversation_id: call.conversation_id }
  rescue Voice::Agent::EscalationService::CallNotEscalatableError => e
    Rails.logger.warn("VOICE_AGENT_ESCALATION_REJECTED #{e.message}")
    render json: { status: 'rejected', error: e.message }, status: :unprocessable_entity
  end

  # Transcript and audio for a finished agent conversation. ElevenLabs sends
  # these as two separate webhooks; both are folded onto the same Call.
  def post_call
    outcome = Voice::Agent::PostCallIngestionService.new(payload: post_call_payload).perform
    Rails.logger.info("VOICE_AGENT_POST_CALL type=#{post_call_payload['type']} outcome=#{outcome}")

    head :no_content
  end

  private

  # ElevenLabs signs the raw body, so parse it ourselves rather than reusing
  # `params` — Rails' parsed copy is not byte-identical to what was signed.
  def post_call_payload
    @post_call_payload ||= JSON.parse(raw_body)
  rescue JSON::ParserError
    {}
  end

  def raw_body
    @raw_body ||= request.body.read.to_s.tap { request.body.rewind }
  end

  def verify_signature!
    secret = ElevenLabs::Credentials.webhook_secret
    return head :service_unavailable if secret.blank?

    return if ElevenLabs::WebhookSignature.valid?(
      payload: raw_body,
      header: request.headers['ElevenLabs-Signature'],
      secret: secret
    )

    Rails.logger.warn('VOICE_AGENT_POST_CALL_BAD_SIGNATURE')
    head :unauthorized
  end

  # The tool is configured in ElevenLabs with this secret as a request header.
  # Compared in constant time so a wrong secret leaks nothing by timing.
  def authenticate_webhook!
    expected = ElevenLabs::Credentials.webhook_secret
    return head :service_unavailable if expected.blank?
    return if ActiveSupport::SecurityUtils.secure_compare(provided_secret.to_s, expected)

    head :unauthorized
  end

  def provided_secret
    request.headers['X-Chatwoot-Signature'].presence || request.headers['x-chatwoot-signature']
  end

  def find_call!
    call_id = params[:chatwoot_call_id].presence
    raise ActionController::BadRequest, 'chatwoot_call_id is required' if call_id.blank?

    Call.find(call_id)
  end
end
