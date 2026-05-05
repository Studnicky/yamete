import type { DefaultTheme } from 'vitepress'

export const themeConfig = {
  appearance: 'dark' as const,
  outline: { label: 'On this page', level: [2, 3] as [number, number] },
  search: { provider: 'local' as const },
  footer: {
    copyright: 'MIT License, © 2026 Andrew Studnicky',
    message: 'Engineered with excessive care for a deeply unnecessary purpose.',
  },
  editLink: {
    pattern: 'https://github.com/Studnicky/yamete/edit/master/docs/:path',
    text: 'Edit this page on GitHub',
  },
  docFooter: { next: 'Next', prev: 'Previous' },
} satisfies Partial<DefaultTheme.Config>
