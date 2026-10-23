#!/usr/bin/env bash
# apt-get purge exits 100 because of an unrelated package (shim-signed on EC2).
# Removal must count as done when no PHP packages of the branch are left,
# and must stop when one is still installed.
# Usage: bash test/purge-error-check.sh   (needs bash 4+, e.g. inside ubuntu:22.04)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "dpkg: error processing package shim-signed (--configure):"
exit 100
EOF
cat > "$tmp/dpkg-query" <<'EOF'
#!/usr/bin/env bash
echo 'ii  php8.2-cli'
[[ -z "${FAKE_LEFT:-}" ]] || echo "ii  ${FAKE_LEFT}"
EOF
chmod +x "$tmp/apt-get" "$tmp/dpkg-query"

{
  echo 'set -Eeuo pipefail'
  echo 'LOG_FILE=/dev/null; APT_OPTS=(-y); branch=8.0; pkgs=(php8.0-cli)'
  echo 'log() { echo "$*"; }'
  echo 'die() { echo "DIE: $*"; exit 1; }'
  sed -n '/^ere_escape()/p' php-safe-maintenance.sh
  sed -n '/^installed_package_names()/,/^}/p;/^installed_php_packages_for_branch()/,/^}/p' php-safe-maintenance.sh
  echo 'purge_step() {'
  sed -n '/^  if ! apt-get "\${APT_OPTS\[@\]}" purge/,/^  log "All PHP \${branch} packages are removed."/p' php-safe-maintenance.sh
  echo '}'
  echo 'purge_step && echo PASS'
} > "$tmp/run.sh"

out="$(PATH="$tmp:$PATH" bash "$tmp/run.sh")"
[[ "$out" == *PASS* ]] || { echo "unrelated apt error stopped the purge: $out"; exit 1; }

out="$(PATH="$tmp:$PATH" FAKE_LEFT=php8.0-fpm bash "$tmp/run.sh" || true)"
[[ "$out" == *"still installed: php8.0-fpm"* && "$out" != *PASS* ]] \
  || { echo "leftover package was accepted: $out"; exit 1; }

echo "purge error check ok"
