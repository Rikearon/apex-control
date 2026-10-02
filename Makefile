# Convenience wrappers around the commands in CONTRIBUTING.md. `make check test` is the
# minimum before a pull request; CI also runs ShellCheck and actionlint (`make lint`, if
# you have them), a security audit of the workflows (zizmor), a release build, a packaging
# dry run, and several Xcode versions, one of them on Intel.
.DEFAULT_GOAL := help
.PHONY: help build test test-tools build-release app package check lint version clean

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-14s %s\n", $$1, $$2}'

build: ## Debug build of every product
	swift build

test: ## Run the unit tests (no keyboard needed)
	swift test

test-tools: ## Test the repository checks themselves (Scripts/check-repo.py)
	python3 -m unittest discover -s Scripts -p 'test_*.py'

build-release: ## Optimised build of every product (this is not the release workflow: see `package`)
	swift build -c release

app: ## Assemble "build/Apex Control.app"
	./Scripts/build-app.sh release

package: ## Build the release artefacts in dist/ (universal DMG, apexctl zip, SHA256SUMS)
	./Scripts/package-release.sh

check: ## Repository checks: whitespace, doc links, PRD cross-references, workflows, scripts, secrets
	./Scripts/check-repo.py

lint: ## ShellCheck the scripts and actionlint the workflows, as CI does (needs shellcheck and actionlint)
	@if command -v shellcheck >/dev/null; then shellcheck Scripts/*.sh && echo "✓ shellcheck"; else echo "note: shellcheck is not installed (brew install shellcheck); CI runs it"; fi
	@if command -v actionlint >/dev/null; then actionlint && echo "✓ actionlint"; else echo "note: actionlint is not installed (brew install actionlint); CI runs it"; fi

version: ## Print the project version
	@./Scripts/version.sh

clean: ## Remove build products
	rm -rf .build build dist
