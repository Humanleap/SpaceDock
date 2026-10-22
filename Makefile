APP_NAME := SpaceDock
BUNDLE_ID := com.humanleap.spacedock
BUILD := build
APP := $(BUILD)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
AGENT := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
# A stable signature keeps the Accessibility permission across updates.
# Ad-hoc signing makes macOS forget it.
FOUND_SIGN := $(shell security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' | head -1)
ifeq ($(strip $(FOUND_SIGN)),)
FOUND_SIGN := $(shell security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' | head -1)
endif
SIGN_ID ?= $(if $(strip $(FOUND_SIGN)),$(FOUND_SIGN),-)

.PHONY: app test install uninstall clean update

app:
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(BUILD)/AppIcon.iconset"
	cp Info.plist "$(APP)/Contents/Info.plist"
	sips -z 16 16 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_16x16.png" >/dev/null
	sips -z 32 32 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
	sips -z 32 32 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_32x32.png" >/dev/null
	sips -z 64 64 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
	sips -z 128 128 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_128x128.png" >/dev/null
	sips -z 256 256 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
	sips -z 256 256 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_256x256.png" >/dev/null
	sips -z 512 512 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
	sips -z 512 512 Resources/AppIcon.png --out "$(BUILD)/AppIcon.iconset/icon_512x512.png" >/dev/null
	cp Resources/AppIcon.png "$(BUILD)/AppIcon.iconset/icon_512x512@2x.png"
	iconutil -c icns "$(BUILD)/AppIcon.iconset" -o "$(APP)/Contents/Resources/AppIcon.icns"
	swiftc -O -parse-as-library -o "$(APP)/Contents/MacOS/$(APP_NAME)" main.swift
	codesign --force --sign "$(SIGN_ID)" "$(APP)"

test:
	mkdir -p "$(BUILD)"
	swiftc -parse-as-library -D SPACE_DOCK_TEST -o "$(BUILD)/switch-test" main.swift
	"$(BUILD)/switch-test"

install: app
	-launchctl bootout "gui/$$(id -u)/$(BUNDLE_ID)"
	mkdir -p "$(INSTALL_DIR)" "$(HOME)/Library/LaunchAgents" "$(HOME)/Library/Logs"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	codesign --force --sign "$(SIGN_ID)" "$(INSTALL_DIR)/$(APP_NAME).app"
	sed -e 's|@HOME@|$(HOME)|g' -e 's|@ID@|$(BUNDLE_ID)|g' launchd.plist > "$(AGENT)"
	launchctl bootstrap "gui/$$(id -u)" "$(AGENT)"

uninstall:
	-launchctl bootout "gui/$$(id -u)/$(BUNDLE_ID)"
	rm -f "$(AGENT)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf "$(BUILD)"

update:
	git pull --ff-only
	$(MAKE) install
	$(MAKE) clean
