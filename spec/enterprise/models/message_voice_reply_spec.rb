require 'rails_helper'

RSpec.describe Message do
  let(:account) { create(:account, voice_replies: true) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def create_outgoing(**attrs)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :outgoing, sender: agent, content: 'Refund on its way.', **attrs)
  end

  describe 'voice reply enqueueing' do
    it 'enqueues a spoken reply for an outgoing message' do
      expect { create_outgoing }.to have_enqueued_job(Messages::VoiceReplyJob)
    end

    it 'does not enqueue when the account has voice replies off' do
      account.update!(voice_replies: false)

      expect { create_outgoing }.not_to have_enqueued_job(Messages::VoiceReplyJob)
    end

    it 'does not enqueue for incoming messages' do
      expect do
        create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
      end.not_to have_enqueued_job(Messages::VoiceReplyJob)
    end

    it 'does not enqueue for private notes' do
      expect { create_outgoing(private: true) }.not_to have_enqueued_job(Messages::VoiceReplyJob)
    end

    it 'does not enqueue for the voice follow-up itself' do
      expect do
        create_outgoing(content_attributes: { Messages::VoiceReplyService::VOICE_REPLY_ATTRIBUTE => 1 })
      end.not_to have_enqueued_job(Messages::VoiceReplyJob)
    end
  end
end
