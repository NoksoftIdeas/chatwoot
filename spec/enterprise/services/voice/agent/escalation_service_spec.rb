require 'rails_helper'

RSpec.describe Voice::Agent::EscalationService, type: :service do
  subject(:service) { described_class.new(call: call, reason: 'caller asked for a person') }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call) do
    create(:call, account: account, inbox: inbox, conversation: conversation,
                  contact: conversation.contact, status: 'in_progress')
  end
  let(:twilio_calls) { double('twilio_calls') } # rubocop:disable RSpec/VerifiedDoubles
  let(:twilio_client) { double('twilio_client') } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'AP123'))
    call.update!(answered_by: 'ai')
    allow(channel).to receive(:client).and_return(twilio_client)
    allow(Inbox).to receive(:find).and_call_original
    allow(call).to receive(:inbox).and_return(inbox)
    allow(inbox).to receive(:channel).and_return(channel)
    allow(twilio_client).to receive(:calls).with(call.provider_call_id).and_return(twilio_calls)
    allow(twilio_calls).to receive(:update)
  end

  describe '#perform' do
    it 'redirects the live Twilio leg back at our own voice webhook' do
      expect(twilio_calls).to receive(:update).with(url: channel.voice_call_webhook_url, method: 'POST')

      service.perform
    end

    it 'marks the call escalated before redirecting so the webhook does not loop' do
      allow(twilio_calls).to receive(:update) do
        expect(call.reload.answered_by).to eq('ai_escalated')
      end

      service.perform

      expect(call.reload).to be_escalated_from_agent
    end

    it 'records why the agent handed over' do
      service.perform

      expect(call.reload.escalation_reason).to eq('caller asked for a person')
    end

    it 'broadcasts so agents see the call waiting' do
      expect(call).to receive(:broadcast_voice_call_event)
        .with(:escalated, escalation_reason: 'caller asked for a person')

      service.perform
    end

    it 'refuses to escalate a call that has already ended' do
      call.update!(status: 'completed')

      expect { service.perform }.to raise_error(described_class::CallNotEscalatableError, /completed/)
    end

    it 'does not redirect a call that has already ended' do
      call.update!(status: 'completed')

      expect(twilio_calls).not_to receive(:update)

      expect { service.perform }.to raise_error(described_class::CallNotEscalatableError)
    end
  end
end
