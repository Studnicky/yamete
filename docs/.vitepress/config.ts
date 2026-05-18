import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve }                                from 'node:path';
import { defineConfig } from 'vitepress';
import { withMermaid }  from 'vitepress-plugin-mermaid';

import { themeConfig } from './theme.config.js';
import pkg             from '../../package.json' with { type: 'json' };

/**
 * SEO tokens live in package.json under `yamete.seo`. All three values
 * are *explicitly designed to be public*: Google/Bing verification
 * meta tags are not credentials, they're property-ownership markers
 * the registry reads back to confirm the SC account that ships this
 * string owns this domain. Anyone can read them; nobody can abuse them.
 * The Twitter handle is the public-facing account.
 *
 * Empty string suppresses the corresponding head tag at build time:
 * we ship no orphaned meta tags pointing at unowned properties.
 */
interface YameteSeoConfig {
  readonly googleSiteVerification: string;
  readonly bingSiteVerification:   string;
  readonly twitterHandle:          string;
}
const seo: YameteSeoConfig = (pkg as { 'yamete'?: { 'seo'?: YameteSeoConfig } }).yamete?.seo ?? {
  googleSiteVerification: '',
  bingSiteVerification:   '',
  twitterHandle:          '',
};

// ── Site identity: single source of truth for SEO, OG, JSON-LD ─────────
const SITE_TITLE             = 'Yamete';
const SITE_TAGLINE           = 'a macOS app that reacts when you smack your laptop';
const SITE_DESCRIPTION       = 'A macOS menu bar app that reacts when you smack your laptop. Three sensors. Eleven event triggers. Forty languages. Zero shame.';
const SITE_DESCRIPTION_SHORT = 'Smack your MacBook. It reacts. Three sensors, eleven triggers, forty languages.';
const SITE_URL               = 'https://studnicky.github.io/yamete/';
const SITE_BASE              = '/yamete/';
const SITE_OG_IMAGE          = `${SITE_URL}og-image.png`;
const SITE_THEME_COLOR       = '#ff6b8a';
const SITE_KEYWORDS          = 'yamete, macOS app, menu bar app, accelerometer, BMI286, AirPods IMU, impact detection, sensor fusion, laptop smack, Swift, SwiftUI, MainActor, macOS menu bar, sound effects, native macOS, haptic feedback, novelty app, Mac App Store';
const SITE_AUTHOR_NAME       = 'Andrew Studnicky';
const SITE_AUTHOR_URL        = 'https://github.com/Studnicky';
const SITE_REPO              = 'https://github.com/Studnicky/yamete';
const SITE_LOGO              = `${SITE_URL}icon.png`;

/* Verification tokens for search-console enrolment. Once you register
   the property at https://search.google.com/search-console (Google) +
   https://www.bing.com/webmasters (Bing), paste the verification value
   into `package.json` → `yamete.seo.{googleSiteVerification,
   bingSiteVerification}` so the next build ships the meta tag.
   Empty string (the default) suppresses the tag: we don't ship orphan
   tags pointing at unowned properties. */
const VERIFY_GOOGLE          = seo.googleSiteVerification;
const VERIFY_BING            = seo.bingSiteVerification;

/* Twitter / X handle for `twitter:site` + `twitter:creator` attribution
   in the unfurl card. Leave empty to omit: a missing handle is better
   than a wrong one, since Twitter's validator drops the entire card if
   `twitter:site` resolves to a deleted account. Set in `package.json`
   → `yamete.seo.twitterHandle` (include the `@`). */
const SITE_TWITTER_HANDLE    = seo.twitterHandle;

const sidebar = [
  {
    'text':  'Yamete',
    'items': [
      { 'link': '/',              'text': 'What it does'           },
      { 'link': '/what-is-this',  'text': 'What is this?'          },
      { 'link': '/using',         'text': 'Using Yamete (the menu)'},
      { 'link': '/support',       'text': 'Support & FAQ'          },
    ],
  },
  {
    'collapsed': false,
    'text':      'Architecture',
    'items': [
      { 'link': '/architecture',                   'text': 'Overview'              },
      { 'link': '/architecture/modules',           'text': 'Module graph'          },
      { 'link': '/architecture/signal-pipeline',   'text': 'Signal pipeline'       },
      { 'link': '/architecture/detection-gates',   'text': 'Detection gates'       },
      { 'link': '/architecture/fusion',            'text': 'Fusion engine'         },
      { 'link': '/architecture/sensitivity',       'text': 'Sensitivity gate'      },
      { 'link': '/architecture/enricher',          'text': 'Bus enricher'          },
      { 'link': '/architecture/responses',         'text': 'Response dispatch'     },
      { 'link': '/architecture/led-flash',         'text': 'LED flash detail'      },
      { 'link': '/architecture/concurrency',       'text': 'Concurrency model'     },
      { 'link': '/architecture/lifecycle',         'text': 'Pipeline lifecycle'    },
      { 'link': '/architecture/source-map',        'text': 'Source map'            },
      { 'link': '/architecture/configuration',     'text': 'Configuration (every knob)' },
    ],
  },
  {
    'text':  'Verification',
    'items': [
      { 'link': '/testing',              'text': 'Testing'                },
      { 'link': '/sensor-kickstart/',    'text': 'Sensor Kickstart helper'},
    ],
  },
  {
    'text':  'Reference',
    'items': [
      { 'link': '/INSTALLATION',       'text': 'Installation'      },
      { 'link': '/CHANGELOG',          'text': 'Changelog'         },
      { 'link': '/LICENSES-CONTENT',   'text': 'Content licenses'  },
    ],
  },
  {
    'text':  'Policy',
    'items': [{ 'link': '/privacy', 'text': 'Privacy' }],
  },
  {
    'text':  'Credit',
    'items': [{ 'link': '/acknowledgments', 'text': 'Acknowledgments' }],
  },
];

export default withMermaid(defineConfig({
  'mermaid': {
    'theme': 'base',
    'flowchart': {
      'htmlLabels':    true,
      'useMaxWidth':   false,
      'wrappingWidth': 200,
    },
    'themeVariables': { 'fontFamily': 'SF Mono, ui-monospace, Menlo, monospace' },
  },
  'mermaidPlugin':  { 'class': 'mermaid yamete-mermaid' },
  'base':           SITE_BASE,
  'lang':           'en-US',
  'title':          SITE_TITLE,
  'titleTemplate':  `:title | ${SITE_TITLE}`,
  'description':    SITE_DESCRIPTION,
  'cleanUrls':      true,
  'lastUpdated':    true,
  'srcDir':         '.',
  /* `art/` holds local-only face-rig design exploration markdown that is
     gitignored at the repo level but still discovered by VitePress's
     srcDir glob. Excluding it here prevents the build from choking on
     interpolation-like braces or unclosed angle-bracket placeholders in
     planning notes that were never meant to ship to Pages. */
  'srcExclude':     ['art/**'],
  'ignoreDeadLinks': ['localhostLinks', /^\/privacy/],
  'sitemap': {
    /* VitePress generates sitemap.xml from every page rendered into
       /dist. Crawlers (Googlebot, Bingbot, DuckDuckGo) discover routes
       faster when the sitemap is published; GitHub Pages serves
       /yamete/sitemap.xml automatically since it's under the dist root. */
    'hostname': SITE_URL,
  },
  'head': [
    /* Favicon stack. The SVG is the canonical icon (modern browsers,
       crisp at every size). The PNG variants stay as fallbacks for
       crawlers and macOS Dock / Safari pinned-tab use cases where SVG
       support is patchy. Order matters: browsers pick the first
       `rel=icon` they can render, so SVG goes first. */
    ['link',   { 'rel': 'icon',             'type': 'image/svg+xml',                       'href': `${SITE_BASE}favicon.svg` }],
    ['link',   { 'rel': 'icon',             'type': 'image/png',   'sizes': '16x16',       'href': `${SITE_BASE}favicon-16.png` }],
    ['link',   { 'rel': 'icon',             'type': 'image/png',   'sizes': '32x32',       'href': `${SITE_BASE}favicon-32.png` }],
    ['link',   { 'rel': 'icon',             'type': 'image/png',   'sizes': '48x48',       'href': `${SITE_BASE}favicon-48.png` }],
    ['link',   { 'rel': 'icon',             'type': 'image/png',   'sizes': '64x64',       'href': `${SITE_BASE}favicon-64.png` }],
    ['link',   { 'rel': 'shortcut icon',                                                   'href': `${SITE_BASE}favicon.svg` }],
    ['link',   { 'rel': 'apple-touch-icon', 'sizes': '180x180',                            'href': `${SITE_BASE}icon.png` }],
    ['link',   { 'rel': 'mask-icon',        'color': SITE_THEME_COLOR,                     'href': `${SITE_BASE}favicon.svg` }],
    ['link',   { 'rel': 'manifest',                                                        'href': `${SITE_BASE}manifest.webmanifest` }],
    ['link',   { 'rel': 'sitemap',          'type': 'application/xml',  'href': `${SITE_BASE}sitemap.xml` }],
    ['link',   { 'rel': 'alternate',        'type': 'application/rss+xml', 'title': `${SITE_TITLE}: changelog`, 'href': `${SITE_BASE}feed.xml` }],

    /* `hreflang` declares this is the en-US canonical of the site. With
       only one language variant published, `x-default` points at the
       same URL: harmless duplication that disambiguates intent for
       international search engines and avoids "language not declared"
       webmaster-tools warnings. */
    ['link',   { 'rel': 'alternate', 'hreflang': 'en-US',     'href': SITE_URL }],
    ['link',   { 'rel': 'alternate', 'hreflang': 'x-default', 'href': SITE_URL }],
    ['meta',   { 'name': 'theme-color',                 'content': SITE_THEME_COLOR }],
    ['meta',   { 'name': 'color-scheme',                'content': 'dark light' }],
    ['meta',   { 'name': 'msapplication-TileColor',     'content': SITE_THEME_COLOR }],
    ['meta',   { 'name': 'msapplication-TileImage',     'content': `${SITE_BASE}icon.png` }],
    ['meta',   { 'name': 'apple-mobile-web-app-capable',           'content': 'yes' }],
    ['meta',   { 'name': 'apple-mobile-web-app-title',             'content': SITE_TITLE }],
    ['meta',   { 'name': 'apple-mobile-web-app-status-bar-style',  'content': 'black-translucent' }],

    /* SEO basics. `robots` carries the explicit indexable signal plus
       the modern hints (`max-snippet:-1`, `max-image-preview:large`,
       `max-video-preview:-1`) that surface richer search-result cards.
       `author` and `keywords` carry minor SEO weight; mostly there for
       human-readable previews and competitor-alias discovery. */
    ['meta',   { 'name': 'robots',           'content': 'index, follow, max-snippet:-1, max-image-preview:large, max-video-preview:-1' }],
    ['meta',   { 'name': 'googlebot',        'content': 'index, follow' }],
    ['meta',   { 'name': 'bingbot',          'content': 'index, follow' }],
    ['meta',   { 'name': 'author',           'content': SITE_AUTHOR_NAME }],
    ['meta',   { 'name': 'keywords',         'content': SITE_KEYWORDS }],
    ['meta',   { 'name': 'application-name', 'content': SITE_TITLE }],
    ['meta',   { 'name': 'generator',        'content': 'VitePress' }],
    /* `referrer` policy. `origin-when-cross-origin` strips the path on
       outbound clicks (so external sites only see `https://studnicky.github.io/`
       in their analytics, not the specific docs page) while keeping the
       full URL on internal navigation. Good privacy posture; doesn't
       harm SEO. */
    ['meta',   { 'name': 'referrer',         'content': 'origin-when-cross-origin' }],

    /* Search-console verification meta tags. Empty content suppresses
       the tag at build time; once the verification value is in the env,
       the next deploy emits the tag and the property activates. */
    ...(VERIFY_GOOGLE !== '' ? [['meta', { 'name': 'google-site-verification', 'content': VERIFY_GOOGLE }] as const] : []),
    ...(VERIFY_BING   !== '' ? [['meta', { 'name': 'msvalidate.01',            'content': VERIFY_BING   }] as const] : []),

    /* Open Graph + Twitter: drive the unfurl card that Discord, Slack,
       iMessage, Twitter/X, and LinkedIn render when someone pastes the
       URL. `og:image` MUST be an absolute URL; Discord drops relative
       paths and falls back to the bare hostname. Per-page values are
       overridden via `transformPageData` below; these are the defaults.
       og:image points at the 1200×630 landscape PNG (`og-image.png`) so
       Twitter's `summary_large_image` card renders correctly. */
    ['meta',   { 'property': 'og:type',             'content': 'website' }],
    ['meta',   { 'property': 'og:site_name',        'content': SITE_TITLE }],
    ['meta',   { 'property': 'og:title',            'content': `${SITE_TITLE}: ${SITE_TAGLINE}` }],
    ['meta',   { 'property': 'og:description',      'content': SITE_DESCRIPTION }],
    ['meta',   { 'property': 'og:url',              'content': SITE_URL }],
    ['meta',   { 'property': 'og:image',            'content': SITE_OG_IMAGE }],
    ['meta',   { 'property': 'og:image:secure_url', 'content': SITE_OG_IMAGE }],
    ['meta',   { 'property': 'og:image:type',       'content': 'image/png' }],
    ['meta',   { 'property': 'og:image:alt',        'content': `${SITE_TITLE}: ${SITE_TAGLINE}` }],
    ['meta',   { 'property': 'og:image:width',      'content': '1200' }],
    ['meta',   { 'property': 'og:image:height',     'content': '630' }],
    ['meta',   { 'property': 'og:locale',           'content': 'en_US' }],
    ['meta',   { 'name':     'twitter:card',        'content': 'summary_large_image' }],
    ['meta',   { 'name':     'twitter:title',       'content': `${SITE_TITLE}: ${SITE_TAGLINE}` }],
    ['meta',   { 'name':     'twitter:description', 'content': SITE_DESCRIPTION_SHORT }],
    ['meta',   { 'name':     'twitter:image',       'content': SITE_OG_IMAGE }],
    ['meta',   { 'name':     'twitter:image:alt',   'content': `${SITE_TITLE}: ${SITE_TAGLINE}` }],
    ...(SITE_TWITTER_HANDLE !== '' ? [
      ['meta', { 'name': 'twitter:site',    'content': SITE_TWITTER_HANDLE }] as const,
      ['meta', { 'name': 'twitter:creator', 'content': SITE_TWITTER_HANDLE }] as const,
    ] : []),

    /* JSON-LD structured data. Search engines parse this into a rich
       site card (name, description, author, repository) and link the
       resulting result to schema.org's SoftwareApplication + WebSite
       types so the site shows up in code-search and macOS-app organic
       results. */
    ['script', { 'type': 'application/ld+json' }, JSON.stringify({
      '@context':            'https://schema.org',
      '@type':               'SoftwareApplication',
      'name':                SITE_TITLE,
      'description':         SITE_DESCRIPTION,
      'url':                 SITE_URL,
      'image':               SITE_OG_IMAGE,
      'applicationCategory': 'UtilitiesApplication',
      'operatingSystem':     'macOS 14.0+',
      'license':             'https://opensource.org/licenses/MIT',
      'downloadUrl':         `${SITE_REPO}/releases/latest`,
      'codeRepository':      SITE_REPO,
      'softwareVersion':     (pkg as { 'yamete'?: { 'version'?: string } }).yamete?.version ?? '',
      'offers': {
        '@type':         'Offer',
        'price':         '0',
        'priceCurrency': 'USD',
      },
      'author': {
        '@type': 'Person',
        'name':  SITE_AUTHOR_NAME,
        'url':   SITE_AUTHOR_URL,
      },
      'keywords': SITE_KEYWORDS,
    })],
    ['script', { 'type': 'application/ld+json' }, JSON.stringify({
      '@context':    'https://schema.org',
      '@type':       'WebSite',
      'name':        SITE_TITLE,
      'url':         SITE_URL,
      'description': SITE_DESCRIPTION,
      'inLanguage':  'en-US',
    })],
    /* Organization schema powers the Google Knowledge Panel. `sameAs`
       lists the canonical accounts that represent this organization
       across the web (GitHub repo) so search engines can disambiguate
       `yamete` from unrelated brands with the same name. `logo` is the
       square mark; absolute URL is mandatory. */
    ['script', { 'type': 'application/ld+json' }, JSON.stringify({
      '@context': 'https://schema.org',
      '@type':    'Organization',
      'name':     SITE_TITLE,
      'url':      SITE_URL,
      'logo':     SITE_LOGO,
      'sameAs':   [SITE_REPO, SITE_AUTHOR_URL],
      'founder': {
        '@type': 'Person',
        'name':  SITE_AUTHOR_NAME,
        'url':   SITE_AUTHOR_URL,
      },
    })],
  ],
  /**
   * Per-page metadata. VitePress invokes this for every page during the
   * SSR pass; we use it to emit page-specific og:title / og:description /
   * og:url / canonical / twitter:title so social unfurls and SEO results
   * surface the page's own title and the page's own URL rather than the
   * site-level default. Without this, every Discord paste of any page
   * would show the yamete homepage card.
   */
  transformPageData(pageData): void {
    const relPath = pageData.relativePath
      .replace(/\.md$/, '')
      .replace(/(^|\/)index$/, '');
    const pageUrl = relPath === '' ? SITE_URL : `${SITE_URL}${relPath}`;
    /* VitePress sets `pageData.title` from the first H1 when no frontmatter
       title is present, and `pageData.description = ''` (empty string, not
       `undefined`) when no description is supplied. We OR-coalesce so empty
       strings fall through to the site-level defaults; ??-coalescing would
       leak empty `''` into `og:description` / `twitter:description`. */
    const frontmatterTitle       = pageData.frontmatter['title']       as string | undefined;
    const frontmatterDescription = pageData.frontmatter['description'] as string | undefined;
    const title        = frontmatterTitle       || pageData.title       || SITE_TITLE;
    const description  = frontmatterDescription || pageData.description || SITE_DESCRIPTION;
    const displayTitle = title === SITE_TITLE ? SITE_TITLE : `${title}: ${SITE_TITLE}`;
    /* Force VitePress's `<title>` resolution to honour the frontmatter
       title over a content-derived H1. */
    if (frontmatterTitle !== undefined) pageData.title = frontmatterTitle;
    /* Suppress the `:title | Yamete` template on any page whose title is
       already the site title. Without this the home renders as `Yamete
       | Yamete` (the template appends unconditionally). */
    if (title === SITE_TITLE) {
      (pageData as { titleTemplate?: string | false }).titleTemplate = false;
    }

    /* BreadcrumbList structured data. Google renders this as the
       "Home > Section > Page" trail above the SERP result, replacing
       the bare URL. Built from URL segments: root is always "Yamete";
       each path segment becomes a position with a humanised label and
       its absolute URL. */
    const segments = relPath === '' ? [] : relPath.split('/');
    const crumbs: Array<{ '@type': 'ListItem'; 'position': number; 'name': string; 'item': string }> = [
      { '@type': 'ListItem', 'position': 1, 'name': SITE_TITLE, 'item': SITE_URL },
    ];
    let accumulated = '';
    for (let i = 0; i < segments.length; i++) {
      const seg = segments[i] as string;
      accumulated  = accumulated === '' ? seg : `${accumulated}/${seg}`;
      const isLast = i === segments.length - 1;
      const label  = isLast
        ? title
        : seg.replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
      crumbs.push({
        '@type':    'ListItem',
        'position': i + 2,
        'name':     label,
        'item':     `${SITE_URL}${accumulated}`,
      });
    }
    const breadcrumb = {
      '@context':        'https://schema.org',
      '@type':           'BreadcrumbList',
      'itemListElement': crumbs,
    };

    /* Article timestamps when VitePress has resolved a `lastUpdated`
       value from git. `article:modified_time` is the freshness signal
       Google uses to rank time-sensitive content; absent timestamps
       default to "unknown freshness" which hurts ranking on docs that
       sit alongside dated competitors. ISO-8601 with timezone is the
       required format. Guard against 0 / NaN from uncommitted files. */
    const lastUpdated = (typeof pageData.lastUpdated === 'number'
      && Number.isFinite(pageData.lastUpdated)
      && pageData.lastUpdated > 0)
      ? new Date(pageData.lastUpdated).toISOString()
      : undefined;

    pageData.frontmatter['head'] = [
      ...(pageData.frontmatter['head'] as ReadonlyArray<readonly [string, Record<string, string>]> ?? []),
      ['link', { 'rel': 'canonical', 'href': pageUrl }],
      ['meta', { 'property': 'og:url',         'content': pageUrl }],
      ['meta', { 'property': 'og:title',       'content': displayTitle }],
      ['meta', { 'property': 'og:description', 'content': description }],
      ['meta', { 'name':     'twitter:title',       'content': displayTitle }],
      ['meta', { 'name':     'twitter:description', 'content': description }],
      ['meta', { 'name':     'description',         'content': description }],
      ...(lastUpdated !== undefined ? [
        ['meta', { 'property': 'article:modified_time', 'content': lastUpdated }] as const,
        ['meta', { 'property': 'article:author',        'content': SITE_AUTHOR_NAME }] as const,
      ] : []),
      ['script', { 'type': 'application/ld+json' }, JSON.stringify(breadcrumb)],
    ];
  },
  /**
   * Build-end hook. Generates the changelog RSS feed by parsing
   * `docs/CHANGELOG.md` once per build and writing `feed.xml` into the
   * VitePress dist root. RSS is still the standard discovery channel
   * for tooling integrators (release watchers, Sparkle-style updaters,
   * GitHub Action notifiers); shipping a feed alongside the docs costs
   * almost nothing and gets cited from `<link rel="alternate"
   * type="application/rss+xml">` in the head for in-page auto-discovery.
   */
  buildEnd(siteConfig): void {
    const changelogPath = resolve(siteConfig.root, 'CHANGELOG.md');
    if (!existsSync(changelogPath)) return;
    const md = readFileSync(changelogPath, 'utf-8');
    /* Match `## [version] - YYYY-MM-DD` headings; capture version, date,
       and the body until the next `## ` heading (or EOF). Keep a
       Changelog format. */
    const re = /## \[([^\]]+)\][^\n]*?-\s*(\d{4}-\d{2}-\d{2})\n([\s\S]*?)(?=\n## |\n$)/g;
    interface FeedEntryInterface {
      readonly version: string;
      readonly date:    string;
      readonly body:    string;
    }
    const entries: FeedEntryInterface[] = [];
    let m: RegExpExecArray | null;
    while ((m = re.exec(md)) !== null) {
      entries.push({ 'version': m[1] as string, 'date': m[2] as string, 'body': (m[3] ?? '').trim() });
    }
    /* RFC 822 date format is the RSS 2.0 spec requirement. Convert via
       UTC noon to avoid timezone-drift backdating. */
    const rfc822 = (isoDate: string): string => new Date(`${isoDate}T12:00:00Z`).toUTCString();
    const escape = (s: string): string => s
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
    const items = entries.map((entry) => {
      const url = `${SITE_URL}CHANGELOG#${entry.version.toLowerCase().replace(/\./g, '')}`;
      return [
        '    <item>',
        `      <title>${escape(SITE_TITLE)} ${escape(entry.version)}</title>`,
        `      <link>${escape(url)}</link>`,
        `      <guid isPermaLink="false">${escape(SITE_URL)}changelog/${escape(entry.version)}</guid>`,
        `      <pubDate>${rfc822(entry.date)}</pubDate>`,
        `      <description><![CDATA[${entry.body}]]></description>`,
        '    </item>',
      ].join('\n');
    }).join('\n');
    const feed = [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">',
      '  <channel>',
      `    <title>${escape(SITE_TITLE)}: changelog</title>`,
      `    <link>${escape(SITE_URL)}</link>`,
      `    <description>${escape(SITE_DESCRIPTION)}</description>`,
      '    <language>en-US</language>',
      `    <atom:link href="${escape(SITE_URL)}feed.xml" rel="self" type="application/rss+xml" />`,
      items,
      '  </channel>',
      '</rss>',
      '',
    ].join('\n');
    writeFileSync(resolve(siteConfig.outDir, 'feed.xml'), feed);
  },
  'appearance':  themeConfig.appearance,
  'themeConfig': {
    ...themeConfig,
    'nav': [
      { 'link': '/',                                                'text': 'Home'             },
      { 'link': '/support',                                         'text': 'Support'          },
      { 'link': '/architecture',                                    'text': 'Architecture'     },
      { 'link': '/testing',                                         'text': 'Testing'          },
      { 'link': '/sensor-kickstart/',                               'text': 'Sensor Kickstart' },
      { 'link': 'https://github.com/Studnicky/yamete/releases/latest', 'text': 'Releases'      },
      { 'link': SITE_REPO,                                          'text': 'GitHub'           },
    ],
    'sidebar':     sidebar,
    'siteTitle':   SITE_TITLE,
    'socialLinks': [{ 'icon': 'github', 'link': SITE_REPO }],
  },
}));
