# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
#
# Sourced by the linux-runtime job in a debian:11 container. Updates the
# package lists and defines apt_install, both falling back to
# archive.debian.org, where Debian 11 moves once its support ends. The
# move is gradual: for a while the usual mirrors still serve the lists
# but no longer the packages, so a failed install falls back too.
debian11_use_archive() {
  sed -i -e 's|http://deb.debian.org|http://archive.debian.org|' \
    -e 's|http://security.debian.org|http://archive.debian.org|' \
    -e '/bullseye-updates/d' /etc/apt/sources.list
  apt-get -o Acquire::Check-Valid-Until=false update
}

apt_install() {
  apt-get install -y --no-install-recommends "$@" ||
    { debian11_use_archive && apt-get install -y --no-install-recommends "$@"; }
}

if ! apt-get update; then
  debian11_use_archive
fi
