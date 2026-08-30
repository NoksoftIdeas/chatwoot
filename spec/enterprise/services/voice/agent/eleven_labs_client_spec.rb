require 'rails_helper'

RSpec.describe Voice::Agent::ElevenLabsClient, type: :service do
  subject(:client) { described_class.new(agent_id: 'agent_abc123') }

  # The shape ElevenLabs actually returns, confirmed against the live API.
  let(:twiml) do
    <<~TWIML.strip
      <?xml version="1.0" encoding="UTF-8"?><Response><Connect>
      <Stream url="wss://api.elevenlabs.io/v1/convai/conversation">
      <Parameter name="conversation_id" value="conv_abc123" />
      </Stream></Connect></Response>
    TWIML
  end

  before do
    InstallationConfig.find_or_create_by!(name: 'ELEVENLABS_API_KEY') { |config| config.value = 'test-eleven-key' }
  end

  describe '#register_call' do
    it 'posts the call endpoints and returns the TwiML ElevenLabs hands back' do
      request = stub_request(:post, described_class::API_URL)
                .with(headers: { 'xi-api-key' => 'test-eleven-key' })
                .to_return(status: 200, headers: { content_type: 'application/xml' }, body: twiml)

      expect(client.register_call(from: '+15551110000', to: '+15552220000').twiml).to eq(twiml)
      expect(request).to have_been_requested
    end

    it 'sends the agent id, both numbers and the direction' do
      stub_request(:post, described_class::API_URL).to_return(status: 200, body: twiml)

      client.register_call(from: '+15551110000', to: '+15552220000')

      expect(
        a_request(:post, described_class::API_URL).with(
          body: hash_including(
            'agent_id' => 'agent_abc123',
            'from_number' => '+15551110000',
            'to_number' => '+15552220000',
            'direction' => 'inbound'
          )
        )
      ).to have_been_made
    end

    it 'passes dynamic variables so the agent can call back about this conversation' do
      stub_request(:post, described_class::API_URL).to_return(status: 200, body: twiml)

      client.register_call(from: '+1555', to: '+1666', dynamic_variables: { chatwoot_call_id: 42 })

      expect(
        a_request(:post, described_class::API_URL).with(
          body: hash_including(
            'conversation_initiation_client_data' => { 'dynamic_variables' => { 'chatwoot_call_id' => 42 } }
          )
        )
      ).to have_been_made
    end

    it 'omits the client data block when there are no dynamic variables' do
      stub_request(:post, described_class::API_URL).to_return(status: 200, body: twiml)

      client.register_call(from: '+1555', to: '+1666')

      matcher = a_request(:post, described_class::API_URL).with do |req|
        !JSON.parse(req.body).key?('conversation_initiation_client_data')
      end
      expect(matcher).to have_been_made
    end

    describe 'the conversation id ElevenLabs allocates at registration' do
      it 'is pulled off the Stream parameter' do
        stub_request(:post, described_class::API_URL).to_return(status: 200, body: twiml)

        expect(client.register_call(from: '+1555', to: '+1666').conversation_id).to eq('conv_abc123')
      end

      it 'is nil when the TwiML carries no such parameter' do
        bare = '<Response><Connect><Stream url="wss://x"/></Connect></Response>'
        stub_request(:post, described_class::API_URL).to_return(status: 200, body: bare)

        expect(client.register_call(from: '+1555', to: '+1666').conversation_id).to be_nil
      end

      it 'does not fail the call when the TwiML will not parse' do
        stub_request(:post, described_class::API_URL).to_return(status: 200, body: '<Response><broken')

        registration = client.register_call(from: '+1555', to: '+1666')

        expect(registration.twiml).to eq('<Response><broken')
        expect(registration.conversation_id).to be_nil
      end
    end

    context 'when the response is not raw TwiML' do
      it 'accepts a bare JSON string' do
        stub_request(:post, described_class::API_URL).to_return(status: 200, body: twiml.to_json)

        expect(client.register_call(from: '+1555', to: '+1666').twiml).to eq(twiml)
      end

      it 'accepts a wrapper object' do
        stub_request(:post, described_class::API_URL).to_return(status: 200, body: { twiml: twiml }.to_json)

        expect(client.register_call(from: '+1555', to: '+1666').twiml).to eq(twiml)
      end

      it 'raises when no TwiML can be found' do
        stub_request(:post, described_class::API_URL).to_return(status: 200, body: { unexpected: true }.to_json)

        expect { client.register_call(from: '+1555', to: '+1666') }
          .to raise_error(described_class::RegistrationError, /No TwiML/)
      end

      it 'raises on an empty body' do
        stub_request(:post, described_class::API_URL).to_return(status: 200, body: '')

        expect { client.register_call(from: '+1555', to: '+1666') }
          .to raise_error(described_class::RegistrationError, /empty body/)
      end
    end

    it 'surfaces an HTTP failure as a Faraday error for the caller to fall back on' do
      stub_request(:post, described_class::API_URL).to_return(status: 500, body: 'boom')

      expect { client.register_call(from: '+1555', to: '+1666') }.to raise_error(Faraday::ServerError)
    end

    it 'raises a configuration error when the API key is missing' do
      InstallationConfig.find_by(name: 'ELEVENLABS_API_KEY').destroy!

      expect { client.register_call(from: '+1555', to: '+1666') }
        .to raise_error(described_class::ConfigurationError, /ELEVENLABS_API_KEY/)
    end
  end
end
