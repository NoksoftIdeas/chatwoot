# Make DISABLE_ENTERPRISE behave the way anyone would expect.
#
# Upstream's gate is:
#
#   def self.enterprise?
#     return if ENV.fetch('DISABLE_ENTERPRISE', false)
#     @enterprise ||= root.join('enterprise').exist?
#   end
#
# ENV.fetch returns a String and every String is truthy in Ruby, so "false",
# "0" and even "" disable enterprise exactly as effectively as "true". Only
# absence of the variable leaves it on.
#
# That is a trap on platforms that manage env vars for you: Coolify creates a
# row for any key referenced by the compose file and injects it even when the
# value is blank, which silently switches off every enterprise feature with no
# error and nothing in the logs. We lost an afternoon to precisely that.
#
# This normalises the falsy spellings to "absent" before anything reads the
# gate. Explicitly setting DISABLE_ENTERPRISE=true still works.
#
# Load order matters and is safe: config/application.rb requires this file from
# inside the Application class body, which runs before config/initializers/* --
# and 01_inject_enterprise_edition_module.rb is the first thing to call
# ChatwootApp.enterprise? and memoise it.

FALSY_DISABLE_ENTERPRISE = ['', 'false', '0', 'no', 'off'].freeze

raw = ENV.fetch('DISABLE_ENTERPRISE', nil)

if raw && FALSY_DISABLE_ENTERPRISE.include?(raw.to_s.strip.downcase)
  warn "[custom] DISABLE_ENTERPRISE=#{raw.inspect} reads as falsy; unsetting it so enterprise stays enabled."
  ENV.delete('DISABLE_ENTERPRISE')
end
