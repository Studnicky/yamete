import { h } from 'vue'
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import SidebarSpinner from './SidebarSpinner.vue'
import MermaidGate from './MermaidGate.vue'
import './palette.css'
import './base.css'

export const theme: Theme = {
  extends: DefaultTheme,
  Layout() {
    return h(DefaultTheme.Layout, null, {
      'sidebar-nav-before': () => [
        h('div', { class: 'yamete-sidebar-icon', 'aria-hidden': 'true' }),
        h(SidebarSpinner),
      ],
      'doc-after': () => h(MermaidGate),
    })
  },
}

export default theme
