.PHONY: test test-linux test-linux-clip

# Run the full test suite (Python reply tests + headless Vim tests).
test:
	@sh tests/run.sh

# Same suite inside a Linux container — validates the Vim plugin + Python backend
# cross-platform. Headless (no display), so the clipboard test self-skips. Needs
# Docker; the repo is bind-mounted, so no rebuild between runs.
IMAGE ?= vim-mail-test
test-linux:
	docker build -t $(IMAGE) -f tests/Dockerfile .
	docker run --rm -v "$(CURDIR)":/repo $(IMAGE)

# Same, but under a virtual X display (xvfb) so the Linux xclip clipboard path is
# exercised too. Local only, best-effort: xclip's selection daemon can hold the
# container's stdout open past test completion, so the run is timeout-bounded
# (a 124 exit after the suite already printed ALL PASS just means that reap).
test-linux-clip:
	docker build -t $(IMAGE) -f tests/Dockerfile .
	docker run --rm -v "$(CURDIR)":/repo $(IMAGE) sh -c 'timeout -k 5 120 xvfb-run -a make test'
