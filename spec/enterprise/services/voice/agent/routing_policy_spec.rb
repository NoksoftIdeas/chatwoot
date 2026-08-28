require 'rails_helper'

RSpec.describe Voice::Agent::RoutingPolicy, type: :service do
  subject(:policy) { described_class.new(inbox: inbox, call: call, direction: 'inbound', from: '+15550003333') }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:inbox) { channel.inbox }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call) { create(:call, account: account, inbox: inbox, conversation: conversation, contact: conversation.contact) }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'AP123'))
  end

  def configure_agent(mode:, agent_id: 'agent_abc123')
    channel.update!(provider_config: channel.provider_config.merge(
      'voice_agent' => { 'provider' => 'elevenlabs', 'agent_id' => agent_id, 'mode' => mode }
    ))
  end

  describe '#agent_answers?' do
    it 'is false when nothing is configured' do
      expect(policy.agent_answers?).to be(false)
    end

    it 'is false when the mode is off' do
      configure_agent(mode: 'off')

      expect(policy.agent_answers?).to be(false)
    end

    it 'is false when a mode is set but no agent id is' do
      configure_agent(mode: 'always', agent_id: nil)

      expect(policy.agent_answers?).to be(false)
    end

    it 'is true in always mode' do
      configure_agent(mode: 'always')

      expect(policy.agent_answers?).to be(true)
    end

    it 'never answers an agent leg joining the bridge' do
      configure_agent(mode: 'always')
      policy = described_class.new(inbox: inbox, call: call, direction: 'inbound', from: 'client:agent-1-account-2')

      expect(policy.agent_answers?).to be(false)
    end

    it 'never answers an outbound leg' do
      configure_agent(mode: 'always')
      policy = described_class.new(inbox: inbox, call: call, direction: 'outbound-api', from: '+15550003333')

      expect(policy.agent_answers?).to be(false)
    end

    it 'does not take back a call it already escalated to a human' do
      configure_agent(mode: 'always')
      call.update!(answered_by: 'ai_escalated')

      expect(policy.agent_answers?).to be(false)
    end

    it 'is false when inbound calls are turned off entirely' do
      configure_agent(mode: 'always')
      channel.update!(provider_config: channel.provider_config.merge('inbound_calls_enabled' => false))

      expect(policy.agent_answers?).to be(false)
    end

    context 'when in fallback mode' do
      before { configure_agent(mode: 'fallback') }

      it 'stays out of the way while a member of the inbox is online' do
        create(:inbox_member, inbox: inbox, user: agent)
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')

        expect(policy.agent_answers?).to be(false)
      end

      it 'answers when every member is offline' do
        create(:inbox_member, inbox: inbox, user: agent)
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})

        expect(policy.agent_answers?).to be(true)
      end

      it 'answers when members are present but busy rather than online' do
        create(:inbox_member, inbox: inbox, user: agent)
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'busy')

        expect(policy.agent_answers?).to be(true)
      end

      it 'ignores online users who are not members of this inbox' do
        other = create(:user, account: account, role: :agent)
        create(:inbox_member, inbox: inbox, user: agent)
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return(other.id.to_s => 'online')

        expect(policy.agent_answers?).to be(true)
      end

      it 'routes to humans when the presence lookup fails rather than silently taking the call' do
        create(:inbox_member, inbox: inbox, user: agent)
        # Materialise the records first: creating them also consults presence,
        # and we only want the lookup inside the policy to blow up.
        policy
        allow(OnlineStatusTracker).to receive(:get_available_users).and_raise(Redis::CannotConnectError)

        expect(policy.agent_answers?).to be(false)
      end

      it 'routes to humans when the inbox has no members at all' do
        expect(policy.agent_answers?).to be(false)
      end
    end
  end
end
