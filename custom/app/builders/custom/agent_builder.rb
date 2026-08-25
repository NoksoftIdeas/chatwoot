# Fork-local override of AgentBuilder.
#
# This module is prepended onto AgentBuilder by
# config/initializers/01_inject_enterprise_edition_module.rb, which is driven by
# the `AgentBuilder.prepend_mod_with('AgentBuilder')` call at the bottom of
# app/builders/agent_builder.rb. Nothing here is wired up by hand.
#
# Because it is a *prepend*, `super` runs the upstream implementation (or
# Enterprise::AgentBuilder, if enterprise code is active -- Custom:: sits ahead
# of Enterprise:: in the ancestor chain). Keep overrides thin and always call
# super: that is what keeps `git pull upstream develop` conflict-free.
#
# Behaviour here: refuse agent invites whose email is outside an allowlist of
# domains. Disabled when the env var is unset, so it is inert by default.
module Custom::AgentBuilder
  def perform
    validate_email_domain!
    super
  end

  private

  def allowed_email_domains
    @allowed_email_domains ||= ENV.fetch('AGENT_EMAIL_DOMAIN_ALLOWLIST', '')
                                  .split(',')
                                  .filter_map { |domain| domain.strip.downcase.presence }
  end

  def validate_email_domain!
    return if allowed_email_domains.empty?
    return if allowed_email_domains.any? { |domain| email.to_s.downcase.end_with?("@#{domain}") }

    # Mirrors how Enterprise::AgentBuilder surfaces a rejection: attach the
    # error to a User and raise, so the controller renders it like any other
    # validation failure rather than a 500.
    invalid_user = User.new(email: email)
    invalid_user.errors.add(:email, "must belong to one of: #{allowed_email_domains.join(', ')}")
    raise ActiveRecord::RecordInvalid, invalid_user
  end
end
