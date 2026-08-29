<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import FluentIcon from 'shared/components/FluentIcon/Index.vue';
import {
  useVoiceSession,
  VOICE_STATUS,
} from 'widget/composables/useVoiceSession';

const { t } = useI18n();
const { status, errorKey, isActive, isConnecting, toggle } = useVoiceSession();

const hasError = computed(() => status.value === VOICE_STATUS.ERROR);

// A live session is the one state where the icon must read "stop", not "talk".
const icon = computed(() =>
  isActive.value ? 'microphone-off-outline' : 'microphone-outline'
);

// Spelled out rather than interpolated so every key is statically checkable and
// a typo fails the i18n lint instead of rendering a raw key to a visitor.
const errorLabel = computed(() => {
  if (errorKey.value === 'MICROPHONE_DENIED') {
    return t('VOICE_CALL.ERRORS.MICROPHONE_DENIED');
  }
  if (errorKey.value === 'CONNECTION_LOST') {
    return t('VOICE_CALL.ERRORS.CONNECTION_LOST');
  }
  return t('VOICE_CALL.ERRORS.UNAVAILABLE');
});

const label = computed(() => {
  if (hasError.value) return errorLabel.value;
  if (isConnecting.value) return t('VOICE_CALL.CONNECTING');
  if (status.value === VOICE_STATUS.SPEAKING) return t('VOICE_CALL.SPEAKING');
  if (status.value === VOICE_STATUS.LISTENING) return t('VOICE_CALL.LISTENING');
  return t('VOICE_CALL.START');
});

const iconClass = computed(() => {
  if (hasError.value) return 'text-n-ruby-11';
  if (isActive.value) return 'text-n-brand';
  if (isConnecting.value) return 'text-n-slate-10 animate-pulse';
  return 'text-n-slate-12';
});
</script>

<template>
  <button
    class="flex items-center justify-center min-h-8 min-w-8"
    :aria-label="label"
    :title="label"
    :aria-pressed="isActive"
    @click="toggle"
  >
    <FluentIcon
      :icon="icon"
      class="transition-all duration-150"
      :class="iconClass"
    />
  </button>
</template>
