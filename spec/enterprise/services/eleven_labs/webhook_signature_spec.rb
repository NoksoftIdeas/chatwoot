require 'rails_helper'

RSpec.describe ElevenLabs::WebhookSignature do
  let(:secret) { 'whsec_test_secret' }
  let(:payload) { { type: 'post_call_transcription' }.to_json }
  let(:timestamp) { Time.zone.now.to_i }

  def sign(signed_at: timestamp, body: payload, key: secret)
    "t=#{signed_at},v0=#{OpenSSL::HMAC.hexdigest('SHA256', key, "#{signed_at}.#{body}")}"
  end

  describe '.valid?' do
    it 'accepts a correctly signed payload' do
      expect(described_class.valid?(payload: payload, header: sign, secret: secret)).to be(true)
    end

    it 'rejects a signature made with a different secret' do
      expect(described_class.valid?(payload: payload, header: sign(key: 'other'), secret: secret)).to be(false)
    end

    it 'rejects a signature over different bytes' do
      expect(described_class.valid?(payload: '{"tampered":true}', header: sign, secret: secret)).to be(false)
    end

    it 'rejects a timestamp outside the replay window' do
      stale = described_class::TOLERANCE.to_i + 60
      header = sign(signed_at: timestamp - stale)

      expect(described_class.valid?(payload: payload, header: header, secret: secret)).to be(false)
    end

    it 'accepts a timestamp inside the replay window' do
      header = sign(signed_at: timestamp - 60)

      expect(described_class.valid?(payload: payload, header: header, secret: secret)).to be(true)
    end

    it 'rejects a future timestamp beyond the window' do
      header = sign(signed_at: timestamp + described_class::TOLERANCE.to_i + 60)

      expect(described_class.valid?(payload: payload, header: header, secret: secret)).to be(false)
    end

    it 'rejects a malformed header' do
      expect(described_class.valid?(payload: payload, header: 'garbage', secret: secret)).to be(false)
    end

    it 'rejects a header missing the signature component' do
      expect(described_class.valid?(payload: payload, header: "t=#{timestamp}", secret: secret)).to be(false)
    end

    it 'rejects blank inputs' do
      expect(described_class.valid?(payload: payload, header: sign, secret: '')).to be(false)
      expect(described_class.valid?(payload: '', header: sign, secret: secret)).to be(false)
      expect(described_class.valid?(payload: payload, header: nil, secret: secret)).to be(false)
    end
  end
end
