require 'rails_helper'

RSpec.describe Llm::SpeechToTextService, type: :service do
  let(:account) { create(:account, audio_transcriptions: true) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) { create(:message, account: account, conversation: conversation) }
  let(:attachment) { message.attachments.create!(account: account, file_type: :audio) }
  let(:service) { described_class.new(blob: attachment.file.blob, account: account) }

  before do
    InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |config| config.value = 'test-api-key' }
    InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_MODEL') { |config| config.value = 'gpt-4o-mini' }

    attachment.file.attach(
      io: File.open(Rails.public_path.join('audio/widget/ding.mp3')),
      filename: 'speech',
      content_type: 'audio/mpeg'
    )
  end

  describe '.available_for?' do
    before do
      allow(account).to receive(:usage_limits).and_return(
        {
          agents: ChatwootApp.max_limit,
          inboxes: ChatwootApp.max_limit,
          captain: { responses: { current_available: 100 } }
        }
      )
    end

    it 'is false when the captain_integration feature is disabled' do
      account.disable_features!('captain_integration')

      expect(described_class.available_for?(account)).to be(false)
    end

    it 'is false when audio transcriptions are disabled on the account' do
      account.enable_features!('captain_integration')
      account.update!(audio_transcriptions: false)

      expect(described_class.available_for?(account)).to be(false)
    end

    it 'is false when no captain responses are available' do
      account.enable_features!('captain_integration')
      allow(account).to receive(:usage_limits).and_return(captain: { responses: { current_available: 0 } })

      expect(described_class.available_for?(account)).to be(false)
    end

    it 'is true when the feature, setting and credits are all present' do
      account.enable_features!('captain_integration')

      expect(described_class.available_for?(account)).to be(true)
    end

    it 'ignores an exhausted captain balance when the account transcribes on ElevenLabs' do
      account.enable_features!('captain_integration')
      account.update!(captain_models: { 'audio_transcription' => 'scribe_v1' })
      allow(account).to receive(:usage_limits).and_return(captain: { responses: { current_available: 0 } })

      expect(described_class.available_for?(account)).to be(true)
    end

    it 'still requires the captain feature flag on ElevenLabs' do
      account.disable_features!('captain_integration')
      account.update!(captain_models: { 'audio_transcription' => 'scribe_v1' })

      expect(described_class.available_for?(account)).to be(false)
    end

    it 'still requires the account setting on ElevenLabs' do
      account.enable_features!('captain_integration')
      account.update!(audio_transcriptions: false, captain_models: { 'audio_transcription' => 'scribe_v1' })

      expect(described_class.available_for?(account)).to be(false)
    end
  end

  describe '.consumes_captain_credits?' do
    it 'is true on the default OpenAI provider' do
      expect(described_class.consumes_captain_credits?(account)).to be(true)
    end

    it 'is false when the account transcribes on ElevenLabs' do
      account.update!(captain_models: { 'audio_transcription' => 'scribe_v1' })

      expect(described_class.consumes_captain_credits?(account)).to be(false)
    end
  end

  describe '.provider_class_for' do
    it 'maps each registered provider to its adapter' do
      expect(described_class.provider_class_for('openai')).to eq(Llm::SpeechToText::OpenAiProvider)
      expect(described_class.provider_class_for('elevenlabs')).to eq(Llm::SpeechToText::ElevenLabsProvider)
    end

    it 'falls back to OpenAI for an unknown provider' do
      expect(described_class.provider_class_for('nope')).to eq(Llm::SpeechToText::OpenAiProvider)
    end
  end

  describe '.too_large?' do
    it 'is false when the blob is missing' do
      expect(described_class.too_large?(nil)).to be(false)
    end

    it 'is true beyond the OpenAI byte limit by default' do
      allow(attachment.file.blob).to receive(:byte_size).and_return(Llm::SpeechToText::OpenAiProvider::BYTE_LIMIT + 1)

      expect(described_class.too_large?(attachment.file.blob, account: account)).to be(true)
    end

    it 'allows audio past the OpenAI limit when the account transcribes on ElevenLabs' do
      account.update!(captain_models: { 'audio_transcription' => 'scribe_v1' })
      allow(attachment.file.blob).to receive(:byte_size).and_return(Llm::SpeechToText::OpenAiProvider::BYTE_LIMIT + 1)

      expect(described_class.too_large?(attachment.file.blob, account: account)).to be(false)
    end

    it 'is true beyond the ElevenLabs byte limit' do
      account.update!(captain_models: { 'audio_transcription' => 'scribe_v1' })
      allow(attachment.file.blob).to receive(:byte_size).and_return(Llm::SpeechToText::ElevenLabsProvider::BYTE_LIMIT + 1)

      expect(described_class.too_large?(attachment.file.blob, account: account)).to be(true)
    end
  end

  describe '#fetch_audio_file' do
    it 'adds extension from content type when filename has no extension' do
      temp_file_path = service.send(:fetch_audio_file)

      expect(File.extname(temp_file_path)).to eq('.mpeg')
    ensure
      FileUtils.rm_f(temp_file_path) if temp_file_path.present?
    end
  end

  describe '#perform' do
    let(:audio_file_path) { Rails.root.join('tmp/speech_to_text_service_spec.mp3').to_s }
    let(:provider) { instance_double(Llm::SpeechToText::OpenAiProvider) }

    before do
      File.binwrite(audio_file_path, 'audio')
      allow(service).to receive_messages(fetch_audio_file: audio_file_path, provider_client: provider)
      allow(account).to receive(:increment_response_usage)
    end

    after do
      FileUtils.rm_f(audio_file_path)
    end

    it 'delegates the transcription to the provider adapter' do
      expect(provider).to receive(:transcribe).with(audio_file_path).and_return('Audio transcript')

      expect(service.perform).to eq('Audio transcript')
    end

    it 'consumes a captain response credit when text comes back' do
      allow(provider).to receive(:transcribe).and_return('Audio transcript')

      service.perform

      expect(account).to have_received(:increment_response_usage)
    end

    it 'does not consume a credit when the transcription is blank' do
      allow(provider).to receive(:transcribe).and_return('')

      service.perform

      expect(account).not_to have_received(:increment_response_usage)
    end

    it 'removes the temp file even when the provider raises' do
      allow(provider).to receive(:transcribe).and_raise(Faraday::BadRequestError.new('nope'))

      expect { service.perform }.to raise_error(Faraday::BadRequestError)
      expect(File.exist?(audio_file_path)).to be(false)
    end

    context 'when the account transcribes on ElevenLabs' do
      let(:account) { create(:account, audio_transcriptions: true, captain_models: { 'audio_transcription' => 'scribe_v1' }) }
      let(:provider) { instance_double(Llm::SpeechToText::ElevenLabsProvider) }

      it 'does not consume a captain response credit' do
        allow(provider).to receive(:transcribe).and_return('Audio transcript')

        expect(service.perform).to eq('Audio transcript')
        expect(account).not_to have_received(:increment_response_usage)
      end
    end
  end

  describe 'provider resolution' do
    it 'defaults to the OpenAI transcription model' do
      expect(service.provider).to eq('openai')
      expect(service.transcription_model).to eq('gpt-4o-mini-transcribe')
      expect(service.send(:provider_client)).to be_a(Llm::SpeechToText::OpenAiProvider)
    end

    it 'builds the ElevenLabs adapter when the account selects Scribe' do
      account.update!(captain_models: { 'audio_transcription' => 'scribe_v1' })

      expect(service.provider).to eq('elevenlabs')
      expect(service.transcription_model).to eq('scribe_v1')
      expect(service.send(:provider_client)).to be_a(Llm::SpeechToText::ElevenLabsProvider)
    end
  end
end
