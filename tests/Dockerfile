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

# Default: run headless — robust everywhere incl. CI (xvfb-run can hang on hosted
# runners). The clipboard test self-skips without a display. To exercise the Linux
# clipboard path, run with a display via `make test-linux-clip` (wraps xvfb-run).
CMD ["make", "test"]
