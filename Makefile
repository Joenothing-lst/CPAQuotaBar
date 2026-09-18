VERSION := 0.4.1
APP_NAME := CPAQuotaBar
SWIFTC ?= $(shell xcrun --find swiftc)
SDK ?= $(shell xcrun --sdk macosx --show-sdk-path)
TARGET := arm64-apple-macosx26.2
MODULE_CACHE := /tmp/cpa-quota-bar-module-cache-26
BUILD_DIR := .build/release
DIST_DIR := dist
APP_DIR := $(DIST_DIR)/CPA Quota Bar.app
ZIP_NAME := $(DIST_DIR)/CPA-Quota-Bar-$(VERSION)-macos-arm64.zip
CORE_SOURCES := $(wildcard Sources/CPAQuotaCore/*.swift)
APP_SOURCES := $(wildcard Sources/CPAQuotaBar/*.swift)

.PHONY: test build app dist clean

test:
	mkdir -p "$(BUILD_DIR)" "$(MODULE_CACHE)"
	"$(SWIFTC)" -target "$(TARGET)" -sdk "$(SDK)" -module-cache-path "$(MODULE_CACHE)" -O -parse-as-library -module-name CPAQuotaCoreSmoke $(CORE_SOURCES) Tests/Smoke/SmokeMain.swift -o "$(BUILD_DIR)/CoreSmokeTests"
	"$(BUILD_DIR)/CoreSmokeTests"

build:
	mkdir -p "$(BUILD_DIR)" "$(MODULE_CACHE)"
	"$(SWIFTC)" -target "$(TARGET)" -sdk "$(SDK)" -module-cache-path "$(MODULE_CACHE)" -O -parse-as-library -module-name CPAQuotaBar $(CORE_SOURCES) $(APP_SOURCES) -framework SwiftUI -framework AppKit -o "$(BUILD_DIR)/$(APP_NAME)"

app: build
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	install -m 755 "$(BUILD_DIR)/$(APP_NAME)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Packaging/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp -r Resources/* "$(APP_DIR)/Contents/Resources/"
	codesign --force --deep --sign - "$(APP_DIR)"

dist: app
	cd "$(DIST_DIR)" && zip -r -X "CPA-Quota-Bar-$(VERSION)-macos-arm64.zip" "CPA Quota Bar.app"

clean:
	swift package clean
	rm -rf "$(DIST_DIR)"
