require 'rails_helper'

RSpec.describe '/api/v1/widget/voice_session', type: :request do
  let(:account) { create(:account, voice_widget_agent_id: 'agent_widget_1') }
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: web_widget.inbox) }
  let(:payload) { { source_id: contact_inbox.source_id, inbox_id: web_widget.inbox.id } }
  let(:token) { Widget::TokenService.new(payload: payload).generate_token }
  let(:params) { { website_token: web_widget.website_token } }
  let(:token_client) { instance_double(ElevenLabs::ConversationTokenClient, webrtc_token: 'tok_abc') }

  before do
    allow(ElevenLabs::ConversationTokenClient).to receive(:new).and_return(token_client)
  end

  describe 'POST /api/v1/widget/voice_session' do
    it 'returns a token the browser can start a session with' do
      post '/api/v1/widget/voice_session', params: params, headers: { 'X-Auth-Token' => token }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['token']).to eq('tok_abc')
      expect(response.parsed_body['agent_id']).to eq('agent_widget_1')
    end

    it 'never exposes the raw conversation id, only a signed reference' do
      post '/api/v1/widget/voice_session', params: params, headers: { 'X-Auth-Token' => token }

      reference = response.parsed_body['voice_reference']
      resolved = Voice::Agent::WidgetSessionService.resolve_reference(reference)

      expect(resolved[:account_id]).to eq(account.id)
      expect(resolved[:conversation_id]).to eq(account.conversations.last.id)
    end

    it 'opens a conversation for a visitor who has not written yet' do
      expect { post '/api/v1/widget/voice_session', params: params, headers: { 'X-Auth-Token' => token } }
        .to change(Conversation, :count).by(1)
    end

    it 'reuses the visitor existing conversation' do
      conversation = create(:conversation, account: account, inbox: web_widget.inbox,
                                           contact: contact, contact_inbox: contact_inbox)

      expect { post '/api/v1/widget/voice_session', params: params, headers: { 'X-Auth-Token' => token } }
        .not_to change(Conversation, :count)

      reference = response.parsed_body['voice_reference']
      expect(Voice::Agent::WidgetSessionService.resolve_reference(reference)[:conversation_id]).to eq(conversation.id)
    end

    it 'is not found when the account has no widget agent configured' do
      account.update!(voice_widget_agent_id: nil)

      post '/api/v1/widget/voice_session', params: params, headers: { 'X-Auth-Token' => token }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']).to eq('voice_not_available')
    end

    it 'reports unavailable when ElevenLabs cannot mint a token' do
      allow(token_client).to receive(:webrtc_token)
        .and_raise(ElevenLabs::ConversationTokenClient::TokenError, 'boom')

      post '/api/v1/widget/voice_session', params: params, headers: { 'X-Auth-Token' => token }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body['error']).to eq('voice_unavailable')
    end

    it 'refuses an unauthenticated caller' do
      post '/api/v1/widget/voice_session', params: params

      expect(response).not_to have_http_status(:success)
    end
  end
end
