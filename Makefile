.PHONY: test test-unit test-ui clean help

# Default simulator
SIMULATOR ?= iPhone 17
SCHEME = OneEighty
DESTINATION = 'platform=iOS Simulator,name=$(SIMULATOR)'

help:
	@echo "OneEighty - Make Commands"
	@echo ""
	@echo "Available commands:"
	@echo "  make test        - Run both unit and UI tests"
	@echo "  make test-unit   - Run unit tests only"
	@echo "  make test-ui     - Run UI tests only"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make help        - Show this help message"
	@echo ""
	@echo "Options:"
	@echo "  SIMULATOR=<name> - Specify simulator (default: iPhone 17)"
	@echo ""
	@echo "Example:"
	@echo "  make test SIMULATOR='iPhone 17 Pro'"

test: test-unit test-ui

test-unit:
	@echo "Running unit tests on $(SIMULATOR)..."
	@xcodebuild test \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		-only-testing:OneEightyTests \
		-parallel-testing-enabled NO

test-ui:
	@echo "Running UI tests on $(SIMULATOR)..."
	@xcodebuild test \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		-only-testing:OneEightyUITests \
		-parallel-testing-enabled NO

clean:
	@echo "Cleaning build artifacts..."
	@xcodebuild clean -scheme $(SCHEME) || true
	@rm -rf ~/Library/Developer/Xcode/DerivedData/OneEighty-* || true
	@echo "Clean complete!"
	@echo ""
	@echo "Note: Run 'xcrun simctl erase all' to reset all simulators if tests fail"
