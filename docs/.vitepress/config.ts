import { defineConfig } from 'vitepress';
import { withMermaid } from 'vitepress-plugin-mermaid';

import { themeConfig } from './theme.config.js';

const sidebar = [
  {
    'items': [
      {
        'link': '/',
        'text': 'What it does'
      },
      {
        'link': '/what-is-this',
        'text': 'What is this?'
      },
      {
        'link': '/using',
        'text': 'Using Yamete (the menu)'
      },
      {
        'link': '/support',
        'text': 'Support & FAQ'
      }
    ],
    'text': 'Yamete'
  },
  {
    'collapsed': false,
    'items': [
      {
        'link': '/architecture',
        'text': 'Overview'
      },
      {
        'link': '/architecture/modules',
        'text': 'Module graph'
      },
      {
        'link': '/architecture/signal-pipeline',
        'text': 'Signal pipeline'
      },
      {
        'link': '/architecture/detection-gates',
        'text': 'Detection gates'
      },
      {
        'link': '/architecture/fusion',
        'text': 'Fusion engine'
      },
      {
        'link': '/architecture/sensitivity',
        'text': 'Sensitivity gate'
      },
      {
        'link': '/architecture/enricher',
        'text': 'Bus enricher'
      },
      {
        'link': '/architecture/responses',
        'text': 'Response dispatch'
      },
      {
        'link': '/architecture/led-flash',
        'text': 'LED flash detail'
      },
      {
        'link': '/architecture/concurrency',
        'text': 'Concurrency model'
      },
      {
        'link': '/architecture/lifecycle',
        'text': 'Pipeline lifecycle'
      },
      {
        'link': '/architecture/source-map',
        'text': 'Source map'
      },
      {
        'link': '/architecture/configuration',
        'text': 'Configuration (every knob)'
      }
    ],
    'text': 'Architecture'
  },
  {
    'items': [
      {
        'link': '/testing',
        'text': 'Testing'
      },
      {
        'link': '/sensor-kickstart/',
        'text': 'Sensor Kickstart helper'
      }
    ],
    'text': 'Verification'
  },
  {
    'items': [
      {
        'link': '/INSTALLATION',
        'text': 'Installation'
      },
      {
        'link': '/CHANGELOG',
        'text': 'Changelog'
      },
      {
        'link': '/LICENSES-CONTENT',
        'text': 'Content licenses'
      }
    ],
    'text': 'Reference'
  },
  {
    'items': [{
      'link': '/privacy',
      'text': 'Privacy'
    }],
    'text': 'Policy'
  },
  {
    'items': [{
      'link': '/acknowledgments',
      'text': 'Acknowledgments'
    }],
    'text': 'Credit'
  }
];

export default withMermaid(defineConfig({
  'appearance': themeConfig.appearance,
  'base': '/yamete/',
  'cleanUrls': true,
  'description': 'A macOS menu bar app that reacts when you smack your laptop. Three sensors. Eleven event triggers. Forty languages. Zero shame.',
  'head': [
    [
      'link',
      {
        'href': '/yamete/favicon.png',
        'rel': 'icon',
        'type': 'image/png'
      }
    ],
    [
      'link',
      {
        'href': '/yamete/icon.png',
        'rel': 'apple-touch-icon'
      }
    ],
    [
      'meta',
      {
        'content': '#ff6b8a',
        'name': 'theme-color'
      }
    ],
    [
      'meta',
      {
        'content': 'website',
        'property': 'og:type'
      }
    ],
    [
      'meta',
      {
        'content': 'Yamete: an app that reacts when you smack your MacBook',
        'property': 'og:title'
      }
    ],
    [
      'meta',
      {
        'content': '/yamete/icon.png',
        'property': 'og:image'
      }
    ]
  ],
  'ignoreDeadLinks': [
    'localhostLinks',
    /^\/privacy/
  ],
  'lang': 'en-US',
  'lastUpdated': true,
  // mermaid plugin options
  'mermaid': {
    'flowchart': {
      'htmlLabels': true,
      'useMaxWidth': false,
      'wrappingWidth': 200
    },
    'theme': 'base',
    'themeVariables': { 'fontFamily': 'SF Mono, ui-monospace, Menlo, monospace' }
  },
  'mermaidPlugin': { 'class': 'mermaid yamete-mermaid' },
  'srcDir': '.',
  'themeConfig': {
    ...themeConfig,
    'nav': [
      {
        'link': '/',
        'text': 'Home'
      },
      {
        'link': '/support',
        'text': 'Support'
      },
      {
        'link': '/architecture',
        'text': 'Architecture'
      },
      {
        'link': '/testing',
        'text': 'Testing'
      },
      {
        'link': '/sensor-kickstart/',
        'text': 'Sensor Kickstart'
      },
      {
        'link': 'https://github.com/Studnicky/yamete/releases/latest',
        'text': 'Releases'
      },
      {
        'link': 'https://github.com/Studnicky/yamete',
        'text': 'GitHub'
      }
    ],
    'sidebar': sidebar,
    'siteTitle': 'Yamete',
    'socialLinks': [{
      'icon': 'github',
      'link': 'https://github.com/Studnicky/yamete'
    }]
  },
  'title': 'Yamete'
}));
