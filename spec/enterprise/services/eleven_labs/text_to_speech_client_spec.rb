require 'rails_helper'

RSpec.describe ElevenLabs::TextToSpeechClient, type: :service do
  subject(:client) { described_class.new }

  let(:audio) { 'fake-mp3-bytes' }

  before do
    InstallationConfig.find_or_create_by!(name: 'ELEVENLABS_API_KEY') { |c| c.value = 'test-eleven-key' }
  end

  def endpoint_for(voice_id)
    "#{described_class::API_ROOT}/#{voice_id}?output_format=#{described_class::OUTPUT_FORMAT}"
  end

  describe '#synthesize' do
    it 'returns the audio bytes for the default voice' do
      stub_request(:post, endpoint_for(described_class::DEFAULT_VOICE_ID))
        .with(headers: { 'xi-api-key' => 'test-eleven-key' })
        .to_return(status: 200, body: audio)

      expect(client.synthesize('Hello there')).to eq(audio)
    end

    it 'sends the text and the resolved model' do
      stub_request(:post, endpoint_for(described_class::DEFAULT_VOICE_ID)).to_return(status: 200, body: audio)

      client.synthesize('Hello there')

      expect(
        a_request(:post, endpoint_for(described_class::DEFAULT_VOICE_ID))
          .with(body: { text: 'Hello there', model_id: described_class::DEFAULT_MODEL })
      ).to have_been_made
    end

    it 'uses the voice the caller asked for' do
      stub_request(:post, endpoint_for('voice_custom')).to_return(status: 200, body: audio)

      expect(described_class.new(voice_id: 'voice_custom').synthesize('Hi')).to eq(audio)
    end

    it 'falls back to the installation voice when the caller names none' do
      InstallationConfig.find_or_create_by!(name: 'ELEVENLABS_TTS_VOICE_ID') { |c| c.value = 'voice_installation' }
      stub_request(:post, endpoint_for('voice_installation')).to_return(status: 200, body: audio)

      expect(client.synthesize('Hi')).to eq(audio)
    end

    it 'prefers the caller voice over the installation one' do
      InstallationConfig.find_or_create_by!(name: 'ELEVENLABS_TTS_VOICE_ID') { |c| c.value = 'voice_installation' }

      expect(described_class.new(voice_id: 'voice_caller').resolved_voice_id).to eq('voice_caller')
    end

    it 'uses the installation model override' do
      InstallationConfig.find_or_create_by!(name: 'ELEVENLABS_TTS_MODEL') { |c| c.value = 'eleven_multilingual_v2' }

      expect(client.resolved_model).to eq('eleven_multilingual_v2')
    end

    it 'refuses blank text' do
      expect { client.synthesize('  ') }.to raise_error(ArgumentError, /text is required/)
    end

    it 'refuses text past the character ceiling' do
      expect { client.synthesize('a' * (described_class::MAX_CHARACTERS + 1)) }
        .to raise_error(ArgumentError, /exceeds/)
    end

    it 'raises a configuration error with no API key' do
      InstallationConfig.find_by(name: 'ELEVENLABS_API_KEY').destroy!

      expect { client.synthesize('Hi') }.to raise_error(described_class::ConfigurationError, /ELEVENLABS_API_KEY/)
    end

    it 'surfaces an HTTP failure' do
      stub_request(:post, endpoint_for(described_class::DEFAULT_VOICE_ID)).to_return(status: 500, body: 'boom')

      expect { client.synthesize('Hi') }.to raise_error(Faraday::ServerError)
    end
  end

  describe '.too_long?' do
    it 'is false at the ceiling and true past it' do
      expect(described_class.too_long?('a' * described_class::MAX_CHARACTERS)).to be(false)
      expect(described_class.too_long?('a' * (described_class::MAX_CHARACTERS + 1))).to be(true)
    end
  end
end
