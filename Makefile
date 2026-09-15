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
# Info.plist now carries $(MARKETING_VERSION) rather than a literal, so the
# version lives in project.yml and nowhere else.
VERSION      := $(shell sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)

.PHONY: all generate build sign package install reinstall launch stop clean help tag

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
	@echo "  make tag V=0.2.0 Bump project.yml, commit, tag and push; CI publishes the release"
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
	@# xattr has no recursive flag; -dr exits 64 and removes nothing.
	@find "$(INSTALL_APP)" -print0 | xargs -0 xattr -d com.apple.quarantine 2>/dev/null || true
	open "$(INSTALL_APP)"
	@echo "Installed + launched: $(INSTALL_APP)"

reinstall: install

launch:
	open "$(INSTALL_APP)"

# Cuts a release. The build itself happens in CI on the pushed tag; this just
# makes sure the version in project.yml and the tag agree, which is what the
# release workflow checks and what the updater compares against.
tag:
	@test -n "$(V)" || { echo "usage: make tag V=0.2.0"; exit 1; }
	@# Tracked changes only: CI builds the tag, so an untracked scratch file in
	@# the working tree cannot reach the release and has no business blocking it.
	@test -z "$$(git status --porcelain --untracked-files=no)" || { echo "tracked files have uncommitted changes"; exit 1; }
	sed -i '' 's/^\( *MARKETING_VERSION: *\).*/\1"$(V)"/' project.yml
	git add project.yml
	git commit -m "Release $(V)"
	git tag -a v$(V) -m "v$(V)"
	git push origin HEAD --follow-tags
	@echo "Pushed v$(V) — watch: gh run watch"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
