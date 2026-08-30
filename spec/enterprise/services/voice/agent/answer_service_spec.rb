require 'rails_helper'

RSpec.describe Voice::Agent::AnswerService, type: :service do
  subject(:service) { described_class.new(call: call, from: '+15550003333', to: channel.phone_number) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call) { create(:call, account: account, inbox: inbox, conversation: conversation, contact: conversation.contact) }
  let(:twiml) { '<Response><Connect><Stream url="wss://elevenlabs"/></Connect></Response>' }
  let(:registration) { Voice::Agent::ElevenLabsClient::Registration.new(twiml: twiml, conversation_id: 'conv_abc123') }
  let(:client) { instance_double(Voice::Agent::ElevenLabsClient) }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'AP123'))
    channel.update!(provider_config: channel.provider_config.merge(
      'voice_agent' => { 'provider' => 'elevenlabs', 'agent_id' => 'agent_abc123', 'mode' => 'always' }
    ))
    allow(Voice::Agent::ElevenLabsClient).to receive(:new).with(agent_id: 'agent_abc123').and_return(client)
  end

  describe '#perform' do
    it 'returns the TwiML ElevenLabs hands back' do
      allow(client).to receive(:register_call).and_return(registration)

      expect(service.perform).to eq(twiml)
    end

    it 'records that the AI took the call' do
      allow(client).to receive(:register_call).and_return(registration)

      service.perform

      expect(call.reload.answered_by).to eq('ai')
      expect(call).to be_answered_by_agent
    end

    it 'stores the ElevenLabs conversation id before a word is spoken' do
      allow(client).to receive(:register_call).and_return(registration)

      service.perform

      expect(call.reload.voice_agent_conversation_id).to eq('conv_abc123')
      expect(Call.by_voice_agent_conversation_id('conv_abc123')).to include(call)
    end

    it 'still answers when ElevenLabs omits the conversation id' do
      allow(client).to receive(:register_call)
        .and_return(Voice::Agent::ElevenLabsClient::Registration.new(twiml: twiml, conversation_id: nil))

      expect(service.perform).to eq(twiml)
      expect(call.reload.voice_agent_conversation_id).to be_nil
    end

    it 'passes the call endpoints and the ids the agent needs to call back' do
      expect(client).to receive(:register_call).with(
        from: '+15550003333',
        to: channel.phone_number,
        direction: 'inbound',
        dynamic_variables: hash_including(
          chatwoot_call_id: call.id.to_s,
          chatwoot_conversation_id: conversation.id.to_s,
          chatwoot_account_id: account.id.to_s,
          caller_number: '+15550003333'
        )
      ).and_return(registration)

      service.perform
    end

    context 'when the agent cannot take the call' do
      it 'returns nil so the caller falls back to a human' do
        allow(client).to receive(:register_call).and_raise(Faraday::ServerError.new('boom'))

        expect(service.perform).to be_nil
      end

      it 'does not mark the call as AI-answered' do
        allow(client).to receive(:register_call).and_raise(Faraday::ConnectionFailed.new('down'))

        service.perform

        expect(call.reload.answered_by).to be_nil
      end

      it 'swallows a missing API key rather than dropping the caller' do
        allow(client).to receive(:register_call)
          .and_raise(Voice::Agent::ElevenLabsClient::ConfigurationError.new('no key'))

        expect { service.perform }.not_to raise_error
        expect(service.perform).to be_nil
      end
    end
  end
end
