#!/usr/bin/env bash
# 1) A branch with only extension packages (no PHP program) is reported as not
#    runnable and does not block "all patched".
# 2) apt-get update failing in a post-update hook does not abort the run.
# Usage: bash test/runtime-and-update-check.sh   (needs bash 4+, e.g. inside ubuntu:22.04)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/root"
mkdir -p "$root/usr/bin" "$root/usr/sbin" "$tmp/bin"

cat > "$root/usr/bin/php8.2" <<'EOF'
#!/usr/bin/env bash
echo "PHP 8.2.35 (cli) (built: Oct 21 2026 14:29:22) (NTS)"
EOF
chmod +x "$root/usr/bin/php8.2"

cat > "$tmp/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ii  php8.2-cli' 'ii  php8.3-common' 'ii  php8.3-intl'
EOF
cat > "$tmp/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_LOCK:-}" == 1 ]]; then
  echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1 (apt-get)"
  exit 100
fi
echo "E: Problem executing scripts APT::Update::Post-Invoke-Success"
exit 100
EOF
chmod +x "$tmp/bin/dpkg-query" "$tmp/bin/apt-get"

{
  echo 'set -Eeuo pipefail'
  echo 'LOG_FILE=/dev/null; APT_UPDATE_OPTS=()'
  echo 'log() { echo "$*"; }'
  echo 'die() { echo "DIE: $*"; exit 1; }'
  sed -n '/^ere_escape()/p' php-safe-maintenance.sh
  sed -n '/^php_cli_version()/,/^self_check_cve()/p' php-safe-maintenance.sh | sed '$d'
  sed -n '/^installed_package_names()/,/^}/p;/^list_installed_branches()/,/^}/p;/^apt_update()/,/^}/p' php-safe-maintenance.sh
  echo 'print_cve_report'
  echo 'all_branches_patched && echo ALL_PATCHED'
  echo 'apt_update && echo UPDATE_CONTINUED'
} | sed -E "s#\"/usr/(bin|sbin|lib)/#\"$root/usr/\1/#g" > "$tmp/run.sh"

out="$(PATH="$tmp/bin:$PATH" bash "$tmp/run.sh")"
[[ "$out" == *"PHP 8.2  PATCHED"* ]] || { echo "8.2 not reported patched: $out"; exit 1; }
[[ "$out" == *"PHP 8.3  NOT RUNNABLE"* ]] || { echo "8.3 not reported as not runnable: $out"; exit 1; }
[[ "$out" == *ALL_PATCHED* ]] || { echo "extension-only 8.3 blocked all-patched: $out"; exit 1; }
[[ "$out" == *UPDATE_CONTINUED* ]] || { echo "apt-get update hook error aborted: $out"; exit 1; }

out="$(PATH="$tmp/bin:$PATH" FAKE_LOCK=1 bash "$tmp/run.sh" || true)"
[[ "$out" == *"package lock"* && "$out" != *UPDATE_CONTINUED* ]] || { echo "apt lock did not stop the run: $out"; exit 1; }

echo "runtime and update check ok"
