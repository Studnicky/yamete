# Yamete — Build Pipeline
#
# Source layout mirrors the final .app bundle:
#   Bundle/Contents/Info.plist          → Yamete.app/Contents/Info.plist
#   Bundle/Contents/Resources/*         → Yamete.app/Contents/Resources/*
#   Sources/**/*.swift                  → compiled into Contents/MacOS/yamete
#
# Build stages:
#   1. compile    swiftc -O → binary
#   2. minify     strip symbols, optimize SVGs (if svgo installed)
#   3. bundle     copy Bundle/ mirror + binary → dist/Yamete.app
#   4. sign       codesign with entitlements + hardened runtime
#   5. verify     validate structure, signature, asset counts

APP       := Yamete
BUNDLE_ID := com.studnicky.yamete
DIST      := dist
BUILD     := .build-stage
TARGET    := $(DIST)/$(APP).app
BINARY    := $(TARGET)/Contents/MacOS/yamete
RES_DIR   := $(TARGET)/Contents/Resources

# Source of truth for bundle contents
BUNDLE_SRC := Bundle/Contents

SOURCES := $(shell find Sources -name '*.swift' | sort)
BUNDLE_RESOURCES := $(shell find $(BUNDLE_SRC)/Resources -type f 2>/dev/null)

FRAMEWORKS := SwiftUI AppKit AVFoundation CoreAudio CoreMotion ServiceManagement
SWIFTFLAGS := -O -module-name $(APP) -target arm64-apple-macosx14.0 -parse-as-library \
              $(addprefix -framework ,$(FRAMEWORKS))

ENTITLE   := Yamete.entitlements
SIGNING_ID ?= -

.PHONY: all build test install uninstall clean dmg lint verify release notarize

all: build

# ── Stage 1: Compile ──────────────────────────────────────────
$(BUILD)/yamete: $(SOURCES)
	@mkdir -p $(BUILD)
	@printf "  compile   $(APP)\n"
	@swiftc $(SWIFTFLAGS) $(SOURCES) -o $(BUILD)/yamete

# ── Stage 2: Minify ───────────────────────────────────────────
$(BUILD)/.minified: $(BUILD)/yamete $(BUNDLE_RESOURCES)
	@printf "  strip     symbols\n"
	@strip -x $(BUILD)/yamete -o $(BUILD)/yamete.stripped
	@mv $(BUILD)/yamete.stripped $(BUILD)/yamete
	@# Copy resources (preserving subdirectory structure)
	@mkdir -p $(BUILD)/resources
	@cp -R $(BUNDLE_SRC)/Resources/ $(BUILD)/resources/
	@# SVG minification (if svgo installed)
	@which svgo > /dev/null 2>&1 && { \
		printf "  minify    SVGs\n"; \
		find $(BUILD)/resources -name '*.svg' -exec svgo -q {} -o {} 2>/dev/null \; ; \
	} || true
	@touch $(BUILD)/.minified

# ── Stage 3: Bundle ───────────────────────────────────────────
build: $(BUILD)/yamete $(BUILD)/.minified
	@mkdir -p $(TARGET)/Contents/MacOS $(RES_DIR)
	@cp $(BUILD)/yamete $(BINARY)
	@cp $(BUNDLE_SRC)/Info.plist $(TARGET)/Contents/
	@cp $(BUNDLE_SRC)/PkgInfo $(TARGET)/Contents/
	@cp -R $(BUILD)/resources/ $(RES_DIR)/
	@# ── Stage 4: Sign ──
	@printf "  sign      $(if $(filter -,$(SIGNING_ID)),ad-hoc,$(SIGNING_ID))\n"
	@codesign --sign "$(SIGNING_ID)" --force --deep --options runtime \
		--entitlements $(ENTITLE) $(TARGET) 2>/dev/null
	@codesign --verify --deep --strict $(TARGET) 2>/dev/null
	@printf "  bundle    $(TARGET) ($$(du -sh $(TARGET) | awk '{print $$1}'))\n"

# ── Lint ──────────────────────────────────────────────────────
lint:
	@printf "  lint      strict concurrency\n"
	@swiftc -typecheck $(SWIFTFLAGS) -strict-concurrency=complete -warnings-as-errors $(SOURCES)

# ── Test ──────────────────────────────────────────────────────
test:
	@swift test

# ── Verify ────────────────────────────────────────────────────
verify: build
	@printf "  verify    bundle\n"
	@test -f $(BINARY)
	@test -f $(TARGET)/Contents/Info.plist
	@test -d $(RES_DIR)/faces && test -d $(RES_DIR)/sounds
	@FACES=$$(find $(RES_DIR)/faces -type f \( -name '*.svg' -o -name '*.png' -o -name '*.jpg' \) | wc -l | tr -d ' '); \
	 SOUNDS=$$(find $(RES_DIR)/sounds -type f \( -name '*.mp3' -o -name '*.wav' -o -name '*.m4a' \) | wc -l | tr -d ' '); \
	 test "$$FACES" -ge 1 && test "$$SOUNDS" -ge 1 && \
	 codesign --verify --deep --strict $(TARGET) 2>/dev/null && \
	 printf "  verify    ✓ binary, plist, $$FACES faces, $$SOUNDS sounds, signature\n"

# ── Install ───────────────────────────────────────────────────
install: build
	@printf "  stop      $(APP)\n"
	@pkill -x yamete 2>/dev/null; osascript -e 'quit app "$(APP)"' 2>/dev/null; sleep 0.5; pkill -9 -x yamete 2>/dev/null || true
	@printf "  install   /Applications/$(APP).app\n"
	@rm -rf /Applications/$(APP).app
	@cp -R $(TARGET) /Applications/
	@open /Applications/$(APP).app
	@printf "  launch    $(APP)\n"

uninstall:
	@pkill -x yamete 2>/dev/null || true
	@rm -rf /Applications/$(APP).app
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
