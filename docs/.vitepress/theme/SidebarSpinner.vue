<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'

const PHRASES = [
  'An app that reacts when you smack your MacBook.',
  'Mm, again?',
  'Is that all?',
  'Tease~',
  'Show me what you got',
  "Now you've got my attention",
  'I see you',
  'Mmm, okay',
  'Show me more',
  'Mmhmm~',
  'Right there',
  'Show off~',
  'I like where this is going',
  "Don't you dare stop",
]

const text = ref(PHRASES[0])
let timer: ReturnType<typeof setInterval> | undefined

function pickNext() {
  if (PHRASES.length <= 1) return
  let next = text.value
  while (next === text.value) {
    next = PHRASES[Math.floor(Math.random() * PHRASES.length)]
  }
  text.value = next
}

onMounted(() => {
  timer = setInterval(pickNext, 3500)
})
onBeforeUnmount(() => {
  if (timer) clearInterval(timer)
})
</script>

<template>
  <div class="yamete-sidebar-spinner" aria-hidden="true">
    <transition name="yamete-fade" mode="out-in">
      <p :key="text" class="phrase">{{ text }}</p>
    </transition>
  </div>
</template>
