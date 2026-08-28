# Blob-in, text-out audio transcription shared by voice-note attachments
# (Messages::AudioTranscriptionService) and voice-call recordings
# (Voice::CallTranscriptionService).
#
# Fetching the blob, metering and instrumentation live here; the API call itself
# is delegated to the adapter for whichever provider owns the model resolved for
# the audio_transcription feature. Callers stay provider-agnostic.
class Llm::SpeechToTextService
  include Integrations::LlmInstrumentation

  FEATURE = 'audio_transcription'.freeze

  PROVIDERS = {
    'openai' => 'Llm::SpeechToText::OpenAiProvider',
    'elevenlabs' => 'Llm::SpeechToText::ElevenLabsProvider'
  }.freeze
  DEFAULT_PROVIDER = 'openai'.freeze

  attr_reader :blob, :account, :transcription_model, :provider

  # Captain gates the *entitlement* for every provider — the feature flag and the
  # account setting. It gates the *balance* only when the provider spends
  # Captain's own credentials: ElevenLabs bills directly against
  # ELEVENLABS_API_KEY, so an exhausted response quota is no reason to refuse
  # work Captain is not paying for.
  def self.available_for?(account)
    return false unless account.feature_enabled?('captain_integration')
    return false if account.audio_transcriptions.blank?
    return true unless consumes_captain_credits?(account)

    account.usage_limits[:captain][:responses][:current_available].positive?
  end

  def self.consumes_captain_credits?(account)
    provider_class_for(resolve(account)[:provider]).consumes_captain_credits?
  end

  # The ceiling is the transcribing provider's, so pass the account whose
  # configuration will do the work. Without one this answers for the default
  # provider, which is what a caller with no account context can act on.
  def self.too_large?(blob, account: nil)
    return false if blob.blank?

    blob.byte_size > byte_limit_for(account)
  end

  def self.byte_limit_for(account = nil)
    provider_class_for(resolve(account)[:provider]).byte_limit
  end

  def self.resolve(account)
    Llm::FeatureRouter.resolve(feature: FEATURE, account: account)
  end

  def self.provider_class_for(provider)
    PROVIDERS.fetch(provider.to_s, PROVIDERS.fetch(DEFAULT_PROVIDER)).constantize
  end

  def initialize(blob:, account:)
    @blob = blob
    @account = account

    route = self.class.resolve(account)
    @transcription_model = route[:model]
    @provider = route[:provider].presence || DEFAULT_PROVIDER
  end

  def perform
    temp_file_path = fetch_audio_file

    transcribed_text = instrument_audio_transcription(instrumentation_params(temp_file_path)) do
      provider_client.transcribe(temp_file_path)
    end

    account.increment_response_usage if transcribed_text.present? && consumes_captain_credits?
    transcribed_text
  ensure
    FileUtils.rm_f(temp_file_path) if temp_file_path.present?
  end

  private

  def provider_client
    @provider_client ||= self.class.provider_class_for(provider).new(model: transcription_model)
  end

  def consumes_captain_credits?
    self.class.provider_class_for(provider).consumes_captain_credits?
  end

  def fetch_audio_file
    temp_dir = Rails.root.join('tmp/uploads/audio-transcriptions')
    FileUtils.mkdir_p(temp_dir)
    temp_file_name = "#{blob.key}-#{blob.filename}"

    if blob.filename.extension_without_delimiter.blank?
      extension = extension_from_content_type(blob.content_type)
      temp_file_name = "#{temp_file_name}.#{extension}" if extension.present?
    end

    temp_file_path = File.join(temp_dir, temp_file_name)

    File.open(temp_file_path, 'wb') do |file|
      blob.open do |blob_file|
        IO.copy_stream(blob_file, file)
      end
    end

    temp_file_path
  end

  def extension_from_content_type(content_type)
    subtype = content_type.to_s.downcase.split(';').first.to_s.split('/').last.to_s
    return if subtype.blank?

    {
      'x-m4a' => 'm4a',
      'x-wav' => 'wav',
      'x-mp3' => 'mp3'
    }.fetch(subtype, subtype)
  end

  def instrumentation_params(file_path)
    {
      span_name: 'llm.messages.audio_transcription',
      model: transcription_model,
      account_id: account&.id,
      feature_name: FEATURE,
      file_path: file_path
    }
  end
end
