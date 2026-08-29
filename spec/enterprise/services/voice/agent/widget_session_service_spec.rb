require 'rails_helper'

RSpec.describe Voice::Agent::WidgetSessionService, type: :service do
  subject(:service) { described_class.new(conversation: conversation) }

  let(:account) { create(:account, voice_widget_agent_id: 'agent_widget_1') }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:token_client) { instance_double(ElevenLabs::ConversationTokenClient, webrtc_token: 'tok_abc') }

  before do
    allow(ElevenLabs::ConversationTokenClient).to receive(:new).with(agent_id: 'agent_widget_1').and_return(token_client)
  end

  describe '#perform' do
    it 'returns a token and the agent it belongs to' do
      session = service.perform

      expect(session[:token]).to eq('tok_abc')
      expect(session[:agent_id]).to eq('agent_widget_1')
    end

    it 'refuses when the account has no widget agent configured' do
      account.update!(voice_widget_agent_id: nil)

      expect { service.perform }.to raise_error(described_class::NotConfiguredError)
    end

    it 'hands out a signed reference rather than a raw conversation id' do
      reference = service.perform[:voice_reference]

      expect(reference).not_to include(conversation.id.to_s)
      expect(described_class.resolve_reference(reference))
        .to eq(conversation_id: conversation.id, account_id: account.id)
    end
  end

  describe '.resolve_reference' do
    it 'rejects a forged reference' do
      expect(described_class.resolve_reference('not-a-real-reference')).to be_nil
    end

    it 'rejects a blank reference' do
      expect(described_class.resolve_reference(nil)).to be_nil
      expect(described_class.resolve_reference('')).to be_nil
    end

    it 'rejects a reference signed for another purpose' do
      other = described_class.verifier.generate({ conversation_id: conversation.id }, purpose: :something_else)

      expect(described_class.resolve_reference(other)).to be_nil
    end

    it 'rejects an expired reference' do
      reference = travel_to(3.hours.ago) { service.perform[:voice_reference] }

      expect(described_class.resolve_reference(reference)).to be_nil
    end
  end
end
