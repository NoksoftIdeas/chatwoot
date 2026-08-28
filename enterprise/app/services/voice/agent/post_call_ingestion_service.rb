# Folds an ElevenLabs post-call webhook back into the Chatwoot call record.
#
# ElevenLabs sends two separate webhooks per conversation: one carrying the
# transcript and analysis, one carrying the audio. Both identify the call
# through the dynamic variables we registered it with, since ElevenLabs never
# sees our Twilio call SID.
class Voice::Agent::PostCallIngestionService
  TRANSCRIPT_TYPE = 'post_call_transcription'.freeze
  AUDIO_TYPE = 'post_call_audio'.freeze

  # Speaker labels for the rendered transcript. ElevenLabs calls the caller
  # "user"; in Chatwoot the caller is the contact.
  ROLE_LABELS = { 'user' => 'Caller', 'agent' => 'Agent' }.freeze

  pattr_initialize [:payload!]

  def perform
    return :ignored unless supported_type?
    return :call_not_found if call.blank?

    case payload['type']
    when TRANSCRIPT_TYPE then ingest_transcript!
    when AUDIO_TYPE then ingest_audio!
    end
  end

  private

  def supported_type?
    [TRANSCRIPT_TYPE, AUDIO_TYPE].include?(payload['type'])
  end

  def data
    @data ||= payload['data'].presence || {}
  end

  def call
    return @call if defined?(@call)

    @call = chatwoot_call_id.present? ? Call.find_by(id: chatwoot_call_id) : nil
    Rails.logger.warn("VOICE_AGENT_POST_CALL_UNKNOWN_CALL id=#{chatwoot_call_id.inspect}") if @call.blank?
    @call
  end

  def chatwoot_call_id
    data.dig('conversation_initiation_client_data', 'dynamic_variables', 'chatwoot_call_id')
  end

  def ingest_transcript!
    text = rendered_transcript
    return :empty if text.blank?

    call.update!(transcript: text, voice_agent_conversation_id: data['conversation_id'])
    publish!
    :transcript_stored
  end

  # Turns are [{ role: 'user'|'agent', message: '...' }, ...]. Rendered as
  # labelled lines because Call#transcript is a plain text column — the same
  # shape Llm::SpeechToTextService produces for human calls.
  def rendered_transcript
    Array(data['transcript']).filter_map do |turn|
      next unless turn.is_a?(Hash)

      message = (turn['message'].presence || turn['text']).to_s.strip
      next if message.blank?

      "#{ROLE_LABELS.fetch(turn['role'].to_s, turn['role'].to_s.titleize)}: #{message}"
    end.join("\n").presence
  end

  def ingest_audio!
    encoded = data['full_audio'].presence
    return :empty if encoded.blank?

    call.recording.attach(
      io: StringIO.new(Base64.decode64(encoded)),
      filename: "call-#{call.id}.mp3",
      content_type: 'audio/mpeg'
    )
    publish!
    :audio_stored
  rescue ArgumentError => e
    Rails.logger.error("VOICE_AGENT_POST_CALL_BAD_AUDIO call=#{call.id}: #{e.message}")
    :invalid_audio
  end

  # Mirrors Voice::CallTranscriptionService#publish: reindex before broadcasting
  # so a retry after a reindex failure does not resend the update event.
  def publish!
    message = call.message
    return if message.blank?

    message.reindex if ChatwootApp.advanced_search_allowed?
    message.reload.send_update_event
  end
end
