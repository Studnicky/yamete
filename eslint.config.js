// Project-local ESLint config. This is a Swift/macOS project; the
// workspace-wide litany rules don't have a useful surface here.
// Ignore everything that isn't ours so the lint pass is a no-op.
import { eslintConfigBase } from '/Users/studs/Workspace/code-quality/noocodec/packages/cogitator/dist/eslint/index.js'
export default [
  {
    ignores: [
      '**/*',  // ignore everything; this project lints via `make lint` (Swift strict-concurrency) instead
    ],
  },
]
