# Decides whether the AI agent or a human answers an inbound call.
#
# Kept out of the channel model because "fallback" needs live presence, which is
# a Redis lookup rather than a property of the channel.
class Voice::Agent::RoutingPolicy
  pattr_initialize [:inbox!, :call!, :direction!, :from!]

  AVAILABLE_STATUSES = %w[online].freeze

  def agent_answers?
    return false unless inbound_contact_leg?
    # Twilio re-requests the voice webhook after an escalation redirect; handing
    # the caller back to the AI here would loop them out of the handover.
    return false if call.escalated_from_agent?
    return false unless channel.respond_to?(:voice_agent_enabled?)
    return false unless channel.voice_agent_enabled?

    case channel.voice_agent_mode
    when 'always' then true
    when 'fallback' then human_available? == false
    else false
    end
  end

  private

  # Agent legs are browser clients joining the bridge and outbound legs already
  # have a human on them; only the contact's own inbound leg is eligible.
  def inbound_contact_leg?
    direction.to_s == 'inbound' && !from.to_s.start_with?('client:')
  end

  def channel
    @channel ||= inbox.channel
  end

  # "Available" means a member of this inbox who is present and not away/busy —
  # the same signal the dashboard shows agents about each other. A Redis outage
  # answers "unknown", and we treat unknown as available so a presence failure
  # routes callers to people rather than silently handing the line to the AI.
  def human_available?
    member_ids = inbox.members.pluck(:id).map(&:to_s)
    return true if member_ids.blank?

    available = OnlineStatusTracker.get_available_users(inbox.account_id)
    available.any? { |user_id, status| member_ids.include?(user_id.to_s) && AVAILABLE_STATUSES.include?(status.to_s) }
  rescue StandardError => e
    Rails.logger.error("VOICE_AGENT_PRESENCE_LOOKUP_FAILED inbox=#{inbox.id} #{e.class}: #{e.message}")
    true
  end
end
