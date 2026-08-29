import { ref, computed, onBeforeUnmount } from 'vue';
import { createVoiceSessionAPI } from 'widget/api/voiceSession';

export const VOICE_STATUS = {
  IDLE: 'idle',
  CONNECTING: 'connecting',
  LISTENING: 'listening',
  SPEAKING: 'speaking',
  ERROR: 'error',
};

// The SDK bundles a WebRTC stack and dwarfs the widget itself, so it is only
// fetched once someone actually asks to talk. Keeping it out of the entry chunk
// means visitors who never use voice never download it.
const loadSdk = () => import('@elevenlabs/client');

export function useVoiceSession() {
  const status = ref(VOICE_STATUS.IDLE);
  const errorKey = ref('');
  let conversation = null;

  const isActive = computed(
    () =>
      status.value === VOICE_STATUS.LISTENING ||
      status.value === VOICE_STATUS.SPEAKING
  );
  const isConnecting = computed(() => status.value === VOICE_STATUS.CONNECTING);

  const teardown = async () => {
    const session = conversation;
    conversation = null;
    if (!session) return;
    try {
      await session.endSession();
    } catch {
      // The session may already be gone; nothing useful to do about it.
    }
  };

  const stop = async () => {
    await teardown();
    status.value = VOICE_STATUS.IDLE;
  };

  const fail = key => {
    conversation = null;
    errorKey.value = key;
    status.value = VOICE_STATUS.ERROR;
  };

  // Asked for before connecting: a visitor who declines should see a permission
  // message rather than a generic connection failure.
  const requestMicrophone = async () => {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    // Only needed to prompt; the SDK opens its own capture stream.
    stream.getTracks().forEach(track => track.stop());
  };

  const start = async () => {
    if (isActive.value || isConnecting.value) return;

    status.value = VOICE_STATUS.CONNECTING;
    errorKey.value = '';

    try {
      await requestMicrophone();
    } catch {
      fail('MICROPHONE_DENIED');
      return;
    }

    let session;
    try {
      session = await createVoiceSessionAPI();
    } catch {
      fail('UNAVAILABLE');
      return;
    }

    const { token, voice_reference: voiceReference } = session?.data || {};
    if (!token) {
      fail('UNAVAILABLE');
      return;
    }

    try {
      const { Conversation } = await loadSdk();
      conversation = await Conversation.startSession({
        conversationToken: token,
        // Read back to us on the post-call webhook, and the only thing tying
        // the transcript to this conversation.
        dynamicVariables: { chatwoot_voice_reference: voiceReference },
        onModeChange: ({ mode }) => {
          status.value =
            mode === 'speaking'
              ? VOICE_STATUS.SPEAKING
              : VOICE_STATUS.LISTENING;
        },
        onDisconnect: () => {
          conversation = null;
          if (status.value !== VOICE_STATUS.ERROR) {
            status.value = VOICE_STATUS.IDLE;
          }
        },
        onError: () => fail('CONNECTION_LOST'),
      });
      status.value = VOICE_STATUS.LISTENING;
    } catch {
      fail('CONNECTION_LOST');
    }
  };

  const toggle = () =>
    isActive.value || isConnecting.value ? stop() : start();

  // A visitor closing the widget mid-sentence must not leave a session (and its
  // billing) running in the background.
  onBeforeUnmount(teardown);

  return { status, errorKey, isActive, isConnecting, start, stop, toggle };
}

export default useVoiceSession;
