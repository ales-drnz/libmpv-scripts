# Sourced by the linux-runtime job in a debian:11 container. Updates the
# package lists, falling back to archive.debian.org once Debian 11 has
# moved there and its usual mirrors stop answering.
if ! apt-get update; then
  sed -i -e 's|http://deb.debian.org|http://archive.debian.org|' \
    -e 's|http://security.debian.org|http://archive.debian.org|' \
    -e '/bullseye-updates/d' /etc/apt/sources.list
  apt-get -o Acquire::Check-Valid-Until=false update
fi
