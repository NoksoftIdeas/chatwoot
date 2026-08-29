class Messages::VoiceReplyJob < ApplicationJob
  queue_as :low

  # A rejected request will be rejected again; only transient failures are worth
  # retrying, and the service already swallows the rest.
  discard_on Faraday::BadRequestError, Faraday::UnauthorizedError

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank?

    Messages::VoiceReplyService.new(message: message).perform
  end
end
