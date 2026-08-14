#!/usr/bin/env bash
set -eo pipefail

# Use the Guix revision that built the active system generation.
export GUIX_PROFILE=/run/current-system/profile
# shellcheck disable=SC1091
. "$GUIX_PROFILE/etc/profile"
hash guix

test -r /etc/config/system.scm
test -r /etc/config/vpsadminos.scm
test -r /run/current-system/channels.scm
guix time-machine -C /run/current-system/channels.scm -- \
  system reconfigure -L /etc/config /etc/config/system.scm
