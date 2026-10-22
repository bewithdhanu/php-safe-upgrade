#!/usr/bin/env bash
# apt-get exits 100 because of an unrelated package (shim-signed on EC2).
# The upgrade must continue when the PHP packages are "ii", and stop otherwise.
# Usage: bash test/apt-error-check.sh   (needs bash 4+, e.g. inside ubuntu:22.04)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "dpkg: error processing package shim-signed (--configure):"
echo "E: Sub-process /usr/bin/dpkg returned an error code (1)"
exit 100
EOF
cat > "$tmp/dpkg-query" <<'EOF'
#!/usr/bin/env bash
pkg="${@: -1}"
if [[ " ${FAKE_BROKEN:-} " == *" $pkg "* ]]; then printf 'iF '; else printf 'ii '; fi
EOF
chmod +x "$tmp/apt-get" "$tmp/dpkg-query"

{
  echo 'set -Eeuo pipefail'
  echo 'LOG_FILE=/dev/null'
  echo 'APT_OPTS=(-y)'
  echo 'log() { echo "$*"; }'
  echo 'die() { echo "DIE: $*"; exit 1; }'
  sed -n '/^apt_install_php()/,/^}/p' php-safe-maintenance.sh
  echo 'apt_install_php --only-upgrade php8.2-cli php8.2-fpm && echo PASS'
} > "$tmp/run.sh"

out="$(PATH="$tmp:$PATH" bash "$tmp/run.sh")"
[[ "$out" == *PASS* ]] || { echo "unrelated apt error stopped the upgrade: $out"; exit 1; }

out="$(PATH="$tmp:$PATH" FAKE_BROKEN=php8.2-fpm bash "$tmp/run.sh" || true)"
[[ "$out" == *"not fully installed: php8.2-fpm(iF )"* && "$out" != *PASS* ]] \
  || { echo "broken PHP package was accepted: $out"; exit 1; }

echo "apt error check ok"
