# Speaks an outgoing reply and delivers it as a follow-up message.
#
# The audio cannot ride on the original message: Message#send_reply is queued in
# the same after_create_commit that would trigger synthesis, so anything
# attached afterwards would never reach the contact. A second message with the
# attachment already built at save time goes out through the ordinary
# SendReplyJob path instead, which every channel already understands.
class Messages::VoiceReplyService
  # Marks the follow-up so it is never itself voiced, and so the dashboard can
  # tell which reply it belongs to.
  VOICE_REPLY_ATTRIBUTE = 'voice_reply_for'.freeze

  pattr_initialize [:message!]

  # Cheap pre-check, so the common case never enqueues a job.
  def self.eligible?(message)
    return false unless speakable?(message)
    return false if already_a_voice_reply?(message)

    message.account&.voice_replies.present?
  end

  # Something a person would read out: an outgoing public reply with prose and
  # no attachment of its own.
  def self.speakable?(message)
    message.outgoing? && !message.private? && message.content.present? && message.attachments.none?
  end

  def self.already_a_voice_reply?(message)
    message.content_attributes&.key?(VOICE_REPLY_ATTRIBUTE)
  end

  def perform
    return :not_eligible unless self.class.eligible?(message)

    text = speakable_text
    return :nothing_to_say if text.blank?
    return :too_long if ElevenLabs::TextToSpeechClient.too_long?(text)

    audio = client.synthesize(text)
    return :empty_audio if audio.blank?

    create_voice_message!(audio)
    :voiced
  rescue StandardError => e
    Rails.logger.error("VOICE_REPLY_FAILED message=#{message.id} #{e.class}: #{e.message}")
    ChatwootExceptionTracker.new(e, account: message.account).capture_exception
    :failed
  end

  private

  def client
    ElevenLabs::TextToSpeechClient.new(voice_id: message.account.voice_reply_voice_id)
  end

  # Captain writes markdown and appends citation links; read aloud verbatim they
  # become "asterisk asterisk" noise and spoken URLs. Strip to what a person
  # would actually say.
  def speakable_text
    message.content.to_s
           .gsub(/\[([^\]]+)\]\([^)]*\)/, '\1')   # markdown links -> their text
           .gsub(/!\[[^\]]*\]\([^)]*\)/, '')      # images -> nothing
           .gsub(/`{1,3}[^`]*`{1,3}/, ' ')        # code spans and fences
           .gsub(%r{https?://\S+}, ' ')           # bare urls
           .gsub(/[*_#>|]/, ' ')
           .gsub(/\s+/, ' ')
           .strip
  end

  # Built before save so SendReplyJob sees an attachment and waits for the
  # upload, exactly as it does for an agent's own audio upload.
  def create_voice_message!(audio)
    voice_message = message.conversation.messages.build(
      account_id: message.account_id,
      inbox_id: message.inbox_id,
      message_type: :outgoing,
      sender: message.sender,
      private: false,
      content_attributes: { VOICE_REPLY_ATTRIBUTE => message.id }
    )
    build_attachment(voice_message, audio)
    voice_message.save!
    voice_message
  end

  def build_attachment(voice_message, audio)
    attachment = voice_message.attachments.build(account_id: message.account_id, file_type: :audio)
    # 'source' keeps Enterprise::Concerns::Attachment from transcribing our own
    # speech back into text; 'is_voice_message' is what channels look at to
    # render it as a voice note rather than a file.
    attachment.meta = { 'source' => 'tts', 'is_voice_message' => true }
    attachment.file.attach(
      io: StringIO.new(audio),
      filename: "reply-#{message.id}.mp3",
      content_type: ElevenLabs::TextToSpeechClient::CONTENT_TYPE
    )
    attachment
  end
end
