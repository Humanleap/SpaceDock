APP_NAME := SpaceDock
BUNDLE_ID := com.humanleap.spacedock
BUILD := build
APP := $(BUILD)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
AGENT := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
# Ad-hoc signature unless SIGN_ID is a Developer ID or Apple Development identity.
SIGN_ID ?= -

.PHONY: app test install uninstall clean

app:
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp Info.plist "$(APP)/Contents/Info.plist"
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
