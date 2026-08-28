module Llm::FeatureRouter
  class UnknownFeatureError < StandardError; end

  CAPTAIN_V2_ASSISTANT_MODEL = 'gpt-5.2'.freeze

  # Features whose model can be pinned instance-wide from Super Admin > App Configs.
  INSTALLATION_MODEL_CONFIGS = {
    'conversation_completion' => 'CAPTAIN_OPEN_AI_MODEL',
    'audio_transcription' => 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL'
  }.freeze

  # CAPTAIN_OPEN_AI_MODEL is deliberately unvalidated so self-hosted installs can
  # point Captain at a custom OpenAI-compatible model behind CAPTAIN_OPEN_AI_ENDPOINT.
  # Transcription has no such escape hatch and spans providers, so an unrecognised
  # value there must fall back to the default rather than route to the wrong API.
  VALIDATED_INSTALLATION_FEATURES = %w[audio_transcription].freeze

  class << self
    def resolve(feature:, account: nil)
      feature_key = feature.to_s
      raise UnknownFeatureError, "Unknown LLM feature: #{feature_key}" unless Llm::Models.feature?(feature_key)

      model, source = model_and_source(account, feature_key)

      {
        feature: feature_key,
        provider: provider_for(model, source),
        model: model,
        source: source
      }
    end

    private

    def model_and_source(account, feature_key)
      account_model = account_model_override(account, feature_key)
      return [account_model, :account_override] if account_model.present?

      installation_model = installation_model_override(feature_key)
      return [installation_model, :installation_override] if installation_model.present?

      [captain_v2_assistant_model(account, feature_key) || Llm::Models.default_model_for(feature_key), :default]
    end

    def account_model_override(account, feature_key)
      model = account&.captain_models&.[](feature_key).presence
      return unless model
      return model if Llm::Models.valid_model_for?(feature_key, model)
    end

    def installation_model_override(feature_key)
      config_name = INSTALLATION_MODEL_CONFIGS[feature_key]
      return if config_name.blank?
      return unless ChatwootApp.self_hosted_enterprise?

      model = InstallationConfig.find_by(name: config_name)&.value.presence
      return if model.blank?
      return model unless VALIDATED_INSTALLATION_FEATURES.include?(feature_key)

      model if Llm::Models.valid_model_for?(feature_key, model)
    end

    def provider_for(model, source)
      Llm::Models.provider_for(model) || ('openai' if source == :installation_override)
    end

    def captain_v2_assistant_model(account, feature_key)
      return unless feature_key == 'assistant'
      return unless account&.feature_enabled?('captain_integration_v2')

      CAPTAIN_V2_ASSISTANT_MODEL
    end
  end
end
