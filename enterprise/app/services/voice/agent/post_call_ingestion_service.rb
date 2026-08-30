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

  # Namespaces the external id we stamp on transcribed widget turns.
  SOURCE_ID_PREFIX = 'elevenlabs'.freeze

  pattr_initialize [:payload!]

  def perform
    return :ignored unless supported_type?
    return ingest_for_call! if call.present?
    return ingest_for_widget_conversation! if widget_conversation.present?

    :target_not_found
  end

  private

  def supported_type?
    [TRANSCRIPT_TYPE, AUDIO_TYPE].include?(payload['type'])
  end

  def data
    @data ||= payload['data'].presence || {}
  end

  # Prefer ElevenLabs' own conversation id, which Voice::Agent::AnswerService
  # recorded at registration: it is authoritative and cannot be lost or altered
  # in the round trip. The dynamic variable stays as a fallback for calls
  # answered before that was captured.
  def call
    return @call if defined?(@call)

    @call = call_by_agent_conversation || call_by_dynamic_variable
    Rails.logger.warn("VOICE_AGENT_POST_CALL_UNKNOWN_CALL conversation=#{voice_session_id.inspect}") if @call.blank?
    @call
  end

  def call_by_agent_conversation
    return if voice_session_id.blank?

    Call.by_voice_agent_conversation_id(voice_session_id).first
  end

  def call_by_dynamic_variable
    return if chatwoot_call_id.blank?

    Call.find_by(id: chatwoot_call_id)
  end

  def chatwoot_call_id
    dynamic_variables['chatwoot_call_id']
  end

  def dynamic_variables
    data.dig('conversation_initiation_client_data', 'dynamic_variables').presence || {}
  end

  # Widget sessions have no Call row. They are identified by a signed reference
  # the browser was handed at session start, so a forged conversation id cannot
  # inject a transcript into someone else's thread.
  def widget_conversation
    return @widget_conversation if defined?(@widget_conversation)

    reference = Voice::Agent::WidgetSessionService.resolve_reference(dynamic_variables['chatwoot_voice_reference'])
    @widget_conversation = reference && Conversation.find_by(id: reference[:conversation_id], account_id: reference[:account_id])
  end

  def ingest_for_call!
    case payload['type']
    when TRANSCRIPT_TYPE then ingest_transcript!
    when AUDIO_TYPE then ingest_audio!
    end
  end

  # A widget transcript becomes ordinary conversation messages, so the visitor's
  # spoken words and the agent's replies read like any other chat.
  def ingest_for_widget_conversation!
    return :ignored unless payload['type'] == TRANSCRIPT_TYPE
    return :already_ingested if already_ingested?

    turns = transcript_turns
    return :empty if turns.blank?

    turns.each_with_index { |turn, index| create_widget_message!(turn, index) }
    :transcript_stored
  end

  # Dedup rides on source_id rather than content_attributes: that column is
  # `json` and Rails stores it double-encoded, so `->> 'key'` reads NULL and
  # every redelivery would look new. source_id is a plain indexed text column
  # and is what external message ids are for.
  def already_ingested?
    return false if voice_session_id.blank?

    widget_conversation.messages.exists?(['source_id LIKE ?', "#{sanitized_source_prefix}%"])
  end

  def voice_session_id
    data['conversation_id'].presence
  end

  def source_prefix
    "#{SOURCE_ID_PREFIX}:#{voice_session_id}:"
  end

  def sanitized_source_prefix
    ActiveRecord::Base.sanitize_sql_like(source_prefix)
  end

  def create_widget_message!(turn, index)
    widget_conversation.messages.create!(
      account_id: widget_conversation.account_id,
      inbox_id: widget_conversation.inbox_id,
      message_type: turn[:role] == 'user' ? :incoming : :outgoing,
      content: turn[:message],
      source_id: voice_session_id.present? ? "#{source_prefix}#{index}" : nil,
      content_attributes: { 'voice_session_id' => voice_session_id }
    )
  end

  def transcript_turns
    Array(data['transcript']).filter_map do |turn|
      next unless turn.is_a?(Hash)

      message = (turn['message'].presence || turn['text']).to_s.strip
      next if message.blank?

      { role: turn['role'].to_s, message: message }
    end
  end

  def ingest_transcript!
    text = rendered_transcript
    return :empty if text.blank?

    call.update!(transcript: text, voice_agent_conversation_id: data['conversation_id'])
    publish!
    :transcript_stored
  end

  # Rendered as labelled lines because Call#transcript is a plain text column ---
  # the same shape Llm::SpeechToTextService produces for human calls.
  def rendered_transcript
    transcript_turns.map do |turn|
      "#{ROLE_LABELS.fetch(turn[:role], turn[:role].titleize)}: #{turn[:message]}"
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
