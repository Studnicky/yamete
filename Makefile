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
SWIFTFLAGS := -O -module-name YameteApp -target arm64-apple-macosx14.0 -parse-as-library \
              $(VARIANT_FLAGS) \
              $(addprefix -framework ,$(FRAMEWORKS)) \
              -I Sources/IOHIDPublic/include

SIGNING_ID ?= -

.PHONY: all build test install uninstall clean dmg lint lint-frameworks verify release notarize \
        appstore appstore-install appstore-lint

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
build: $(BUILD_BINARY) $(BUILD)/.minified
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
lint: lint-frameworks
	@printf "  lint      strict concurrency\n"
	@swiftc -typecheck $(SWIFTFLAGS) -strict-concurrency=complete -warnings-as-errors $(SOURCES)

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
