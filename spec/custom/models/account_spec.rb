require 'rails_helper'

# Exercises Custom::Account through Account's public interface -- the module is
# prepended by config/initializers/01_inject_enterprise_edition_module.rb.
RSpec.describe Account do
  let(:account) { create(:account) }

  describe '#feature_enabled? with CUSTOM_FORCED_FEATURES unset' do
    it 'reports a disabled premium feature as disabled' do
      expect(account).not_to be_feature_enabled('disable_branding')
    end

    it 'still reports genuinely enabled features as enabled' do
      account.enable_features!('disable_branding')

      expect(account.reload).to be_feature_enabled('disable_branding')
    end
  end

  describe '#feature_enabled? with CUSTOM_FORCED_FEATURES set' do
    it 'forces the listed feature on without touching the stored bitset' do
      with_modified_env CUSTOM_FORCED_FEATURES: 'disable_branding' do
        expect(account).to be_feature_enabled('disable_branding')
        # The stored bit stays off, so the daily plan reconciliation in
        # enterprise builds has nothing to strip.
        expect(account).not_to be_feature_disable_branding
      end
    end

    it 'stops forcing once the env var is gone' do
      with_modified_env CUSTOM_FORCED_FEATURES: 'disable_branding' do
        expect(account).to be_feature_enabled('disable_branding')
      end

      expect(account).not_to be_feature_enabled('disable_branding')
    end

    it 'reports the forced feature through enabled_features too' do
      # feature_enabled? backs all_features, so the dashboard payload and the
      # view checks agree rather than disagreeing.
      with_modified_env CUSTOM_FORCED_FEATURES: 'disable_branding' do
        expect(account.enabled_features.keys).to include('disable_branding')
      end
    end

    it 'leaves features outside the list alone' do
      with_modified_env CUSTOM_FORCED_FEATURES: 'disable_branding' do
        expect(account).not_to be_feature_enabled('audit_logs')
      end
    end

    it 'accepts several features' do
      with_modified_env CUSTOM_FORCED_FEATURES: 'disable_branding,audit_logs' do
        expect(account).to be_feature_enabled('disable_branding')
        expect(account).to be_feature_enabled('audit_logs')
      end
    end

    it 'ignores whitespace and casing' do
      with_modified_env CUSTOM_FORCED_FEATURES: '  Disable_Branding , AUDIT_LOGS  ' do
        expect(account).to be_feature_enabled('disable_branding')
        expect(account).to be_feature_enabled('audit_logs')
      end
    end

    it 'treats a list of only separators as unset' do
      with_modified_env CUSTOM_FORCED_FEATURES: ' , ,' do
        expect(account).not_to be_feature_enabled('disable_branding')
      end
    end

    it 'accepts a symbol as well as a string' do
      with_modified_env CUSTOM_FORCED_FEATURES: 'disable_branding' do
        expect(account).to be_feature_enabled(:disable_branding)
      end
    end
  end
end
