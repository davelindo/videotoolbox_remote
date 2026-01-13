SHELL := /bin/bash

.PHONY: test lint format

test:
	swift test

format:
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat .; \
	else \
		echo "swiftformat not installed (skipping)"; \
	fi

lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --strict; \
	else \
		echo "swiftlint not installed (skipping)"; \
	fi
