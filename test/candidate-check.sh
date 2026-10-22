#!/usr/bin/env bash
# Runs the CVE candidate gate against a fake apt-cache with a long version table.
# Usage: bash test/candidate-check.sh   (needs bash 4+, e.g. inside ubuntu:22.04)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/apt-cache" <<'EOF'
#!/usr/bin/env bash
printf '%s:\n  Installed: 8.2.14-1+ubuntu22.04.1+deb.sury.org+1\n  Candidate: %s\n  Version table:\n' "$2" "${FAKE_CANDIDATE}"
for i in $(seq 1 20000); do echo "     8.2.$i-1+ubuntu22.04.1+deb.sury.org+1 500"; done
EOF
chmod +x "$tmp/apt-cache"

{
  echo 'set -Eeuo pipefail'
  echo 'log() { :; }'
  echo 'die() { echo "DIE: $*"; exit 1; }'
  sed -n '/^php_cli_version()/,/^print_cve_report()/p' php-safe-maintenance.sh | sed '$d'
  sed -n '/^candidate_version()/,/^}/p;/^has_candidate()/,/^}/p' php-safe-maintenance.sh
  echo 'require_cve_candidate 8.2 && echo PASS'
} > "$tmp/gate.sh"

out="$(PATH="$tmp:$PATH" FAKE_CANDIDATE='8.2.35-1+ubuntu22.04.1+deb.sury.org+1' bash "$tmp/gate.sh")"
[[ "$out" == PASS ]] || { echo "fixed candidate rejected: $out"; exit 1; }

out="$(PATH="$tmp:$PATH" FAKE_CANDIDATE='8.2.34-1+ubuntu22.04.1+deb.sury.org+1' bash "$tmp/gate.sh" || true)"
[[ "$out" == *"below the fixed release 8.2.35"* ]] || { echo "unfixed candidate not rejected: $out"; exit 1; }

echo "candidate check ok"
