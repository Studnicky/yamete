/* global document */
'use strict';

const REPO = 'https://github.com/Studnicky/yamete';
const RELEASES_URL = `${REPO}/releases/latest`;
const ISSUES_URL = `${REPO}/issues`;

function initSidebar(tocItems, activePage) {
  const tocHtml = tocItems.map(({
    href, label
  }) => {
    const result = `<li><a href="${href}">${label}</a></li>`;

    return result;
  }).join('\n          ');

  const pages = [
    {
      'href': 'index.html',
      'label': 'Home'
    },
    {
      'href': 'support.html',
      'label': 'Support &amp; FAQ'
    },
    {
      'href': 'privacy.html',
      'label': 'Privacy Policy'
    },
    {
      'href': 'architecture.html',
      'label': 'Architecture'
    },
    {
      'href': RELEASES_URL,
      'label': 'Releases'
    },
    {
      'href': ISSUES_URL,
      'label': 'Issues'
    },
    {
      'href': REPO,
      'label': 'GitHub'
    }
  ];

  const pagesHtml = pages.map(({
    href, label
  }) => {
    const isActive = href === activePage;

    return `<li><a href="${href}"${isActive ? ' style="color:var(--accent-soft)"' : ''}>${label}</a></li>`;
  }).join('\n          ');

  document.getElementById('sidebar-placeholder').innerHTML = `
    <a href="index.html"><img src="assets/icon.png" alt="Yamete icon" class="app-icon"></a>
    <h1><a href="index.html" style="color:inherit;text-decoration:none">Yamete</a></h1>
    <p class="tagline">Your MacBook reacts when you smack it.</p>
    <span class="badge">macOS 14+ · v2.0.0</span>

    <a class="dl-btn" href="${RELEASES_URL}">Download Yamete Direct</a>
    <span class="dl-sub">App Store coming soon</span>

    <span class="toc-label">On this page</span>
    <ul class="toc">
      ${tocHtml}
    </ul>

    <span class="pages-label">Pages</span>
    <ul class="page-links">
      ${pagesHtml}
    </ul>
  `;
}
