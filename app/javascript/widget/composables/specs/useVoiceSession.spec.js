import { describe, it, expect, vi, beforeEach } from 'vitest';
import { defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';
import { useVoiceSession, VOICE_STATUS } from '../useVoiceSession';
import { createVoiceSessionAPI } from 'widget/api/voiceSession';

vi.mock('widget/api/voiceSession', () => ({
  createVoiceSessionAPI: vi.fn(),
}));

const startSession = vi.fn();
vi.mock('@elevenlabs/client', () => ({
  Conversation: {
    startSession: (...args) => startSession(...args),
  },
}));

// The composable registers onBeforeUnmount, so it needs a component instance.
const mountComposable = () => {
  let api;
  const wrapper = mount(
    defineComponent({
      setup() {
        api = useVoiceSession();
        return () => h('div');
      },
    })
  );
  return { api, wrapper };
};

const grantMicrophone = () => {
  const stop = vi.fn();
  navigator.mediaDevices = {
    getUserMedia: vi.fn().mockResolvedValue({ getTracks: () => [{ stop }] }),
  };
  return stop;
};

describe('useVoiceSession', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    startSession.mockResolvedValue({ endSession: vi.fn() });
    createVoiceSessionAPI.mockResolvedValue({
      data: { token: 'tok_abc', voice_reference: 'ref_signed' },
    });
  });

  it('starts idle', () => {
    const { api } = mountComposable();
    expect(api.status.value).toBe(VOICE_STATUS.IDLE);
    expect(api.isActive.value).toBe(false);
  });

  it('connects and starts listening', async () => {
    grantMicrophone();
    const { api } = mountComposable();

    await api.start();

    expect(api.status.value).toBe(VOICE_STATUS.LISTENING);
    expect(api.isActive.value).toBe(true);
  });

  it('passes the signed reference through so the transcript can be matched back', async () => {
    grantMicrophone();
    const { api } = mountComposable();

    await api.start();

    expect(startSession).toHaveBeenCalledWith(
      expect.objectContaining({
        conversationToken: 'tok_abc',
        dynamicVariables: { chatwoot_voice_reference: 'ref_signed' },
      })
    );
  });

  it('releases the permission-probe track it opened', async () => {
    const stop = grantMicrophone();
    const { api } = mountComposable();

    await api.start();

    expect(stop).toHaveBeenCalled();
  });

  it('reports a denied microphone without calling the server', async () => {
    navigator.mediaDevices = {
      getUserMedia: vi.fn().mockRejectedValue(new Error('denied')),
    };
    const { api } = mountComposable();

    await api.start();

    expect(api.status.value).toBe(VOICE_STATUS.ERROR);
    expect(api.errorKey.value).toBe('MICROPHONE_DENIED');
    expect(createVoiceSessionAPI).not.toHaveBeenCalled();
  });

  it('reports unavailable when the server will not mint a token', async () => {
    grantMicrophone();
    createVoiceSessionAPI.mockRejectedValue(new Error('503'));
    const { api } = mountComposable();

    await api.start();

    expect(api.errorKey.value).toBe('UNAVAILABLE');
    expect(startSession).not.toHaveBeenCalled();
  });

  it('reports a lost connection when the session will not open', async () => {
    grantMicrophone();
    startSession.mockRejectedValue(new Error('ice failed'));
    const { api } = mountComposable();

    await api.start();

    expect(api.errorKey.value).toBe('CONNECTION_LOST');
  });

  it('does not open a second session while one is live', async () => {
    grantMicrophone();
    const { api } = mountComposable();

    await api.start();
    await api.start();

    expect(startSession).toHaveBeenCalledTimes(1);
  });

  it('ends the session on stop', async () => {
    grantMicrophone();
    const endSession = vi.fn();
    startSession.mockResolvedValue({ endSession });
    const { api } = mountComposable();

    await api.start();
    await api.stop();

    expect(endSession).toHaveBeenCalled();
    expect(api.status.value).toBe(VOICE_STATUS.IDLE);
  });

  it('ends the session when the widget unmounts so it cannot bill on', async () => {
    grantMicrophone();
    const endSession = vi.fn();
    startSession.mockResolvedValue({ endSession });
    const { api, wrapper } = mountComposable();

    await api.start();
    wrapper.unmount();

    expect(endSession).toHaveBeenCalled();
  });

  it('tracks the agent speaking and listening', async () => {
    grantMicrophone();
    const { api } = mountComposable();

    await api.start();
    const { onModeChange } = startSession.mock.calls[0][0];

    onModeChange({ mode: 'speaking' });
    expect(api.status.value).toBe(VOICE_STATUS.SPEAKING);

    onModeChange({ mode: 'listening' });
    expect(api.status.value).toBe(VOICE_STATUS.LISTENING);
  });

  it('returns to idle when the agent hangs up', async () => {
    grantMicrophone();
    const { api } = mountComposable();

    await api.start();
    startSession.mock.calls[0][0].onDisconnect();

    expect(api.status.value).toBe(VOICE_STATUS.IDLE);
  });
});
