require 'rails_helper'

RSpec.describe Voice::Agent::PostCallIngestionService, type: :service do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation, content_type: :voice_call) }
  let(:call) do
    create(:call, account: account, inbox: inbox, conversation: conversation,
                  contact: conversation.contact, status: 'completed', message: message)
  end

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'AP123'))
  end

  def transcript_payload(turns, call_id: call.id.to_s)
    {
      'type' => 'post_call_transcription',
      'data' => {
        'conversation_id' => 'conv_xyz',
        'transcript' => turns,
        'conversation_initiation_client_data' => { 'dynamic_variables' => { 'chatwoot_call_id' => call_id } }
      }
    }
  end

  def audio_payload(encoded, call_id: call.id.to_s)
    {
      'type' => 'post_call_audio',
      'data' => {
        'full_audio' => encoded,
        'conversation_initiation_client_data' => { 'dynamic_variables' => { 'chatwoot_call_id' => call_id } }
      }
    }
  end

  describe '#perform' do
    it 'stores a speaker-labelled transcript on the call' do
      payload = transcript_payload([
                                     { 'role' => 'agent', 'message' => 'How can I help?' },
                                     { 'role' => 'user', 'message' => 'I need a refund.' }
                                   ])

      expect(described_class.new(payload: payload).perform).to eq(:transcript_stored)
      expect(call.reload.transcript).to eq("Agent: How can I help?\nCaller: I need a refund.")
    end

    it 'records the ElevenLabs conversation id alongside the transcript' do
      described_class.new(payload: transcript_payload([{ 'role' => 'agent', 'message' => 'Hi' }])).perform

      expect(call.reload.voice_agent_conversation_id).to eq('conv_xyz')
    end

    it 'skips turns with no text' do
      payload = transcript_payload([
                                     { 'role' => 'agent', 'message' => 'Hi' },
                                     { 'role' => 'user', 'message' => '  ' },
                                     'not-a-hash'
                                   ])

      described_class.new(payload: payload).perform

      expect(call.reload.transcript).to eq('Agent: Hi')
    end

    it 'reports an empty transcript without touching the call' do
      expect(described_class.new(payload: transcript_payload([])).perform).to eq(:empty)
      expect(call.reload.transcript).to be_nil
    end

    it 'attaches the audio as the call recording' do
      encoded = Base64.strict_encode64(File.binread(Rails.public_path.join('audio/widget/ding.mp3')))

      expect(described_class.new(payload: audio_payload(encoded)).perform).to eq(:audio_stored)
      expect(call.reload.recording).to be_attached
    end

    context 'when the transcript belongs to a widget voice session' do
      let(:widget_account) { create(:account, voice_widget_agent_id: 'agent_widget_1') }
      let(:widget_inbox) { create(:inbox, account: widget_account) }
      let(:widget_conversation) { create(:conversation, account: widget_account, inbox: widget_inbox) }
      let(:reference) do
        Voice::Agent::WidgetSessionService.new(conversation: widget_conversation).send(:signed_reference)
      end

      def widget_payload(turns, ref: reference, session_id: 'conv_widget_1')
        {
          'type' => 'post_call_transcription',
          'data' => {
            'conversation_id' => session_id,
            'transcript' => turns,
            'conversation_initiation_client_data' => { 'dynamic_variables' => { 'chatwoot_voice_reference' => ref } }
          }
        }
      end

      it 'writes each turn into the conversation with the right direction' do
        payload = widget_payload([
                                   { 'role' => 'user', 'message' => 'Where is my order?' },
                                   { 'role' => 'agent', 'message' => 'Let me check.' }
                                 ])

        expect(described_class.new(payload: payload).perform).to eq(:transcript_stored)

        messages = widget_conversation.messages.order(:id)
        expect(messages.map(&:content)).to eq(['Where is my order?', 'Let me check.'])
        expect(messages.map(&:message_type)).to eq(%w[incoming outgoing])
      end

      it 'never speaks a transcribed turn back through TTS' do
        widget_account.update!(voice_replies: true)
        payload = widget_payload([{ 'role' => 'agent', 'message' => 'Let me check.' }])

        described_class.new(payload: payload).perform

        expect(Messages::VoiceReplyJob).not_to have_been_enqueued
      end

      it 'is idempotent when ElevenLabs redelivers the webhook' do
        payload = widget_payload([{ 'role' => 'user', 'message' => 'Hello' }])

        described_class.new(payload: payload).perform
        expect(described_class.new(payload: payload).perform).to eq(:already_ingested)
        expect(widget_conversation.messages.count).to eq(1)
      end

      it 'refuses a forged reference' do
        payload = widget_payload([{ 'role' => 'user', 'message' => 'Hello' }], ref: 'forged')

        expect(described_class.new(payload: payload).perform).to eq(:target_not_found)
        expect(widget_conversation.messages.count).to eq(0)
      end
    end

    context 'when matching the call to the webhook' do
      it 'prefers the conversation id recorded at registration' do
        call.update!(voice_agent_conversation_id: 'conv_live')
        payload = {
          'type' => 'post_call_transcription',
          'data' => {
            'conversation_id' => 'conv_live',
            'transcript' => [{ 'role' => 'agent', 'message' => 'Hello' }],
            # Deliberately wrong: the authoritative id must win over it.
            'conversation_initiation_client_data' => { 'dynamic_variables' => { 'chatwoot_call_id' => '999999' } }
          }
        }

        expect(described_class.new(payload: payload).perform).to eq(:transcript_stored)
        expect(call.reload.transcript).to eq('Agent: Hello')
      end

      it 'falls back to the dynamic variable for calls answered before ids were recorded' do
        payload = transcript_payload([{ 'role' => 'agent', 'message' => 'Hello' }])

        expect(described_class.new(payload: payload).perform).to eq(:transcript_stored)
        expect(call.reload.transcript).to eq('Agent: Hello')
      end
    end

    it 'ignores an unknown webhook type' do
      expect(described_class.new(payload: { 'type' => 'something_else' }).perform).to eq(:ignored)
    end

    it 'reports a call it cannot find rather than raising' do
      payload = transcript_payload([{ 'role' => 'agent', 'message' => 'Hi' }], call_id: '999999')

      expect(described_class.new(payload: payload).perform).to eq(:target_not_found)
    end

    it 'reports a missing call id rather than raising' do
      payload = { 'type' => 'post_call_transcription', 'data' => {} }

      expect(described_class.new(payload: payload).perform).to eq(:target_not_found)
    end

    it 'rebroadcasts the message so open dashboards pick up the transcript' do
      allow(message).to receive(:send_update_event)
      allow(Message).to receive(:find_by).and_call_original
      payload = transcript_payload([{ 'role' => 'agent', 'message' => 'Hi' }])

      described_class.new(payload: payload).perform

      expect(call.reload.transcript).to be_present
    end
  end
end
