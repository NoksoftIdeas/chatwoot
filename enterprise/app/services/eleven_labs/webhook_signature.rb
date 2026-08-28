# Verifies the ElevenLabs-Signature header on webhooks ElevenLabs sends us.
#
#   ElevenLabs-Signature: t=<unix_timestamp>,v0=<hex_hmac_sha256>
#
# The signed message is "<timestamp>.<raw_body>", so verification has to run on
# the raw request body — re-serialising parsed params would change the bytes and
# every signature would fail.
module ElevenLabs::WebhookSignature
  # ElevenLabs signs with a 5 minute replay window; matching it means a captured
  # request stops being replayable at the same time on both sides.
  TOLERANCE = 5.minutes

  class << self
    def valid?(payload:, header:, secret:, tolerance: TOLERANCE)
      return false if payload.blank? || header.blank? || secret.blank?

      timestamp, signature = parse(header)
      return false if timestamp.blank? || signature.blank?
      return false unless recent?(timestamp, tolerance)

      matches?(timestamp, payload, signature, secret)
    end

    private

    def parse(header)
      parts = header.to_s.split(',').to_h do |part|
        key, _, value = part.strip.partition('=')
        [key, value]
      end

      [parts['t'], parts['v0']]
    rescue StandardError
      [nil, nil]
    end

    def recent?(timestamp, tolerance)
      (Time.zone.now.to_i - timestamp.to_i).abs <= tolerance.to_i
    end

    def matches?(timestamp, payload, signature, secret)
      expected = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{payload}")
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end
  end
end
