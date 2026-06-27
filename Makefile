.PHONY: test test-linux

# Run the full test suite (Python reply tests + headless Vim tests).
test:
	@sh tests/run.sh

# Same suite inside a Linux container — validates the cross-platform paths
# (the Vim plugin, the Python backend, and the xclip clipboard code). Needs
# Docker; the repo is bind-mounted, so no rebuild between runs.
IMAGE ?= vim-mail-test
test-linux:
	docker build -t $(IMAGE) -f tests/Dockerfile .
	docker run --rm -v "$(CURDIR)":/repo $(IMAGE)
