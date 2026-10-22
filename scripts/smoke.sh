#!/usr/bin/env bash
# Usage: scripts/smoke.sh <cli-image> <fpm-image> <php-version> [platform]
# Checks the CLI image runs the expected PHP without php-fpm, and that the
# fpm image comes up as nonroot and stays up.
set -euo pipefail

cli="$1" fpm="$2" version="$3"
plat=()
[ -n "${4:-}" ] && plat=(--platform "$4")

docker run --rm "${plat[@]}" "$cli" -v | tee /dev/stderr | grep -q "PHP $version "
docker run --rm "${plat[@]}" "$cli" -r 'exit(file_exists("/usr/bin/php-fpm") || posix_getuid() !== 65532 ? 1 : 0);'
docker run --rm "${plat[@]}" --entrypoint /usr/bin/php-fpm "$fpm" -t -y /etc/php/php-fpm.conf

name="smoke-fpm-$$"
docker run -d "${plat[@]}" --name "$name" "$fpm" > /dev/null
trap 'docker rm -f "$name" > /dev/null 2>&1 || true' EXIT
for _ in $(seq 1 20); do
  docker logs "$name" 2>&1 | grep -q "ready to handle connections" && break
  sleep 1
done
docker logs "$name" 2>&1 | grep -q "ready to handle connections"
test "$(docker inspect -f '{{.State.Running}}' "$name")" = true
echo "smoke OK: $cli / $fpm ${4:-}"
