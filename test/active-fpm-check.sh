#!/usr/bin/env bash
# With php8.0-fpm.conf and php8.2-fpm.conf both enabled, Apache serves 8.2
# (loaded last), so that is the branch the script must report as active.
# Usage: bash test/active-fpm-check.sh   (needs bash 4+, e.g. inside ubuntu:22.04)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/conf-enabled"

{
  echo 'set -Eeuo pipefail'
  sed -n '/^enabled_apache_fpm_branches()/,/^}/p;/^active_apache_fpm_branch()/,/^}/p' php-safe-maintenance.sh \
    | sed "s#/etc/apache2/conf-enabled#$tmp/conf-enabled#"
  echo 'echo "active=$(active_apache_fpm_branch)"'
} > "$tmp/run.sh"

touch "$tmp/conf-enabled/php8.0-fpm.conf" "$tmp/conf-enabled/php8.2-fpm.conf"
out="$(bash "$tmp/run.sh")"
[[ "$out" == "active=8.2" ]] || { echo "both enabled: $out"; exit 1; }

rm "$tmp/conf-enabled/php8.2-fpm.conf"
out="$(bash "$tmp/run.sh")"
[[ "$out" == "active=8.0" ]] || { echo "only 8.0 enabled: $out"; exit 1; }

echo "active fpm check ok"
