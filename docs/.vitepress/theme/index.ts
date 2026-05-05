import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import './palette.css'
import './base.css'

export const theme: Theme = {
  extends: DefaultTheme,
}

export default theme
