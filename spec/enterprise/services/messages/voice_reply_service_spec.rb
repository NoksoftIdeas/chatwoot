require 'rails_helper'

RSpec.describe Messages::VoiceReplyService, type: :service do
  let(:account) { create(:account, voice_replies: true) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:audio) { File.binread(Rails.public_path.join('audio/widget/ding.mp3')) }
  let(:client) { instance_double(ElevenLabs::TextToSpeechClient) }

  def outgoing(content: 'We will refund you today.', **attrs)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :outgoing, sender: agent, content: content, **attrs)
  end

  before do
    allow(ElevenLabs::TextToSpeechClient).to receive(:new).and_return(client)
    allow(client).to receive(:synthesize).and_return(audio)
    allow(Messages::VoiceReplyJob).to receive(:perform_later)
  end

  describe '.eligible?' do
    it 'accepts an outgoing reply with content' do
      expect(described_class.eligible?(outgoing)).to be(true)
    end

    it 'rejects incoming messages' do
      message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)

      expect(described_class.eligible?(message)).to be(false)
    end

    it 'rejects private notes' do
      expect(described_class.eligible?(outgoing(private: true))).to be(false)
    end

    it 'rejects messages with no content' do
      expect(described_class.eligible?(outgoing(content: nil))).to be(false)
    end

    it 'rejects a message that already carries an attachment' do
      message = outgoing
      message.attachments.create!(account_id: account.id, file_type: :file)

      expect(described_class.eligible?(message.reload)).to be(false)
    end

    it 'rejects the voice follow-up itself so it cannot loop' do
      message = outgoing(content_attributes: { described_class::VOICE_REPLY_ATTRIBUTE => 1 })

      expect(described_class.eligible?(message)).to be(false)
    end

    it 'rejects when the account has voice replies off' do
      account.update!(voice_replies: false)

      expect(described_class.eligible?(outgoing.reload)).to be(false)
    end
  end

  describe '#perform' do
    it 'delivers the audio as a follow-up message' do
      message = outgoing

      expect { described_class.new(message: message).perform }
        .to change { conversation.messages.count }.by(1)

      voice = conversation.messages.order(:id).last
      expect(voice.message_type).to eq('outgoing')
      expect(voice.content_attributes[described_class::VOICE_REPLY_ATTRIBUTE]).to eq(message.id)
    end

    it 'attaches the audio before saving so the send job picks it up' do
      described_class.new(message: outgoing).perform

      attachment = conversation.messages.order(:id).last.attachments.first
      expect(attachment.file_type).to eq('audio')
      expect(attachment.file).to be_attached
    end

    it 'marks the attachment so it is never transcribed back into text' do
      described_class.new(message: outgoing).perform

      attachment = conversation.messages.order(:id).last.attachments.first
      expect(attachment.meta['source']).to eq('tts')
      expect(attachment.meta['is_voice_message']).to be(true)
      expect(Messages::AudioTranscriptionJob).not_to have_been_enqueued
    end

    it 'keeps the original sender on the spoken reply' do
      described_class.new(message: outgoing).perform

      expect(conversation.messages.order(:id).last.sender).to eq(agent)
    end

    it 'speaks the prose, not the markdown' do
      message = outgoing(content: 'See **our [refund policy](https://example.com/refunds)** for `details`.')

      expect(client).to receive(:synthesize).with('See our refund policy for .').and_return(audio)

      described_class.new(message: message).perform
    end

    it 'skips a reply that is only a link' do
      expect(described_class.new(message: outgoing(content: 'https://example.com')).perform).to eq(:nothing_to_say)
    end

    it 'skips a reply past the character ceiling' do
      long = 'a' * (ElevenLabs::TextToSpeechClient::MAX_CHARACTERS + 1)

      expect(described_class.new(message: outgoing(content: long)).perform).to eq(:too_long)
    end

    it 'reports failure without raising when synthesis fails' do
      allow(client).to receive(:synthesize).and_raise(Faraday::ServerError.new('boom'))
      message = outgoing

      expect(described_class.new(message: message).perform).to eq(:failed)
      expect(conversation.messages.where.not(id: message.id).count).to eq(0)
    end

    it 'does nothing for an ineligible message' do
      account.update!(voice_replies: false)

      expect(described_class.new(message: outgoing.reload).perform).to eq(:not_eligible)
    end
  end
end
