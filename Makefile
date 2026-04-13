# =============================================================================
# WhisperUtil - Makefile
# macOS menu bar speech-to-text tool
# =============================================================================

SCHEME          := WhisperUtil
PROJECT         := WhisperUtil.xcodeproj
DEVELOPER_DIR   := /Applications/Xcode.app/Contents/Developer
DERIVED_DATA    := $(HOME)/Library/Developer/Xcode/DerivedData
APP_NAME        := WhisperUtil.app
LOCAL_BUILD_DIR := $(CURDIR)/.local-build

# Resolve the actual app path from DerivedData (glob handles the hash suffix)
DEBUG_APP       = $(shell ls -d $(DERIVED_DATA)/WhisperUtil-*/Build/Products/Debug/$(APP_NAME) 2>/dev/null | head -1)
RELEASE_APP     = $(shell ls -d $(DERIVED_DATA)/WhisperUtil-*/Build/Products/Release/$(APP_NAME) 2>/dev/null | head -1)

# xcodebuild with DEVELOPER_DIR preset
XCODEBUILD      = DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project $(PROJECT) -scheme $(SCHEME)

.PHONY: build release local run dev clean check help

# ---------------------------------------------------------------------------
# Build Debug (default target)
# ---------------------------------------------------------------------------
build:
	$(XCODEBUILD) -configuration Debug build

# ---------------------------------------------------------------------------
# Development workflow: build + restart app
# ---------------------------------------------------------------------------
dev: build run

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1     || { echo "Error: git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "Error: Xcode command-line tools not installed"; exit 1; }
	@command -v swift >/dev/null 2>&1    || { echo "Error: swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

# ---------------------------------------------------------------------------
# Build Release
# ---------------------------------------------------------------------------
release:
	$(XCODEBUILD) -configuration Release build

# ---------------------------------------------------------------------------
# Build for local use — no Apple ID login required in Xcode
# ---------------------------------------------------------------------------
local: check
	@echo "Building WhisperUtil (ad-hoc signing, no Apple ID required)..."
	@rm -rf "$(LOCAL_BUILD_DIR)"
	$(XCODEBUILD) -configuration Debug \
		-derivedDataPath "$(LOCAL_BUILD_DIR)" \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		build
	@APP_PATH="$(LOCAL_BUILD_DIR)/Build/Products/Debug/$(APP_NAME)" && \
	if [ -d "$$APP_PATH" ]; then \
		echo ""; \
		echo "Build complete!"; \
		echo "App location: $$APP_PATH"; \
		echo "Run with:     open \"$$APP_PATH\""; \
	else \
		echo "Error: $(APP_NAME) not found at $$APP_PATH"; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# Run: quit old process, launch new build
# ---------------------------------------------------------------------------
run:
	@osascript -e 'tell application "WhisperUtil" to quit' 2>/dev/null; sleep 1
	@if [ -d "$(DEBUG_APP)" ]; then \
		open "$(DEBUG_APP)"; \
	elif [ -d "$(RELEASE_APP)" ]; then \
		open "$(RELEASE_APP)"; \
	else \
		echo "Error: $(APP_NAME) not found. Run 'make build' first."; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# Clean build artifacts
# ---------------------------------------------------------------------------
clean:
	$(XCODEBUILD) clean

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
help:
	@echo "WhisperUtil Makefile"
	@echo ""
	@echo "Usage:  make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build          Build Debug version (default)"
	@echo "  release        Build Release version"
	@echo "  local          Build without Apple ID (ad-hoc signing)"
	@echo "  run            Quit running app and launch latest build"
	@echo "  dev            Build Debug + restart app (daily workflow)"
	@echo "  clean          Clean Xcode build artifacts"
	@echo "  check          Verify prerequisites (git, xcodebuild, swift)"
	@echo "  help           Show this help message"
