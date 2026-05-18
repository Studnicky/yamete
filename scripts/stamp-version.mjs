#!/usr/bin/env node
/**
 * Stamp the current marketing version into versioned SVG assets.
 *
 * Reads `project.yml` for `settings.base.MARKETING_VERSION` (the canonical
 * macOS bundle version source of truth), then for each `.svg.template`
 * under `docs/public/`, writes a sibling `.svg` with every `__VERSION__`
 * placeholder replaced by `v<version>`.
 *
 * Designed to be run before release commits so the SVG referenced by the
 * GitHub release notes always carries the released version.
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

const version = readMarketingVersion();
const tag     = `v${version}`;

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
  const stamped      = readFileSync(templatePath, 'utf8').replaceAll('__VERSION__', tag);

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
  console.log(`stamp-version: wrote ${basename(outputPath)} (${tag})`);
}

if (checkOnly && drift) {
  console.error('stamp-version: run `node scripts/stamp-version.mjs` to regenerate');
  process.exit(1);
}
