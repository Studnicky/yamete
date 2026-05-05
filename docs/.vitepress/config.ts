import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'
import { themeConfig } from './theme.config.js'

const sidebar = [
  {
    text: 'Yamete',
    items: [
      { link: '/',         text: 'What it does' },
      { link: '/support',  text: 'Support & FAQ' },
    ],
  },
  {
    text: 'Internals',
    items: [
      { link: '/architecture',       text: 'Architecture' },
      { link: '/sensor-kickstart/',  text: 'Sensor Kickstart helper' },
    ],
  },
  {
    text: 'Reference',
    items: [
      { link: '/INSTALLATION',     text: 'Installation' },
      { link: '/CHANGELOG',        text: 'Changelog' },
      { link: '/LICENSES-CONTENT', text: 'Content licenses' },
    ],
  },
  {
    text: 'Policy',
    items: [
      { link: '/privacy',          text: 'Privacy' },
    ],
  },
]

export default withMermaid(defineConfig({
  appearance: themeConfig.appearance,
  base: '/yamete/',
  cleanUrls: true,
  description: 'A macOS menu bar app that reacts when you smack your laptop. Three sensors. Eleven event triggers. Forty languages. Zero shame.',
  ignoreDeadLinks: ['localhostLinks', /^\/privacy/],
  lang: 'en-US',
  lastUpdated: true,
  srcDir: '.',
  themeConfig: {
    ...themeConfig,
    siteTitle: 'Yamete',
    nav: [
      { text: 'Home',         link: '/' },
      { text: 'Support',      link: '/support' },
      { text: 'Architecture', link: '/architecture' },
      { text: 'Sensor Kickstart', link: '/sensor-kickstart/' },
      { text: 'Releases',     link: 'https://github.com/Studnicky/yamete/releases/latest' },
      { text: 'GitHub',       link: 'https://github.com/Studnicky/yamete' },
    ],
    sidebar,
    socialLinks: [{ icon: 'github', link: 'https://github.com/Studnicky/yamete' }],
  },
  title: 'Yamete',
  head: [
    ['link', { rel: 'icon',          type: 'image/png',  href: '/yamete/favicon.png' }],
    ['link', { rel: 'apple-touch-icon', href: '/yamete/icon.png' }],
    ['meta', { name: 'theme-color',  content: '#ff6b8a' }],
    ['meta', { property: 'og:type',  content: 'website' }],
    ['meta', { property: 'og:title', content: 'Yamete: an app that reacts when you smack your MacBook' }],
    ['meta', { property: 'og:image', content: '/yamete/icon.png' }],
  ],
  // mermaid plugin options
  mermaid: { theme: 'base' },
  mermaidPlugin: { class: 'mermaid yamete-mermaid' },
}))
