# Fork-local override of Account.
#
# Prepended via `Account.prepend_mod_with('Account')` at the bottom of
# app/models/account.rb.
#
# Pins chosen feature flags on regardless of what is stored in the account's
# bitset. Driven by CUSTOM_FORCED_FEATURES, a comma-separated list:
#
#   CUSTOM_FORCED_FEATURES=disable_branding
#
# Why this exists rather than just calling `account.enable_features!`:
# in builds where enterprise/ is present, Internal::ReconcilePlanConfigService
# runs daily (config/schedule.yml) and strips premium flags off accounts that
# are not on the plan, so a stored flag silently reverts. Forcing it at read
# time survives that. In a CE build nothing reconciles, so a stored flag is
# enough and this override is optional.
#
# Inert when the env var is unset.
module Custom::Account
  def feature_enabled?(name)
    return true if custom_forced_features.include?(name.to_s)

    super
  end

  private

  # Prefixed to avoid colliding with anything upstream might add to Account.
  #
  # Deliberately not memoized. An `@ivar ||=` here survives `reload` (which
  # refreshes attributes, not instance variables), so an instance that read the
  # env once would keep answering from the stale list forever. In production the
  # env is static so it would not matter, but it makes the behaviour confusing
  # and untestable. Parsing a short string is cheap enough to just redo.
  def custom_forced_features
    ENV.fetch('CUSTOM_FORCED_FEATURES', '')
       .split(',')
       .filter_map { |feature| feature.strip.downcase.presence }
  end
end
