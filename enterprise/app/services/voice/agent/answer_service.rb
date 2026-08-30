# Answers an inbound call with the inbox's AI voice agent.
#
# Returns TwiML for Twilio to render, or nil when the agent could not take the
# call — the caller then falls back to the ordinary human conference. Nothing
# here is allowed to raise: a misconfigured or unreachable ElevenLabs must never
# drop a live caller.
class Voice::Agent::AnswerService
  pattr_initialize [:call!, :from!, :to!]

  def perform
    registration = client.register_call(
      from: from,
      to: to,
      direction: 'inbound',
      dynamic_variables: dynamic_variables
    )
    mark_answered_by_agent!(registration.conversation_id)
    registration.twiml
  rescue StandardError => e
    Rails.logger.error("VOICE_AGENT_ANSWER_FAILED call=#{call.id} inbox=#{call.inbox_id} #{e.class}: #{e.message}")
    ChatwootExceptionTracker.new(e, account: call.account).capture_exception
    nil
  end

  private

  def client
    Voice::Agent::ElevenLabsClient.new(agent_id: channel.voice_agent_id)
  end

  def channel
    @channel ||= call.inbox.channel
  end

  # The agent has no other handle on this call: register-call takes no call_sid,
  # so these are what its escalation tool sends back to identify the caller.
  # Values are strings because ElevenLabs interpolates them into prompts.
  def dynamic_variables
    {
      chatwoot_call_id: call.id.to_s,
      chatwoot_conversation_id: call.conversation_id.to_s,
      chatwoot_account_id: call.account_id.to_s,
      caller_number: from.to_s,
      contact_name: call.contact&.name.to_s
    }
  end

  # Recorded before a word is spoken, so the post-call webhook can match on
  # ElevenLabs' own conversation id rather than on a dynamic variable we asked
  # them to echo back.
  def mark_answered_by_agent!(conversation_id)
    call.update!(answered_by: 'ai', voice_agent_conversation_id: conversation_id)
  end
end
