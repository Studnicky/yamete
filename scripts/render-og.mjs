#!/usr/bin/env node
/**
 * Render og-image.svg → og-image.png (1200×630) for social-share unfurls.
 *
 * Discord, Slack, iMessage, Twitter/X, and LinkedIn all require a raster
 * og:image; SVG-only unfurls fall back to the bare hostname card. Sharp
 * (libvips under the hood) is the most reliable Node SVG-to-PNG rasteriser
 * and is already the default tooling in most Node ecosystems.
 *
 * Inputs:
 *   docs/public/og-image.svg            (timeless social card)
 *   docs/public/yamete-banner.svg       (version-stamped release banner)
 *
 * Outputs:
 *   docs/public/og-image.png            (1200×630, fed to og:image)
 *   docs/public/yamete-banner.png       (1200×630, fed to release notes)
 *
 * Skips silently if sharp is unavailable — the SVG sources stay in the
 * tree and CI installs sharp as a devDep before invoking this script.
 *
 * Usage:
 *   node scripts/render-og.mjs
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT       = join(dirname(fileURLToPath(import.meta.url)), '..');
const PUBLIC_DIR = join(ROOT, 'docs/public');

let sharp;
try {
  ({ default: sharp } = await import('sharp'));
} catch {
  console.warn('render-og: sharp not installed; skipping PNG render. Run `npm install` first.');
  process.exit(0);
}

const targets = [
  { 'src': 'og-image.svg',      'out': 'og-image.png' },
  { 'src': 'yamete-banner.svg', 'out': 'yamete-banner.png' },
];

for (const { src, out } of targets) {
  const srcPath = join(PUBLIC_DIR, src);
  const outPath = join(PUBLIC_DIR, out);
  if (!existsSync(srcPath)) {
    console.warn(`render-og: ${src} missing; skipping`);
    continue;
  }
  const svg = readFileSync(srcPath);
  const png = await sharp(svg, { 'density': 144 })
    .resize(1200, 630, { 'fit': 'cover' })
    .png({ 'compressionLevel': 9, 'palette': false })
    .toBuffer();
  writeFileSync(outPath, png);
  console.log(`render-og: wrote ${out} (${png.length} bytes)`);
}
