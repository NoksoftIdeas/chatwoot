require 'rails_helper'

RSpec.describe ElevenLabs::ConversationTokenClient, type: :service do
  subject(:client) { described_class.new(agent_id: 'agent_widget_1') }

  before do
    InstallationConfig.find_or_create_by!(name: 'ELEVENLABS_API_KEY') { |c| c.value = 'test-eleven-key' }
  end

  describe '#webrtc_token' do
    it 'returns the token for the agent' do
      stub_request(:get, described_class::API_URL)
        .with(query: { agent_id: 'agent_widget_1' }, headers: { 'xi-api-key' => 'test-eleven-key' })
        .to_return(status: 200, body: { token: 'tok_abc' }.to_json)

      expect(client.webrtc_token).to eq('tok_abc')
    end

    it 'raises when no token comes back' do
      stub_request(:get, described_class::API_URL).with(query: hash_including({}))
                                                  .to_return(status: 200, body: { token: '' }.to_json)

      expect { client.webrtc_token }.to raise_error(described_class::TokenError, /no conversation token/)
    end

    it 'raises on an unparseable response' do
      stub_request(:get, described_class::API_URL).with(query: hash_including({}))
                                                  .to_return(status: 200, body: 'nope')

      expect { client.webrtc_token }.to raise_error(described_class::TokenError, /Unparseable/)
    end

    it 'surfaces an HTTP failure' do
      stub_request(:get, described_class::API_URL).with(query: hash_including({})).to_return(status: 500)

      expect { client.webrtc_token }.to raise_error(Faraday::ServerError)
    end

    it 'raises a configuration error with no API key' do
      InstallationConfig.find_by(name: 'ELEVENLABS_API_KEY').destroy!

      expect { client.webrtc_token }.to raise_error(described_class::ConfigurationError, /ELEVENLABS_API_KEY/)
    end
  end
end
