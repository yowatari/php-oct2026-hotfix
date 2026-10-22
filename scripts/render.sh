#!/usr/bin/env bash
# Usage: scripts/render.sh <php-version>   e.g. scripts/render.sh 8.5.12
#
# Looks up the tarball sha256 on php.net and renders build/<version>/:
#   melange.yaml, apko.yaml (php CLI), apko-fpm.yaml (php-fpm),
#   src/patches/ (copied from patches/<major.minor>/)
# Prints shell-style KEY=VALUE lines (also appended to $GITHUB_OUTPUT in CI).
set -euo pipefail

version="${1:?usage: $0 <php-version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
major="${version%%.*}"
branch="${version%.*}"
out="$root/build/$version"

sha256="$(curl -fsSL "https://www.php.net/releases/index.php?json&version=${major}&max=200" |
  jq -r --arg v "$version" --arg f "php-${version}.tar.xz" \
    '.[$v].source[]? | select(.filename == $f) | .sha256')"
if [ -z "$sha256" ]; then
  echo "php-${version}.tar.xz is not listed on php.net" >&2
  exit 1
fi

rm -rf "$out" && mkdir -p "$out/src/patches"
shopt -s nullglob
patches=("$root/patches/$branch"/*.patch)
for p in "${patches[@]}"; do cp "$p" "$out/src/patches/"; done
# Patched builds become <version>-r1 so they never collide with the pristine tarball build.
epoch=0
[ "${#patches[@]}" -gt 0 ] && epoch=1

# EOL branches predate C23-default GCC and newer libxml2/OpenSSL headers.
cflags_extra=""
case "$branch" in
  7.*|8.0|8.1)
    cflags_extra="-std=gnu17 -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=implicit-int"
    ;;
esac

legacy=0
case "$branch" in 7.*|8.0|8.1) legacy=1 ;; esac

render() {
  sed -e "s/@@VERSION@@/${version}/g" -e "s/@@SHA256@@/${sha256}/g" \
    -e "s/@@BRANCH@@/${branch}/g" -e "s/@@EPOCH@@/${epoch}/g" \
    -e "s/@@CFLAGS_EXTRA@@/${cflags_extra}/g" "$@"
}

render "$root/melange.tmpl.yaml" > "$out/melange.yaml"
# Two images from the same apk set: php CLI, and php-fpm on top of it.
render -e "/^# @@FPM_PACKAGE@@$/d" \
  -e "s|@@ENTRYPOINT@@|/usr/bin/php|" -e "s/@@FLAVOR_SUFFIX@@//" \
  "$root/apko.tmpl.yaml" > "$out/apko.yaml"
render -e "s|^# @@FPM_PACKAGE@@$|    - php-hotfix-fpm=${version}-r${epoch}|" \
  -e "s|@@ENTRYPOINT@@|/usr/bin/php-fpm -F -y /etc/php/php-fpm.conf|" -e "s/@@FLAVOR_SUFFIX@@/-fpm/" \
  "$root/apko.tmpl.yaml" > "$out/apko-fpm.yaml"
if [ "$legacy" = 1 ]; then
  sed -i -e "/^# @@LEGACY_DEPS@@$/r $root/legacy-deps.inc.yaml" -e "/^# @@LEGACY_DEPS@@$/d" "$out/melange.yaml"
else
  sed -i "/^# @@LEGACY_DEPS@@$/d" "$out/melange.yaml"
fi

# Content hashes for CI caching. melange_hash covers everything that feeds
# the apk build; image_hash adds the apko configs on top.
melange_hash="$(cd "$out" && find melange.yaml src -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16)"
image_hash="$(cd "$out" && { echo "$melange_hash"; cat apko.yaml apko-fpm.yaml; } | sha256sum | cut -c1-16)"

{
  echo "version=$version"
  echo "branch=$branch"
  echo "epoch=$epoch"
  echo "sha256=$sha256"
  echo "patches=${#patches[@]}"
  echo "legacy=$legacy"
  echo "dir=build/$version"
  echo "melange_hash=$melange_hash"
  echo "image_hash=$image_hash"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
