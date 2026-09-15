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
# The version a release cut from this tree would carry. Computed at recipe
# time, not here, so it sees the tags a `git fetch` in the recipe just pulled.
NEXT_VERSION := ./scripts/next-version.sh

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

# Stamps the version this tree would be published as — one minor above the
# newest release — so an installed local build is never behind what the updater
# is watching for, and so it cannot replace itself with the work it was built
# from. Tags are fetched first because that number is read from them.
build: generate
	@git fetch --tags --quiet 2>/dev/null || true
	xcodebuild \
	  -project $(XCODEPROJ) \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD_DIR) \
	  MARKETING_VERSION="$$($(NEXT_VERSION))" \
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
	V=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(DIST_APP)/Contents/Info.plist") ; \
	  cd $(DIST_DIR) && rm -f $(PROJECT)-$$V.zip && zip -qry $(PROJECT)-$$V.zip $(APP_NAME) && \
	  echo "Packaged: $(APP_NAME) and $(PROJECT)-$$V.zip"

stop:
	@pkill -x $(PROJECT) 2>/dev/null || true

install: build stop
	rm -rf "$(INSTALL_APP)"
	cp -R "$(BUILT_APP)" "$(INSTALL_APP)"
	@# xattr has no recursive flag; -dr exits 64 and removes nothing.
	@find "$(INSTALL_APP)" -print0 | xargs -0 xattr -d com.apple.quarantine 2>/dev/null || true
	open "$(INSTALL_APP)"
	@echo "Installed + launched: $(INSTALL_APP) ($$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(INSTALL_APP)/Contents/Info.plist"))"

reinstall: install

launch:
	open "$(INSTALL_APP)"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
