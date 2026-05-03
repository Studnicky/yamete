# Yamete — Build Pipeline
#
# Source layout mirrors the final .app bundle:
#   App/Config/Info.plist               → Yamete Direct.app/Contents/Info.plist
#   App/Config/PkgInfo                  → Yamete Direct.app/Contents/PkgInfo
#   App/Resources/*                     → Yamete Direct.app/Contents/Resources/*
#   Sources/**/*.swift                  → compiled into Contents/MacOS/yamete-direct
#
# Build stages:
#   1. compile    swiftc -O → binary
#   2. minify     strip symbols, optimize SVGs (if svgo installed)
#   3. bundle     copy App/ layout + binary → dist/Yamete Direct.app
#   4. sign       codesign with entitlements + hardened runtime
#   5. verify     validate structure, signature, asset counts

# ── Build variant selection ───────────────────────────────────
# BUILD_VARIANT controls which app gets built:
#   direct   → Yamete Direct.app (notarized direct download, spicy content)
#   appstore → Yamete.app        (Mac App Store, tame content only)
# Default is direct so existing `make`, `make install`, `make build` keep
# their previous behavior. Use `make appstore` or `make appstore-install`
# (or `BUILD_VARIANT=appstore make build`) for the App Store variant.
BUILD_VARIANT ?= direct

ifeq ($(BUILD_VARIANT),appstore)
APP        := Yamete
EXECUTABLE := yamete
BUNDLE_ID  := com.studnicky.yamete
ENTITLE    := App/Config/AppStore.entitlements
VARIANT_FLAGS :=
APPLY_DIRECT_OVERLAY := 0
else ifeq ($(BUILD_VARIANT),direct)
APP        := Yamete Direct
EXECUTABLE := yamete-direct
BUNDLE_ID  := com.studnicky.yamete.direct
ENTITLE    := App/Config/Direct.entitlements
VARIANT_FLAGS := -D DIRECT_BUILD
APPLY_DIRECT_OVERLAY := 1
else
$(error BUILD_VARIANT must be 'direct' or 'appstore', got '$(BUILD_VARIANT)')
endif

# ── yq dependency check ───────────────────────────────────────
# Structured queries against project.yml use yq (not sed regex). This keeps
# Makefile and CI in sync with the YAML schema and avoids brittle patterns
# that break the moment formatting changes. yq must be installed locally;
# print a helpful error and bail early if it is missing.
YQ := $(shell command -v yq 2>/dev/null)
ifndef YQ
$(error yq not found in PATH. Install with `brew install yq` (https://github.com/mikefarah/yq))
endif

DEVELOPMENT_LANGUAGE := en
MARKETING_VERSION := $(shell yq -r '.settings.base.MARKETING_VERSION' project.yml)
CURRENT_PROJECT_VERSION := $(shell yq -r '.settings.base.CURRENT_PROJECT_VERSION' project.yml)
DIST      := dist
BUILD     := .build-stage/$(BUILD_VARIANT)
TARGET    := $(DIST)/$(APP).app
BINARY    := $(TARGET)/Contents/MacOS/$(EXECUTABLE)
RES_DIR   := $(TARGET)/Contents/Resources
BUILD_BINARY := $(BUILD)/$(EXECUTABLE)

APP_LAYOUT      := App
CONFIG_DIR      := $(APP_LAYOUT)/Config
RESOURCE_SRC    := $(APP_LAYOUT)/Resources
# Direct-only resources (spicy DDLG Moans.strings overrides). Copied on top
# of $(RESOURCE_SRC) at bundle time for the Direct build, NEVER for App Store.
RESOURCE_DIRECT := $(APP_LAYOUT)/Resources-Direct
INFO_PLIST      := $(CONFIG_DIR)/Info.plist
PKGINFO         := $(CONFIG_DIR)/PkgInfo

SOURCES := $(shell find Sources -name '*.swift' | sort)
BUNDLE_RESOURCES := $(shell find $(RESOURCE_SRC) $(RESOURCE_DIRECT) -type f 2>/dev/null)

# ── Framework list (drift-guarded) ────────────────────────────
# The set of system frameworks the app links against is enumerated in THREE
# places that must stay in lockstep:
#   1. This FRAMEWORKS variable           (Makefile: `make build` / `make lint`)
#   2. Package.swift  `.linkedFramework(…)` entries per target (SPM builds)
#   3. project.yml    `dependencies: [- sdk: …]` on the Yamete target (Xcode)
# The `lint-frameworks` target below diffs all three and fails if they disagree,
# so any addition/removal here MUST be mirrored in Package.swift and project.yml.
# Keep the list sorted in normalized form (framework basename, no `.framework`
# suffix, case-sensitive) to make diffs readable.
FRAMEWORKS := AppKit AVFoundation CoreAudio CoreMotion IOKit ServiceManagement SwiftUI UserNotifications
# RAW_SWIFTC_LUMP: Set during Makefile-driven raw-swiftc compilation, where
# every Sources/**/*.swift file is fed to a single `-module-name YameteApp`
# invocation. Under SPM (`swift test`) and xcodebuild (`make test-host-app`)
# each module compiles to its own .swiftmodule and the symbol resolves via
# `import YameteCore` / `import SensorKit` / `import ResponseKit` /
# `import YameteApp`. Source files use `#if !RAW_SWIFTC_LUMP` to skip those
# imports under the lump (where the symbols are intra-module and a self-import
# is a no-op warning that becomes an error under -warnings-as-errors).
SWIFTFLAGS := -O -module-name YameteApp -target arm64-apple-macosx14.0 -parse-as-library \
              -swift-version 6 \
              -D RAW_SWIFTC_LUMP \
              $(VARIANT_FLAGS) \
              $(addprefix -framework ,$(FRAMEWORKS)) \
              -I Sources/IOHIDPublic/include

SIGNING_ID ?= -

.PHONY: all build test test-host-app install uninstall clean dmg lint lint-frameworks docs-check verify release notarize \
        appstore appstore-install appstore-lint mutate mutate-pr perf-baseline perf-baseline-record check-versions hooks

all: build

# ── Stage 1: Compile ──────────────────────────────────────────
$(BUILD_BINARY): $(SOURCES)
	@mkdir -p $(BUILD)
	@printf "  compile   $(APP)\n"
	@swiftc $(SWIFTFLAGS) $(SOURCES) -o "$(BUILD_BINARY)"

# ── Stage 2: Minify ───────────────────────────────────────────
$(BUILD)/.minified: $(BUILD_BINARY) $(BUNDLE_RESOURCES)
	@printf "  strip     symbols\n"
	@strip -x "$(BUILD_BINARY)" -o "$(BUILD_BINARY).stripped"
	@mv "$(BUILD_BINARY).stripped" "$(BUILD_BINARY)"
	@# Stage resources: tame base, then direct overlay if applicable.
	@# The overlay replaces tame Moans.strings with spicy DDLG content.
	@# It is gated on BUILD_VARIANT — App Store build NEVER copies the overlay.
	@rm -rf "$(BUILD)/resources"
	@mkdir -p "$(BUILD)/resources"
	@rsync -a --exclude '*.xcassets' "$(RESOURCE_SRC)/" "$(BUILD)/resources/"
ifeq ($(APPLY_DIRECT_OVERLAY),1)
	@if [ -d "$(RESOURCE_DIRECT)" ]; then \
		printf "  overlay   $(RESOURCE_DIRECT)\n"; \
		rsync -a "$(RESOURCE_DIRECT)/" "$(BUILD)/resources/"; \
	fi
else
	@printf "  variant   $(BUILD_VARIANT) (no overlay)\n"
endif
	@# SVG minification (if svgo installed)
	@which svgo > /dev/null 2>&1 && { \
		printf "  minify    SVGs\n"; \
		find "$(BUILD)/resources" -name '*.svg' -exec svgo -q {} -o {} 2>/dev/null \; ; \
	} || true
	@touch $(BUILD)/.minified

# ── Stage 3: Bundle ───────────────────────────────────────────
build: hooks $(BUILD_BINARY) $(BUILD)/.minified
	@rm -rf "$(TARGET)"
	@mkdir -p "$(TARGET)/Contents/MacOS" "$(RES_DIR)"
	@cp "$(BUILD_BINARY)" "$(BINARY)"
	@cp "$(INFO_PLIST)" "$(TARGET)/Contents/Info.plist"
	@cp "$(PKGINFO)" "$(TARGET)/Contents/PkgInfo"
	@plutil -replace CFBundleDevelopmentRegion -string "$(DEVELOPMENT_LANGUAGE)" "$(TARGET)/Contents/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(EXECUTABLE)" "$(TARGET)/Contents/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(TARGET)/Contents/Info.plist"
	@plutil -replace CFBundleName -string "$(APP)" "$(TARGET)/Contents/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP)" "$(TARGET)/Contents/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(MARKETING_VERSION)" "$(TARGET)/Contents/Info.plist"
	@plutil -replace CFBundleVersion -string "$(CURRENT_PROJECT_VERSION)" "$(TARGET)/Contents/Info.plist"
	@cp -R "$(BUILD)/resources/." "$(RES_DIR)/"
	@LCOUNT=$$(find "$(RES_DIR)" -maxdepth 1 -name '*.lproj' -type d | wc -l | tr -d ' '); \
	 printf "  l10n      $$LCOUNT locales\n"
	@# ── Stage 4: Sign ──
	@printf "  sign      $(if $(filter -,$(SIGNING_ID)),ad-hoc,$(SIGNING_ID))\n"
	@codesign --sign "$(SIGNING_ID)" --force --deep --options runtime \
		--entitlements "$(ENTITLE)" "$(TARGET)" 2>/dev/null
	@codesign --verify --deep --strict "$(TARGET)" 2>/dev/null
	@SIZE=$$(du -sh "$(TARGET)" | awk '{print $$1}'); \
	 printf "  bundle    $(TARGET) ($$SIZE)\n"

# ── Lint ──────────────────────────────────────────────────────
lint: lint-frameworks docs-check
	@printf "  lint      strict concurrency (Sources/)\n"
	@swiftc -typecheck $(SWIFTFLAGS) -strict-concurrency=complete -warnings-as-errors $(SOURCES)
	@printf "  lint      strict concurrency (Tests/ via SPM)\n"
	@swift build --build-tests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors >/dev/null
	@printf "  lint      Tests target compiled clean under strict concurrency\n"

# ── Lint: framework-list drift guard ─────────────────────────
# Fails if the framework list in the Makefile (FRAMEWORKS), Package.swift
# (.linkedFramework(…) across all targets), and project.yml (sdk: …
# dependencies on the Yamete target) disagree. See the comment block above
# FRAMEWORKS for why this matters. Normalizes by stripping `.framework`
# suffixes and sorting.
lint-frameworks:
	@printf "  lint      framework-list drift guard\n"
	@YML_LIST=$$(yq -r '.targets.Yamete.dependencies[] | select(.sdk) | .sdk' project.yml \
		| sed 's/\.framework$$//' | sort -u); \
	PKG_LIST=$$(grep -E '^[[:space:]]*\.linkedFramework\(' Package.swift \
		| sed -E 's/.*\.linkedFramework\("([^"]+)"\).*/\1/' | sort -u); \
	MAK_LIST=$$(printf '%s\n' $(FRAMEWORKS) | sort -u); \
	YML_TMP=$$(mktemp); PKG_TMP=$$(mktemp); MAK_TMP=$$(mktemp); \
	printf '%s\n' "$$YML_LIST" > "$$YML_TMP"; \
	printf '%s\n' "$$PKG_LIST" > "$$PKG_TMP"; \
	printf '%s\n' "$$MAK_LIST" > "$$MAK_TMP"; \
	DIFF_YP=$$(diff -u "$$YML_TMP" "$$PKG_TMP" || true); \
	DIFF_YM=$$(diff -u "$$YML_TMP" "$$MAK_TMP" || true); \
	rm -f "$$YML_TMP" "$$PKG_TMP" "$$MAK_TMP"; \
	if [ -n "$$DIFF_YP" ] || [ -n "$$DIFF_YM" ]; then \
		printf "  FAIL      framework lists drifted across sources\n"; \
		printf "\n  project.yml (sdk:) vs Package.swift (.linkedFramework):\n"; \
		printf "%s\n" "$$DIFF_YP"; \
		printf "\n  project.yml (sdk:) vs Makefile FRAMEWORKS:\n"; \
		printf "%s\n" "$$DIFF_YM"; \
		printf "\n  Fix: align all three. Sources:\n"; \
		printf "    - Makefile FRAMEWORKS variable\n"; \
		printf "    - Package.swift .linkedFramework(...) per target\n"; \
		printf "    - project.yml targets.Yamete.dependencies (sdk: X.framework)\n"; \
		exit 1; \
	fi
	@printf "  lint      ✓ frameworks aligned across Makefile, Package.swift, project.yml\n"

# ── Docs: source reference check ─────────────────────────────
# Validates that every Sources/**/*.swift path mentioned in docs/*.html
# still exists. Prevents docs from silently referencing deleted files.
docs-check:
	@printf "  check     doc source references\n"
	@grep -oh 'Sources/[A-Za-z]*/[A-Za-z]*\.swift' docs/*.html 2>/dev/null | \
	  sort -u | while read f; do \
	    test -f "$$f" || { echo "  ✗ docs references missing file: $$f"; exit 1; }; \
	  done
	@printf "  ok        all source references valid\n"

# ── Version consistency gate ─────────────────────────────────
# project.yml MARKETING_VERSION is the canonical version; docs files that
# embed a version string must match it. Caught a real miss on v2.0.0
# where MARKETING_VERSION was left at 1.3.2 and the release.yml
# workflow only flagged it AFTER the tag was pushed.
check-versions:
	@printf "  check     version consistency\n"
	@scripts/check-versions.sh

# ── App Store build convenience targets ──────────────────────
# These wrappers force BUILD_VARIANT=appstore so the right resources,
# bundle ID, executable name, and entitlements are used. The default
# `make build` / `make install` keep building Direct.

# NOTE: `make appstore` builds the sandboxed App Store variant. Sandbox
# entitlements ONLY apply to this target (and archive) — not Xcode's Run
# button on the Yamete-AppStore scheme, which uses Debug config.
appstore:
	@$(MAKE) build BUILD_VARIANT=appstore

appstore-install:
	@$(MAKE) install BUILD_VARIANT=appstore

# Bundle-lint gate for App Store builds. Fails if any spicy content leaked
# into a Moans.strings file in the bundle. Re-runs the bundle build under
# BUILD_VARIANT=appstore so the lint always reflects the App Store layout
# regardless of which variant was last built.
appstore-lint:
	@$(MAKE) build BUILD_VARIANT=appstore
	@printf "  appstore  lint Moans.strings for spicy leakage\n"
	@FOUND=0; \
	for f in "$(DIST)/Yamete.app/Contents/Resources"/*.lproj/Moans.strings; do \
		if [ -f "$$f" ] && plutil -p "$$f" 2>/dev/null | grep -qi 'daddy'; then \
			printf "  FAIL      $$f contains 'daddy'\n"; \
			FOUND=1; \
		fi; \
	done; \
	if [ "$$FOUND" -eq 0 ]; then \
		printf "  appstore  ✓ no spicy leakage in Moans.strings\n"; \
	else \
		exit 1; \
	fi

# ── Test ──────────────────────────────────────────────────────
test:
	@swift test

# ── Test (host-app, Phase 1) ─────────────────────────────────
# Runs the YameteHostTest test bundle inside the bundled `Yamete.app`
# host so `Bundle.main` resolves to a real `.app` at runtime. Cells
# that XCTSkip under SPM (UN center, full Haptic engine, CGEvent.post
# under Accessibility) execute their Real-driver halves here. See
# Tests/Mutation/README.md → "Phase 1 — host-app xcodebuild".
#
# Regenerates Yamete.xcodeproj on the fly (project.yml is the source of
# truth; .xcodeproj is gitignored) and then drives xcodebuild against
# the YameteHostTest scheme on macOS arm64.
test-host-app: hooks
	@printf "  xcodegen  Yamete.xcodeproj\n"
	@xcodegen generate --quiet
	@printf "  xcodebuild test  -scheme YameteHostTest\n"
	@xcodebuild test \
		-project Yamete.xcodeproj \
		-scheme YameteHostTest \
		-destination 'platform=macOS,arch=arm64' \
		-quiet
	@mkdir -p build && git rev-parse HEAD > build/.host-app-test-fresh
	@printf "  ok        host-app sentinel recorded (build/.host-app-test-fresh = $$(cat build/.host-app-test-fresh))\n"

# ── Local pre-push gate setup ────────────────────────────────
# Installs the repo's checked-in git hooks under .githooks. Idempotent;
# safe to run repeatedly (and on CI — the hooks themselves bail when
# CI=true). Wired into `build` and `test-host-app` so a fresh checkout
# self-bootstraps on first build.
hooks:
	@if [ "$$(git config --get core.hooksPath 2>/dev/null)" != ".githooks" ]; then \
		git config core.hooksPath .githooks; \
		printf "  hooks     core.hooksPath = .githooks\n"; \
	fi

# ── Performance baseline regression detection ────────────────
# `Tests/Performance_Tests.swift` cells assert RATIO bounds (second-half
# median ≤ 3× first-half median) inside each cell, but a 2× CPU
# regression that stays within that ratio slips through. The
# perf-baseline pair adds absolute-baseline tracking on top:
#
#   make perf-baseline         compare current run vs Tests/Performance/baselines.json
#                              fails on any cell exceeding its tolerance_factor
#                              (default 2.0×). Use in PR/CI gates.
#
#   make perf-baseline-record  capture a fresh baselines.json. Foot-gun
#                              guarded behind YAMETE_BASELINE_RECORD=1
#                              so accidental "blessing" of a regression
#                              is impossible. Use only after a deliberate
#                              perf-improving change has landed.
perf-baseline:
	@scripts/perf-baseline.sh

perf-baseline-record:
	@scripts/perf-baseline-record.sh

# ── Mutate (mutation-test runner) ─────────────────────────────
# Drives Tests/Mutation/mutation-catalog.json: applies each declarative
# (search→replace) mutation to a clean Sources/ tree, runs the named XCTest
# and asserts it FAILS with the catalogued substring, then reverts via
# `git checkout --`. Refuses to run on a dirty tree (the revert path would
# clobber unstaged work). Exit 0 only when total == caught, so this target
# can be wired into release gating without further wrapping. Catalog
# additions happen in JSON, not here — never commits, never modifies
# Sources/ permanently.
mutate:
	@scripts/mutation-test.sh

# Phase 2.1 sustainability target. Sliced mutate: filters
# Tests/Mutation/mutation-catalog.json down to entries whose targetFile
# was touched on this branch vs. the PR base (BASE_REF env or
# origin/develop fallback), then runs only those mutations through the
# canonical runner. Typical PR touches 1–5 files (1–10 mutations) so a
# slice run completes in ~1–2 minutes — fast enough to stay a required
# PR gate without burning ~20 minutes of macOS-runner time. The full
# `make mutate` still runs nightly + on push to master/develop to catch
# drift the slice can miss (catalog edits on un-touched files, refactors
# that move a search snippet without renaming targetFile, etc.).
mutate-pr:
	@scripts/mutation-test-slice.sh

# ── Verify ────────────────────────────────────────────────────
verify: build
	@printf "  verify    bundle\n"
	@test -f "$(BINARY)"
	@test -f "$(TARGET)/Contents/Info.plist"
	@test -d "$(RES_DIR)/faces" && test -d "$(RES_DIR)/sounds"
	@FACES=$$(find "$(RES_DIR)/faces" -type f \( -name '*.svg' -o -name '*.png' -o -name '*.jpg' \) | wc -l | tr -d ' '); \
	 SOUNDS=$$(find "$(RES_DIR)/sounds" -type f \( -name '*.mp3' -o -name '*.wav' -o -name '*.m4a' \) | wc -l | tr -d ' '); \
	 LPROJS=$$(find "$(RES_DIR)" -maxdepth 1 -name '*.lproj' -type d | wc -l | tr -d ' '); \
	 test "$$FACES" -ge 1 && test "$$SOUNDS" -ge 1 && test "$$LPROJS" -ge 1 && \
	 codesign --verify --deep --strict "$(TARGET)" 2>/dev/null && \
	 printf "  verify    ✓ binary, plist, $$FACES faces, $$SOUNDS sounds, $$LPROJS locales, signature\n"

# ── Install ───────────────────────────────────────────────────
install: build
	@printf "  stop      $(APP)\n"
	@pkill -x "$(EXECUTABLE)" 2>/dev/null; osascript -e 'quit app "$(APP)"' 2>/dev/null; sleep 0.5; pkill -9 -x "$(EXECUTABLE)" 2>/dev/null || true
	@printf "  install   /Applications/$(APP).app\n"
	@rm -rf "/Applications/$(APP).app"
	@cp -R "$(TARGET)" /Applications/
	@open "/Applications/$(APP).app"
	@printf "  launch    $(APP)\n"

uninstall:
	@pkill -x "$(EXECUTABLE)" 2>/dev/null || true
	@rm -rf "/Applications/$(APP).app"
	@printf "  remove    /Applications/$(APP).app\n"

# ── Release (with Developer ID signing) ───────────────────────
release: clean
	@$(MAKE) build SIGNING_ID="$(SIGNING_ID)"
	@printf "  hardened  signed for distribution\n"

# ── Notarize ──────────────────────────────────────────────────
notarize: release dmg
	@printf "  notarize  $(DIST)/$(APP).dmg\n"
	@xcrun notarytool submit "$(DIST)/$(APP).dmg" --wait --keychain-profile "yamete-notarize"
	@xcrun stapler staple "$(DIST)/$(APP).dmg"
	@printf "  stapled   $(DIST)/$(APP).dmg\n"

# ── DMG ───────────────────────────────────────────────────────
DMG     := $(DIST)/$(APP).dmg
DMG_TMP := $(DIST)/.dmg_staging

dmg: build
	@printf "  stage     DMG\n"
	@rm -rf "$(DMG_TMP)" "$(DMG)"
	@mkdir -p "$(DMG_TMP)"
	@cp -R "$(TARGET)" "$(DMG_TMP)/"
	@ln -sf /Applications "$(DMG_TMP)/Applications"
	@mkdir -p "$(DMG_TMP)/.background"
	@cp Assets/dmg_background.png "$(DMG_TMP)/.background/"
	@printf "  pack      $(DMG)\n"
	@hdiutil create -volname "$(APP)" -srcfolder "$(DMG_TMP)" \
		-ov -format UDRW "$(DIST)/$(APP)_rw.dmg" > /dev/null
	@hdiutil attach "$(DIST)/$(APP)_rw.dmg" -mountpoint "$(DIST)/$(APP)_vol" -quiet
	@cp "$(RES_DIR)/AppIcon.icns" \
		"$(DIST)/$(APP)_vol/.VolumeIcon.icns" 2>/dev/null || true
	@SetFile -a C "$(DIST)/$(APP)_vol" 2>/dev/null || true
	@osascript scripts/dmg-layout.applescript "$(APP)" 2>/dev/null || true
	@hdiutil detach "$(DIST)/$(APP)_vol" -quiet
	@hdiutil convert "$(DIST)/$(APP)_rw.dmg" -format UDZO -o "$(DMG)" > /dev/null
	@rm -f "$(DIST)/$(APP)_rw.dmg"
	@rm -rf "$(DMG_TMP)"
	@printf "  done      $(DMG)\n"

# ── Clean ─────────────────────────────────────────────────────
clean:
	@rm -rf $(DIST) $(BUILD)
	@printf "  clean\n"
