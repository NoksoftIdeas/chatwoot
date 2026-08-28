# Hands a call the AI is currently holding over to a human.
#
# Rather than building conference TwiML here, this points Twilio back at our own
# voice webhook. Twilio re-requests it, Twilio::VoiceController sees the call is
# already escalated and skips the agent, and the ordinary conference path runs
# with its recording, status callbacks and participant labels intact. Ending the
# ElevenLabs media stream is a side effect of Twilio moving off that TwiML.
class Voice::Agent::EscalationService
  class Error < StandardError; end
  class CallNotEscalatableError < Error; end

  pattr_initialize [:call!, { reason: nil }]

  def perform
    raise CallNotEscalatableError, "call #{call.id} is #{call.status}" if call.terminal?

    mark_escalated!
    redirect_to_conference!
    broadcast!
    call
  end

  private

  def channel
    @channel ||= call.inbox.channel
  end

  # Set before the redirect: Twilio re-requests our webhook immediately, and if
  # the flag were not already persisted the controller would hand the caller
  # straight back to the AI.
  def mark_escalated!
    call.update!(answered_by: 'ai_escalated', escalation_reason: reason.presence)
  end

  def redirect_to_conference!
    channel.client.calls(call.provider_call_id).update(
      url: channel.voice_call_webhook_url,
      method: 'POST'
    )
  end

  # Surfaces the call to agents the same way an ordinary inbound ring does.
  def broadcast!
    call.broadcast_voice_call_event(:escalated, escalation_reason: reason.presence)
  end
end
