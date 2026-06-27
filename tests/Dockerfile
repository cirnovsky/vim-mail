# Run the vim-mail test suite under Linux, to validate the cross-platform paths:
# the Vim plugin, the Python backend, and the xclip clipboard code that is
# otherwise only exercised on macOS.
#
# Deps only — the repo is bind-mounted at run time (see `make test-linux`), so
# editing files needs no image rebuild.
FROM debian:stable-slim

# vim-nox = the "huge" headless Vim build (+job +timers +lambda +conceal).
# xvfb + xclip give the clipboard test a virtual X display to talk to.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        vim-nox python3 make xvfb xauth xclip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /repo

# xvfb-run provides DISPLAY so xclip works and the clipboard test actually runs
# (it self-skips when no display/clipboard tool is present) instead of skipping.
CMD ["xvfb-run", "-a", "make", "test"]
