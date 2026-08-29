module Enterprise::Concerns::Message
  extend ActiveSupport::Concern

  included do
    has_one :call, dependent: :nullify
    has_many :message_reports, class_name: 'Captain::MessageReport', dependent: :destroy_async

    after_create_commit :enqueue_voice_reply
  end

  private

  # Speaks agent and Captain replies when the account has voice replies on. The
  # audio arrives as a follow-up message; see Messages::VoiceReplyService for
  # why it cannot ride on this one.
  def enqueue_voice_reply
    return unless Messages::VoiceReplyService.eligible?(self)

    Messages::VoiceReplyJob.perform_later(id)
  end
end
