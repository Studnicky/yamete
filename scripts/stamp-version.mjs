#!/usr/bin/env node
/**
 * Stamp current marketing version + embedded app-icon data URI into
 * versioned SVG assets.
 *
 * Reads `project.yml` for `settings.base.MARKETING_VERSION` (the canonical
 * macOS bundle version source of truth) and reads `docs/public/icon.png`
 * as the canonical brand mark. For each `.svg.template` under
 * `docs/public/`, writes a sibling `.svg` with:
 *   __VERSION__       replaced by `v<version>`
 *   __ICON_DATA_URI__ replaced by a base64 PNG data URI of the icon
 *                     downscaled to 320×320 (~60 KB on disk; ~80 KB
 *                     after base64 expansion). The icon is the same one
 *                     shipped in the docs site favicon stack and the
 *                     README header, so the social banners read as the
 *                     same product.
 *
 * Designed to run before release commits so the SVG referenced by the
 * GitHub release notes always carries the released version and the
 * SVG can be served standalone (no relative-URL image references that
 * GitHub's content proxy or arbitrary renderers might fail to resolve).
 *
 * Usage:
 *   node scripts/stamp-version.mjs           # stamp + write
 *   node scripts/stamp-version.mjs --check   # exit non-zero if any output is stale
 */

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT             = join(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_YML_PATH = join(ROOT, 'project.yml');
const PUBLIC_DIR       = join(ROOT, 'docs/public');
/**
 * `App/Resources/menubar_icon.png` is the canonical face source: the
 * original 1024×1024 line-art bitmap (black on white, no rounded
 * squircle, fills the frame). Every other icon surface — App icon set,
 * docs site favicon, yamete_icon_source.svg — derives from it. We
 * tone-map the bitmap on the fly: where pixels are dark, we substitute
 * the brand pink `#ff6b8a`; where pixels are bright, we keep them
 * white. The result reads as pink line art on white, matching the
 * design reference and tracking the source bitmap if the artist ever
 * updates it.
 */
const ICON_SRC_PATH    = join(ROOT, 'App/Resources/menubar_icon.png');
const ICON_EMBED_SIZE  = 320;
const BRAND_PINK_RGB   = [0xff, 0x6b, 0x8a];

/**
 * Extract MARKETING_VERSION from project.yml without pulling in a YAML
 * dependency. The XcodeGen schema places it at
 * `settings.base.MARKETING_VERSION` as a quoted string literal; a single
 * targeted regex is enough and avoids adding `yaml` to the dev tree.
 */
function readMarketingVersion() {
  const yml = readFileSync(PROJECT_YML_PATH, 'utf8');
  const match = yml.match(/^\s{4}MARKETING_VERSION:\s*"?([^"\n]+)"?\s*$/m);
  if (!match || !match[1]) {
    console.error('stamp-version: failed to locate settings.base.MARKETING_VERSION in project.yml');
    process.exit(1);
  }
  return match[1].trim();
}

/**
 * Build a base64 PNG data URI for the canonical app icon, downscaled
 * to ICON_EMBED_SIZE so the embedded payload stays bounded (~80 KB) no
 * matter what resolution the source PNG ships at. Sharp is required;
 * if it cannot be loaded, the templates that depend on the icon will
 * still substitute the version placeholder but the icon placeholder
 * will pass through unreplaced — the next caller of `render-og` (which
 * loads sharp) will surface the missing dep clearly.
 */
async function buildIconDataUri() {
  const { default: sharp } = await import('sharp');
  /* Read the source bitmap as flat sRGB so we can luminance-mix each
     pixel between the brand pink and pure white. Anti-aliased line
     edges get intermediate pink shades automatically (no banding). */
  const { data, info } = await sharp(ICON_SRC_PATH)
    .removeAlpha()
    .toColourspace('srgb')
    .raw()
    .toBuffer({ 'resolveWithObject': true });

  const pixelCount = info.width * info.height;
  const recolored  = Buffer.alloc(pixelCount * 4);
  const [pinkR, pinkG, pinkB] = BRAND_PINK_RGB;
  for (let i = 0; i < pixelCount; i++) {
    /* Luminance 0..1: 0 = pure black (full ink), 1 = pure white. */
    const lum = (data[i * 3] + data[i * 3 + 1] + data[i * 3 + 2]) / (3 * 255);
    const ink = 1 - lum;
    recolored[i * 4]     = Math.round(255 * lum + pinkR * ink);
    recolored[i * 4 + 1] = Math.round(255 * lum + pinkG * ink);
    recolored[i * 4 + 2] = Math.round(255 * lum + pinkB * ink);
    recolored[i * 4 + 3] = 255;
  }
  const buf = await sharp(recolored, { 'raw': { 'width': info.width, 'height': info.height, 'channels': 4 } })
    .resize(ICON_EMBED_SIZE, ICON_EMBED_SIZE, { 'fit': 'cover' })
    .png({ 'compressionLevel': 9 })
    .toBuffer();
  return `data:image/png;base64,${buf.toString('base64')}`;
}

const version     = readMarketingVersion();
const tag         = `v${version}`;
const iconDataUri = await buildIconDataUri();

const templates = readdirSync(PUBLIC_DIR).filter((f) => f.endsWith('.svg.template'));
if (templates.length === 0) {
  console.error('stamp-version: no .svg.template files under docs/public/');
  process.exit(1);
}

const checkOnly = process.argv.includes('--check');
let drift       = false;

for (const tmpl of templates) {
  const templatePath = join(PUBLIC_DIR, tmpl);
  const outputPath   = join(PUBLIC_DIR, basename(tmpl, '.template'));
  const stamped      = readFileSync(templatePath, 'utf8')
    .replaceAll('__VERSION__',       tag)
    .replaceAll('__ICON_DATA_URI__', iconDataUri);

  if (checkOnly) {
    let existing = '';
    try { existing = readFileSync(outputPath, 'utf8'); } catch { /* missing */ }
    if (existing !== stamped) {
      console.error(`stamp-version: ${basename(outputPath)} is stale (expected version ${tag})`);
      drift = true;
    }
    continue;
  }

  writeFileSync(outputPath, stamped);
  console.log(`stamp-version: wrote ${basename(outputPath)} (${tag}, icon ${ICON_EMBED_SIZE}×${ICON_EMBED_SIZE})`);
}

if (checkOnly && drift) {
  console.error('stamp-version: run `node scripts/stamp-version.mjs` to regenerate');
  process.exit(1);
}
