require 'rails_helper'

RSpec.describe Llm::SpeechToText::ElevenLabsProvider, type: :service do
  subject(:provider) { described_class.new(model: 'scribe_v1') }

  let(:audio_file_path) { Rails.root.join('tmp/eleven_labs_provider_spec.mp3').to_s }

  before do
    InstallationConfig.find_or_create_by!(name: 'ELEVENLABS_API_KEY') { |config| config.value = 'test-eleven-key' }
    File.binwrite(audio_file_path, 'audio')
  end

  after do
    FileUtils.rm_f(audio_file_path)
  end

  describe '#transcribe' do
    it 'posts the audio to Scribe and returns the transcript text' do
      request = stub_request(:post, described_class::API_URL)
                .with(headers: { 'xi-api-key' => 'test-eleven-key' })
                .to_return(
                  status: 200,
                  headers: { content_type: 'application/json' },
                  body: { language_code: 'eng', text: 'Audio transcript', words: [] }.to_json
                )

      expect(provider.transcribe(audio_file_path)).to eq('Audio transcript')
      expect(request).to have_been_requested
    end

    it 'sends the resolved model id and suppresses audio event tags' do
      stub_request(:post, described_class::API_URL)
        .to_return(status: 200, headers: { content_type: 'application/json' }, body: { text: 'ok' }.to_json)

      provider.transcribe(audio_file_path)

      expect(a_request(:post, described_class::API_URL).with(body: /name="model_id"/)).to have_been_made
      expect(a_request(:post, described_class::API_URL).with(body: /scribe_v1/)).to have_been_made
      expect(a_request(:post, described_class::API_URL).with(body: /name="tag_audio_events"/)).to have_been_made
    end

    it 'raises Faraday::UnauthorizedError on a rejected key so callers can skip transcription' do
      stub_request(:post, described_class::API_URL).to_return(status: 401, body: '{}')

      expect { provider.transcribe(audio_file_path) }.to raise_error(Faraday::UnauthorizedError)
    end

    it 'raises Faraday::BadRequestError on an unusable file so the job discards' do
      stub_request(:post, described_class::API_URL).to_return(status: 400, body: '{}')

      expect { provider.transcribe(audio_file_path) }.to raise_error(Faraday::BadRequestError)
    end

    it 'raises a configuration error when the response is not JSON' do
      stub_request(:post, described_class::API_URL).to_return(status: 200, body: 'not json')

      expect { provider.transcribe(audio_file_path) }
        .to raise_error(described_class::ResponseError, /Unparseable ElevenLabs response/)
    end
  end

  describe 'api key' do
    it 'raises a configuration error when the key is missing' do
      InstallationConfig.find_by(name: 'ELEVENLABS_API_KEY').destroy!

      expect { provider.transcribe(audio_file_path) }
        .to raise_error(described_class::ConfigurationError, 'ELEVENLABS_API_KEY is not configured')
    end
  end

  describe '.consumes_captain_credits?' do
    it 'spends no captain credit because ElevenLabs bills the key directly' do
      expect(described_class.consumes_captain_credits?).to be(false)
    end
  end

  describe '.byte_limit' do
    it 'is well past the OpenAI ceiling so long recordings still transcribe' do
      expect(described_class.byte_limit).to be > Llm::SpeechToText::OpenAiProvider.byte_limit
    end
  end
end
