require 'rails_helper'

RSpec.describe 'ElevenLabs::WebhooksController', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call) do
    create(:call, account: account, inbox: inbox, conversation: conversation,
                  contact: conversation.contact, status: 'in_progress')
  end
  let(:secret) { 'shared-webhook-secret' }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'AP123'))
    InstallationConfig.find_or_create_by!(name: 'ELEVENLABS_WEBHOOK_SECRET') { |c| c.value = secret }
  end

  describe 'POST /eleven_labs/webhooks/post_call' do
    let(:body) do
      {
        type: 'post_call_transcription',
        data: {
          conversation_id: 'conv_xyz',
          transcript: [{ role: 'agent', message: 'Hello' }],
          conversation_initiation_client_data: { dynamic_variables: { chatwoot_call_id: call.id.to_s } }
        }
      }.to_json
    end

    def signature_for(payload, signed_at: Time.zone.now.to_i, key: secret)
      "t=#{signed_at},v0=#{OpenSSL::HMAC.hexdigest('SHA256', key, "#{signed_at}.#{payload}")}"
    end

    def post_webhook(payload, header)
      post '/eleven_labs/webhooks/post_call', params: payload,
                                              headers: { 'ElevenLabs-Signature' => header, 'CONTENT_TYPE' => 'application/json' }
    end

    it 'stores the transcript when the signature checks out' do
      post_webhook(body, signature_for(body))

      expect(response).to have_http_status(:no_content)
      expect(call.reload.transcript).to eq('Agent: Hello')
    end

    it 'rejects a payload signed with the wrong secret' do
      post_webhook(body, signature_for(body, key: 'wrong'))

      expect(response).to have_http_status(:unauthorized)
      expect(call.reload.transcript).to be_nil
    end

    it 'rejects a replayed payload outside the tolerance window' do
      stale = Time.zone.now.to_i - ElevenLabs::WebhookSignature::TOLERANCE.to_i - 60

      post_webhook(body, signature_for(body, signed_at: stale))

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a body that was altered after signing' do
      post_webhook('{"type":"post_call_transcription","data":{}}', signature_for(body))

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an unsigned request' do
      post '/eleven_labs/webhooks/post_call', params: body, headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses to act when no secret is configured' do
      InstallationConfig.find_by(name: 'ELEVENLABS_WEBHOOK_SECRET').destroy!

      post_webhook(body, signature_for(body))

      expect(response).to have_http_status(:service_unavailable)
    end

    it 'accepts a signed payload for an unknown call without erroring' do
      unknown = {
        type: 'post_call_transcription',
        data: { conversation_initiation_client_data: { dynamic_variables: { chatwoot_call_id: '999999' } } }
      }.to_json

      post_webhook(unknown, signature_for(unknown))

      expect(response).to have_http_status(:no_content)
    end
  end

  describe 'POST /eleven_labs/webhooks/escalate' do
    let(:escalation) { instance_double(Voice::Agent::EscalationService, perform: call) }

    it 'escalates the call the agent names' do
      expect(Voice::Agent::EscalationService).to receive(:new)
        .with(call: call, reason: 'caller asked for a person').and_return(escalation)

      post '/eleven_labs/webhooks/escalate',
           params: { chatwoot_call_id: call.id, reason: 'caller asked for a person' },
           headers: { 'X-Chatwoot-Signature' => secret }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['status']).to eq('escalated')
      expect(response.parsed_body['conversation_id']).to eq(conversation.id)
    end

    it 'rejects a request with the wrong secret' do
      expect(Voice::Agent::EscalationService).not_to receive(:new)

      post '/eleven_labs/webhooks/escalate',
           params: { chatwoot_call_id: call.id },
           headers: { 'X-Chatwoot-Signature' => 'wrong' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a request with no secret at all' do
      post '/eleven_labs/webhooks/escalate', params: { chatwoot_call_id: call.id }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses to act when no secret is configured on this installation' do
      InstallationConfig.find_by(name: 'ELEVENLABS_WEBHOOK_SECRET').destroy!

      post '/eleven_labs/webhooks/escalate',
           params: { chatwoot_call_id: call.id },
           headers: { 'X-Chatwoot-Signature' => secret }

      expect(response).to have_http_status(:service_unavailable)
    end

    it 'reports a call that can no longer be escalated' do
      allow(Voice::Agent::EscalationService).to receive(:new).and_return(escalation)
      allow(escalation).to receive(:perform)
        .and_raise(Voice::Agent::EscalationService::CallNotEscalatableError, 'call 1 is completed')

      post '/eleven_labs/webhooks/escalate',
           params: { chatwoot_call_id: call.id },
           headers: { 'X-Chatwoot-Signature' => secret }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['status']).to eq('rejected')
    end
  end
end
