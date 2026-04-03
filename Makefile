# Yamete — Build Pipeline
#
# Stages:
#   1. compile    swiftc -O → binary
#   2. optimize   SVG minification, PNG compression
#   3. bundle     Assemble .app structure
#   4. sign       Ad-hoc codesign with entitlements
#   5. verify     Validate bundle structure + signature
#
# The dist/ folder IS the bundle — it mirrors the final .app structure.

APP       := Yamete
BUNDLE_ID := com.yamete
DIST      := dist
BUNDLE    := $(DIST)/$(APP).app
BINARY    := $(BUNDLE)/Contents/MacOS/yamete
RES_DIR   := $(BUNDLE)/Contents/Resources

SOURCES := \
	Sources/Domain.swift \
	Sources/Logging.swift \
	Sources/SignalProcessing.swift \
	Sources/SignalDetectors.swift \
	Sources/ImpactDetector.swift \
	Sources/AccelerometerReader.swift \
	Sources/AudioDevice.swift \
	Sources/AudioPlayer.swift \
	Sources/ScreenFlash.swift \
	Sources/SettingsStore.swift \
	Sources/Updater.swift \
	Sources/ImpactController.swift \
	Sources/Views/Theme.swift \
	Sources/Views/MenuBarIcon.swift \
	Sources/Views/SliderRow.swift \
	Sources/Views/RangeSlider.swift \
	Sources/Views/MenuBarView.swift \
	Sources/YameteApp.swift

FRAMEWORKS := SwiftUI AppKit AVFoundation CoreAudio ServiceManagement
SWIFTFLAGS := -O -module-name $(APP) -target arm64-apple-macosx14.0 -parse-as-library \
              $(addprefix -framework ,$(FRAMEWORKS))

FACES     := $(wildcard Resources/face_*.svg)
SOUNDS    := $(wildcard Resources/sound_*.mp3)
ICONS     := Assets/menubar_icon.png Assets/AppIcon.icns
ENTITLE   := Yamete.entitlements

.PHONY: all build test install uninstall clean dmg lint verify

all: build

# ── Stage 1: Compile ──────────────────────────────────────────
build: $(BINARY)

$(BINARY): $(SOURCES) $(FACES) $(SOUNDS) $(ICONS) $(ENTITLE) Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS $(RES_DIR)
	@printf "  compile   $(APP)\n"
	@swiftc $(SWIFTFLAGS) $(SOURCES) -o $(BINARY)
	@# ── Stage 2: Optimize assets ──
	@printf "  assets    $(words $(FACES)) faces, $(words $(SOUNDS)) sounds\n"
	@cp $(FACES) $(RES_DIR)/
	@cp $(SOUNDS) $(RES_DIR)/
	@cp $(ICONS) $(RES_DIR)/
	@# SVG minification (if svgo available)
	@which svgo > /dev/null 2>&1 && { \
		printf "  minify    SVGs\n"; \
		for f in $(RES_DIR)/face_*.svg; do svgo -q "$$f" -o "$$f"; done; \
	} || true
	@# ── Stage 3: Bundle ──
	@cp Info.plist $(BUNDLE)/Contents/
	@# ── Stage 4: Sign ──
	@printf "  sign      ad-hoc + entitlements\n"
	@codesign --sign - --force --deep --entitlements $(ENTITLE) $(BUNDLE) 2>/dev/null
	@# ── Stage 5: Verify ──
	@codesign --verify --deep --strict $(BUNDLE) 2>/dev/null
	@printf "  bundle    $(BUNDLE)\n"

# ── Lint (strict concurrency) ─────────────────────────────────
lint:
	@printf "  lint      strict concurrency\n"
	@swiftc -typecheck $(SWIFTFLAGS) -strict-concurrency=complete -warnings-as-errors $(SOURCES)

# ── Test ──────────────────────────────────────────────────────
test:
	@swift test

# ── Install ───────────────────────────────────────────────────
install: build
	@printf "  stop      $(APP)\n"
	@pkill -x $(APP) 2>/dev/null || true
	@printf "  install   /Applications/$(APP).app\n"
	@rm -rf /Applications/$(APP).app
	@cp -R $(BUNDLE) /Applications/
	@open /Applications/$(APP).app
	@printf "  launch    $(APP)\n"

uninstall:
	@pkill -x $(APP) 2>/dev/null || true
	@rm -rf /Applications/$(APP).app
	@printf "  remove    /Applications/$(APP).app\n"

# ── DMG ───────────────────────────────────────────────────────
DMG     := $(DIST)/$(APP).dmg
DMG_TMP := $(DIST)/.dmg_staging

dmg: build
	@printf "  stage     DMG\n"
	@rm -rf "$(DMG_TMP)" "$(DMG)"
	@mkdir -p "$(DMG_TMP)"
	@cp -R "$(BUNDLE)" "$(DMG_TMP)/"
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

# ── Verify (standalone) ───────────────────────────────────────
verify:
	@printf "  verify    bundle structure\n"
	@test -f $(BINARY) || (echo "ERROR: no binary" && exit 1)
	@test -f $(BUNDLE)/Contents/Info.plist || (echo "ERROR: no Info.plist" && exit 1)
	@test $$(ls $(RES_DIR)/face_*.svg 2>/dev/null | wc -l) -ge 5 || (echo "ERROR: missing faces" && exit 1)
	@test $$(ls $(RES_DIR)/sound_*.mp3 2>/dev/null | wc -l) -ge 5 || (echo "ERROR: missing sounds" && exit 1)
	@codesign --verify --deep --strict $(BUNDLE) || (echo "ERROR: signature invalid" && exit 1)
	@printf "  verify    ✓ binary, plist, %s faces, %s sounds, signature\n" \
		$$(ls $(RES_DIR)/face_*.svg | wc -l | tr -d ' ') \
		$$(ls $(RES_DIR)/sound_*.mp3 | wc -l | tr -d ' ')

clean:
	@rm -rf $(DIST)
	@printf "  clean\n"
