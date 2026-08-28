require 'rails_helper'

RSpec.describe Llm::SpeechToText::OpenAiProvider, type: :service do
  subject(:provider) { described_class.new(model: 'gpt-4o-mini-transcribe') }

  let(:audio_file_path) { Rails.root.join('tmp/open_ai_provider_spec.mp3').to_s }
  let(:audio_api) { double('audio_api') } # rubocop:disable RSpec/VerifiedDoubles

  before do
    InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |config| config.value = 'test-api-key' }
    File.binwrite(audio_file_path, 'audio')
  end

  after do
    FileUtils.rm_f(audio_file_path)
  end

  describe '#transcribe' do
    before do
      allow(provider.send(:client)).to receive(:audio).and_return(audio_api)
    end

    it 'sends the configured model at temperature zero' do
      expect(audio_api).to receive(:transcribe).with(
        parameters: hash_including(model: 'gpt-4o-mini-transcribe', temperature: 0.0)
      ).and_return({ 'text' => 'Audio transcript' })

      expect(provider.transcribe(audio_file_path)).to eq('Audio transcript')
    end
  end

  describe '.consumes_captain_credits?' do
    it 'is true because transcription runs on the Captain OpenAI key' do
      expect(described_class.consumes_captain_credits?).to be(true)
    end
  end

  describe 'client construction' do
    it 'does not build the OpenAI client until a transcription is requested' do
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.destroy!

      expect { described_class.new(model: 'whisper-1') }.not_to raise_error
    end

    it 'uses the configured endpoint override' do
      InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_ENDPOINT') { |config| config.value = 'https://proxy.test/' }

      expect(provider.send(:uri_base)).to eq('https://proxy.test/')
    end
  end
end
