PROJECT      := DevMail.xcodeproj
SCHEME       := DevMail
DERIVED_DATA := build/DerivedData
APP          := $(DERIVED_DATA)/Build/Products/Debug/Dev Mail.app
SWIFT_FORMAT := xcrun swift-format
SWIFT_PATHS  := DevMail DevMailTests Packages scripts

XCODEBUILD := xcodebuild \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-destination 'platform=macOS' \
	-derivedDataPath $(DERIVED_DATA) \
	COMPILER_INDEX_STORE_ENABLE=NO \
	$(XCODEBUILD_FLAGS)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

.PHONY: setup
setup: ## Install development dependencies from the Brewfile
	brew bundle install

$(PROJECT): project.yml
	xcodegen generate

.PHONY: generate
generate: ## Regenerate the Xcode project from project.yml
	xcodegen generate

.PHONY: open
open: $(PROJECT) ## Open the project in Xcode
	open $(PROJECT)

.PHONY: build
build: $(PROJECT) ## Build the app (Debug)
	$(XCODEBUILD) build

.PHONY: test
test: $(PROJECT) ## Run app and package tests
	$(XCODEBUILD) test

.PHONY: run
run: build ## Build and launch the app
	open "$(APP)"

.PHONY: icon
icon: ## Regenerate the placeholder app icon PNGs
	swift scripts/generate-app-icon.swift

.PHONY: lint
lint: ## Check formatting and lint rules
	$(SWIFT_FORMAT) lint --strict --recursive --parallel $(SWIFT_PATHS)
	swiftlint lint --strict --quiet
	actionlint
	zizmor --offline .github

.PHONY: format
format: ## Auto-format Swift sources and apply safe lint fixes
	$(SWIFT_FORMAT) format --in-place --recursive --parallel $(SWIFT_PATHS)
	swiftlint lint --fix --quiet

.PHONY: clean
clean: ## Remove build output and the generated project
	rm -rf build $(PROJECT)
