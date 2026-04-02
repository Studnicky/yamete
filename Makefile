# Yamete — Makefile

APP       := Yamete
BUNDLE_ID := com.yamete
DIST      := dist
BUNDLE    := $(DIST)/$(APP).app
BINARY    := $(BUNDLE)/Contents/MacOS/yamete

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
	Sources/Views/MenuBarIcon.swift \
	Sources/Views/Theme.swift \
	Sources/Views/SliderRow.swift \
	Sources/Views/RangeSlider.swift \
	Sources/Views/MenuBarView.swift \
	Sources/YameteApp.swift

FRAMEWORKS := SwiftUI AppKit AVFoundation CoreAudio ServiceManagement
SWIFTFLAGS := -O -module-name $(APP) -target arm64-apple-macosx14.0 -parse-as-library \
              $(addprefix -framework ,$(FRAMEWORKS))

RESOURCES := $(wildcard Resources/face_*.svg) $(wildcard Resources/sound_*.mp3)
ICONS     := Assets/face_icon.png Assets/AppIcon.icns

.PHONY: all build test install uninstall clean dmg

all: build

test:
	@swift test

build: $(BINARY)

$(BINARY): $(SOURCES) $(RESOURCES) $(ICONS) Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@printf "  compile   $(APP)\n"
	@swiftc $(SWIFTFLAGS) $(SOURCES) -o $(BINARY)
	@cp Info.plist $(BUNDLE)/Contents/
	@cp $(RESOURCES) $(BUNDLE)/Contents/Resources/
	@cp $(ICONS) $(BUNDLE)/Contents/Resources/
	@codesign --sign - --force --deep $(BUNDLE) 2>/dev/null
	@printf "  bundle    $(BUNDLE)\n"

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
	@cp "$(BUNDLE)/Contents/Resources/AppIcon.icns" \
		"$(DIST)/$(APP)_vol/.VolumeIcon.icns" 2>/dev/null || true
	@SetFile -a C "$(DIST)/$(APP)_vol" 2>/dev/null || true
	@osascript scripts/dmg-layout.applescript "$(APP)" 2>/dev/null || true
	@hdiutil detach "$(DIST)/$(APP)_vol" -quiet
	@hdiutil convert "$(DIST)/$(APP)_rw.dmg" -format UDZO -o "$(DMG)" > /dev/null
	@rm -f "$(DIST)/$(APP)_rw.dmg"
	@rm -rf "$(DMG_TMP)"
	@printf "  done      $(DMG)\n"

clean:
	@rm -rf $(DIST)
	@printf "  clean\n"
