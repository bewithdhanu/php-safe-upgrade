#!/usr/bin/env bash
# Removed ("rc") and purged packages must not be picked for an upgrade,
# otherwise the post-install check rejects them as not fully installed.
# Usage: bash test/installed-filter-check.sh   (needs bash 4+, e.g. inside ubuntu:22.04)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'ii  php8.2-cli' \
  'rc  php8.2-fpm' \
  'iF  php8.2-gd' \
  'un  php8.2-calendar' \
  'rc  php7.4-common' \
  'ii  php8.3-fpm' \
  'ii  libapache2-mod-php8.2'
EOF
chmod +x "$tmp/dpkg-query"

{
  echo 'set -Eeuo pipefail'
  sed -n '/^ere_escape()/p' php-safe-maintenance.sh
  sed -n '/^installed_package_names()/,/^}/p;/^installed_php_packages_for_branch()/,/^}/p;/^list_installed_branches()/,/^}/p' php-safe-maintenance.sh
  echo 'echo "pkgs=$(installed_php_packages_for_branch 8.2 | tr "\n" " ")"'
  echo 'echo "branches=$(list_installed_branches | tr "\n" " ")"'
} > "$tmp/run.sh"

out="$(PATH="$tmp:$PATH" bash "$tmp/run.sh")"
[[ "$out" == *"pkgs=libapache2-mod-php8.2 php8.2-cli php8.2-gd "* ]] || { echo "wrong 8.2 packages: $out"; exit 1; }
[[ "$out" == *"branches=8.2 8.3 "* ]] || { echo "wrong branches: $out"; exit 1; }

echo "installed filter check ok"
