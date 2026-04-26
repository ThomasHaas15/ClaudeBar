SHELL := /bin/bash

PROJECT      := ClaudeBar
SCHEME       := ClaudeBar
CONFIG       := Release
XCODEPROJ    := $(PROJECT).xcodeproj
ENTITLEMENTS := ClaudeBar/ClaudeBar.entitlements
BUILD_DIR    := build
DIST_DIR     := dist
APP_NAME     := $(PROJECT).app
BUILT_APP    := $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)
DIST_APP     := $(DIST_DIR)/$(APP_NAME)
INSTALL_DIR  := /Applications
INSTALL_APP  := $(INSTALL_DIR)/$(APP_NAME)
VERSION      := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ClaudeBar/Info.plist 2>/dev/null || echo 0.0.0)

.PHONY: all generate build sign package install reinstall launch stop clean help

all: install

help:
	@echo "Targets:"
	@echo "  make generate    Regenerate Xcode project from project.yml"
	@echo "  make build       Release build (ad-hoc signed)"
	@echo "  make package     Stage .app + zip into dist/"
	@echo "  make install     Build, stop running copy, overwrite /Applications/$(APP_NAME), launch"
	@echo "  make reinstall   Alias for install"
	@echo "  make launch      open $(INSTALL_APP)"
	@echo "  make stop        Quit any running copies"
	@echo "  make clean       Remove build/ and dist/"

generate:
	xcodegen generate

build: generate
	xcodebuild \
	  -project $(XCODEPROJ) \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD_DIR) \
	  CODE_SIGN_IDENTITY="-" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO \
	  build
	codesign --force --deep --sign - \
	  --entitlements $(ENTITLEMENTS) \
	  "$(BUILT_APP)"

package: build
	@mkdir -p $(DIST_DIR)
	rm -rf "$(DIST_APP)"
	cp -R "$(BUILT_APP)" "$(DIST_APP)"
	cd $(DIST_DIR) && rm -f $(PROJECT)-$(VERSION).zip && zip -qry $(PROJECT)-$(VERSION).zip $(APP_NAME)
	@echo "Packaged: $(DIST_APP) and $(DIST_DIR)/$(PROJECT)-$(VERSION).zip"

stop:
	@pkill -x $(PROJECT) 2>/dev/null || true

install: build stop
	rm -rf "$(INSTALL_APP)"
	cp -R "$(BUILT_APP)" "$(INSTALL_APP)"
	-xattr -dr com.apple.quarantine "$(INSTALL_APP)" 2>/dev/null
	open "$(INSTALL_APP)"
	@echo "Installed + launched: $(INSTALL_APP)"

reinstall: install

launch:
	open "$(INSTALL_APP)"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
