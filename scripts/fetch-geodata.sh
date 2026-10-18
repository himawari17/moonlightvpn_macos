#!/usr/bin/env bash
# Download the geo databases the core reads for GEOSITE and GEOIP rules.
#
# mihomo fetches them itself the first time a config has such a rule, and every
# subscription's does. It needs them to *parse* the config, so that first time
# is before any tunnel exists: where the download is blocked — which is where
# someone needs the tunnel — the core can never start. So they ship in the
# bundle, and the app puts them in the core's home before it runs it.
#
# Not committed, like the core; CI and a fresh clone both run this.
set -euo pipefail
cd "$(dirname "$0")/.."

# There is no version to pin. Upstream keeps one release, tagged `latest` and
# rebuilt every day, so this takes the day's build and records its date.
# GEODATA_URL points it elsewhere: at a mirror, or at one exact build —
#   https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/<commit of the release branch>
BASE="${GEODATA_URL:-https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest}"
DEST=Resources/geodata
mkdir -p "$DEST"

# What mihomo v1.19.31 opens in its home with the default `geodata-mode`, found
# by running it on an empty one: GeoSite.dat for GEOSITE, geoip.metadb for
# GEOIP — each on its own is not enough. GeoIP.dat is read only under
# `geodata-mode: true`, and ASN.mmdb only for IP-ASN rules; neither is shipped.
# ASN.mmdb is MaxMind's GeoLite2 ASN as published, under a licence that has
# copies replaced within 30 days of each update — see the README.
# Check again when the core moves. Named as the core names them, which is not
# how the release does:   name in the home:asset in the release
FILES="GeoSite.dat:geosite.dat geoip.metadb:geoip.metadb"

present=1
for pair in $FILES; do
  [ -s "$DEST/${pair%%:*}" ] || present=0
done
if [ "$present" = 1 ] && [ "${FORCE:-0}" != "1" ]; then
  echo "geodata already present — FORCE=1 to refetch"
  cat "$DEST/VERSION" 2>/dev/null || true
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for pair in $FILES; do
  name="${pair%%:*}"
  asset="${pair##*:}"
  echo "  $name"
  # -R keeps the release's own timestamp on the file: it is the only date the
  # data carries.
  curl -fsSL -R "$BASE/$asset" -o "$tmp/$name"
  # The release publishes a checksum beside each file. A download cut short, or
  # an error page served with a 200, is otherwise a database the core refuses
  # at the first connect — on someone else's machine.
  want=$(curl -fsSL "$BASE/$asset.sha256sum" | awk '{print $1}')
  got=$(shasum -a 256 "$tmp/$name" | awk '{print $1}')
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "  ! $name does not match the checksum published with it" >&2
    exit 1
  fi
done

# Moved in only once both are good, so a failed fetch never leaves one day's
# file beside another's.
for pair in $FILES; do
  mv -f "$tmp/${pair%%:*}" "$DEST/${pair%%:*}"
done

date -u -r "$DEST/GeoSite.dat" +%Y-%m-%d > "$DEST/VERSION"
echo "geodata of $(cat "$DEST/VERSION")"
ls -la "$DEST"
