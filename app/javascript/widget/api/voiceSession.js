import { API } from 'widget/helpers/axios';
import { buildSearchParamsWithLocale } from '../helpers/urlParamsHelper';

// Mints a short-lived WebRTC token for a voice conversation with the account's
// ElevenLabs agent. The workspace API key stays on the server; the browser only
// ever sees this token and an opaque signed reference to the conversation.
export const createVoiceSessionAPI = async () => {
  const search = buildSearchParamsWithLocale(window.location.search);
  return API.post(`/api/v1/widget/voice_session${search}`);
};

export default { createVoiceSessionAPI };
