# Hands a live Twilio call to an ElevenLabs agent.
#
# ElevenLabs' "register call" endpoint is the one integration path that leaves
# the phone number, its webhook and the Twilio credentials with us: we POST the
# call's endpoints, ElevenLabs answers with TwiML, and we hand that straight
# back to Twilio. The alternative paths either import the number into ElevenLabs
# (Chatwoot would never see the call) or require us to run a websocket bridge
# relaying media ourselves.
#
# https://elevenlabs.io/docs/api-reference/twilio/register-call
class Voice::Agent::ElevenLabsClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class RegistrationError < Error; end

  API_URL = 'https://api.elevenlabs.io/v1/convai/twilio/register-call'.freeze

  # This runs inside Twilio's inbound webhook, which Twilio abandons after 15s.
  # Stay well inside that so a slow ElevenLabs still leaves us time to fall back
  # to the human conference rather than dropping the caller.
  TIMEOUT = 8
  OPEN_TIMEOUT = 3

  pattr_initialize [:agent_id!]

  # Returns TwiML (String) for Twilio to render.
  def register_call(from:, to:, direction: 'inbound', dynamic_variables: {})
    response = connection.post(API_URL, payload(from, to, direction, dynamic_variables).to_json)
    extract_twiml(response)
  end

  private

  def payload(from, to, direction, dynamic_variables)
    body = {
      agent_id: agent_id,
      from_number: from,
      to_number: to,
      direction: direction
    }
    # Dynamic variables are how the agent learns which Chatwoot call it is on;
    # its escalation tool passes them back to us. See Voice::Agent::CallContext.
    body[:conversation_initiation_client_data] = { dynamic_variables: dynamic_variables } if dynamic_variables.present?
    body
  end

  # The endpoint is documented as returning "string". Observed shapes differ by
  # SDK version, so accept the raw TwiML body, a JSON string, or a wrapper
  # object rather than guessing one and failing closed on a live call.
  def extract_twiml(response)
    body = response.body.to_s
    raise RegistrationError, 'ElevenLabs returned an empty body' if body.blank?
    return body if body.lstrip.start_with?('<')

    parsed = JSON.parse(body)
    twiml = parsed.is_a?(Hash) ? parsed.values_at('twiml', 'twiml_response', 'response').compact.first : parsed
    raise RegistrationError, "No TwiML in ElevenLabs response: #{body.truncate(200)}" unless twiml.is_a?(String) && twiml.present?

    twiml
  rescue JSON::ParserError
    raise RegistrationError, "Unparseable ElevenLabs response: #{body.truncate(200)}"
  end

  def connection
    Faraday.new(headers: { 'xi-api-key' => api_key, 'Content-Type' => 'application/json' }) do |f|
      f.response :raise_error
      f.options.timeout = TIMEOUT
      f.options.open_timeout = OPEN_TIMEOUT
    end
  end

  def api_key
    ElevenLabs::Credentials.api_key!
  rescue ElevenLabs::Credentials::MissingApiKeyError => e
    raise ConfigurationError, e.message
  end
end
