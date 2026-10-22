#!/usr/bin/env bash
# Safe Ubuntu/Apache PHP maintenance helper for patching the PHP engine
# without breaking a running site. Checks CVE-2026-109618 and CVE-2026-109619
# (fixed in 8.2.35, 8.3.36, 8.4.27, 8.5.12; no upstream fix before 8.2).
#
# Actions:
#   1 Audit only                       - report PHP/Apache state, change nothing.
#   2 Update the ACTIVE Apache branch  - upgrade only its already-installed pkgs.
#   3 Update ALL installed branches    - patch every branch, incl. idle CLI ones.
#   4 Migrate Apache FPM X.Y -> A.B    - install target, preserve ini/pool, switch.
#   5 Purge an old (inactive) branch   - gated removal after a successful migration.
#
# Run (interactive):   chmod +x php-safe-maintenance.sh && sudo ./php-safe-maintenance.sh
# Run (unattended):    sudo ./php-safe-maintenance.sh --action=4 --from=8.1 --to=8.2 --yes
#
# Everything is backed up first; upgrades/migrations never remove the old branch.
# Removal happens only via action 5, which refuses to touch the active handler,
# scans for references, and confirms before purging.

set -Eeuo pipefail
umask 077

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/php-safe-maintenance.log"
BACKUP_ROOT="/var/backups/php-safe-maintenance"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

# Runtime options (set by argument parsing below).
ASSUME_YES=0
SELF_CHECK=0
OPT_ACTION=""
OPT_FROM=""
OPT_TO=""

# Drive apt non-interactively and keep existing config files (e.g. a customized
# php.ini) rather than prompting or overwriting them. This avoids the dpkg
# conffile prompt that otherwise stalls an unattended run.
export DEBIAN_FRONTEND=noninteractive
# php.ini is managed by ucf, which ignores the dpkg conffile options below.
export UCF_FORCE_CONFFOLD=1
APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
# ondrej/php renamed its PPA label; apt exits 100 until that change is accepted.
APT_UPDATE_OPTS=(-o Acquire::AllowReleaseInfoChange::Label=true)

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Escape a string so it can be used literally inside an ERE.
ere_escape() { printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\\/]/\\&/g'; }

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME} [options]

Options:
  --action=N        1=audit only, 2=update active branch,
                    3=update all installed branches, 4=migrate FPM,
                    5=purge an old branch, 6=exit
  --audit-only      Shorthand for --action=1
  --from=X.Y        Source branch for migration, or branch to purge (action 5)
  --to=X.Y          Target PHP branch for migration
  -y, --yes         Assume "yes" to all prompts (unattended mode)
  --self-check      Check the CVE version table and exit (no root, no changes)
  -h, --help        Show this help

Examples:
  sudo ./${SCRIPT_NAME}                              # interactive menu
  sudo ./${SCRIPT_NAME} --audit-only                 # read-only audit
  sudo ./${SCRIPT_NAME} --action=2 --yes             # upgrade active branch, unattended
  sudo ./${SCRIPT_NAME} --action=3 --yes             # upgrade every installed branch
  sudo ./${SCRIPT_NAME} --action=4 --from=8.1 --to=8.2 --yes   # migrate FPM
  sudo ./${SCRIPT_NAME} --action=5 --from=8.1 --yes            # purge old PHP 8.1
EOF
}

ask_yes_no() {
  local prompt="$1" answer
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log "Auto-yes (--yes): $prompt"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log "No TTY and --yes not set; assuming NO for: $prompt"
    return 1
  fi
  read -r -p "$prompt [y/N]: " answer || true
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# Prompt for a value, honoring non-interactive mode (returns empty if no TTY).
ask_value() {
  local prompt="$1" reply=""
  if [[ -t 0 && "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "$prompt" reply || true
  fi
  printf '%s' "$reply"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)      ASSUME_YES=1 ;;
      --self-check)  SELF_CHECK=1 ;;
      --audit-only)  OPT_ACTION=1 ;;
      --action=*)    OPT_ACTION="${1#*=}" ;;
      --from=*)      OPT_FROM="${1#*=}" ;;
      --to=*)        OPT_TO="${1#*=}" ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done
}

parse_args "$@"

if [[ "$SELF_CHECK" -ne 1 ]]; then
  [[ "${EUID}" -eq 0 ]] || { echo "Run with sudo: sudo ./${SCRIPT_NAME}" >&2; exit 1; }
  for cmd in apt-get apt-cache dpkg-query systemctl flock awk sed; do
    have "$cmd" || { echo "Missing command: $cmd" >&2; exit 1; }
  done

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec 9>/run/lock/php-safe-maintenance.lock
  flock -n 9 || { echo "Another copy of this script is running." >&2; exit 1; }

  trap 'rc=$?; [[ $rc -ne 0 ]] && log "Aborted (exit ${rc}) at line ${LINENO}."; exit $rc' ERR
  log "Started. Backup directory: $BACKUP_DIR"
fi

backup_config() {
  log "Backing up config and package inventory."
  mkdir -p "$BACKUP_DIR/etc"
  [[ ! -d /etc/php ]] || cp -a /etc/php "$BACKUP_DIR/etc/"
  [[ ! -d /etc/apache2 ]] || cp -a /etc/apache2 "$BACKUP_DIR/etc/"
  dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$BACKUP_DIR/installed-packages.tsv"
  systemctl list-unit-files 'php*-fpm.service' > "$BACKUP_DIR/php-fpm-unit-files.txt" 2>&1 || true
  if have apache2ctl; then apache2ctl -S > "$BACKUP_DIR/apache-vhosts.txt" 2>&1 || true; fi
  log "Backup completed."
}

php_cli_version() {
  "$1" -v 2>/dev/null | sed -n '1s/^PHP \([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' | head -n1
}

# First upstream release that fixes CVE-2026-109618 and CVE-2026-109619.
# PHP 8.1 and older have no upstream fix.
cve_fixed_version() {
  case "$1" in
    8.2) printf '%s' 8.2.35 ;;
    8.3) printf '%s' 8.3.36 ;;
    8.4) printf '%s' 8.4.27 ;;
    8.5) printf '%s' 8.5.12 ;;
    *) return 1 ;;
  esac
}

# True when $1 >= $2 (dotted numeric versions).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# patched | affected | no-upstream-fix | unknown
cve_status() {
  local ver="$1" branch fix
  [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || { printf 'unknown'; return 0; }
  branch="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  if fix="$(cve_fixed_version "$branch")"; then
    if version_ge "$ver" "$fix"; then printf 'patched'; else printf 'affected'; fi
  elif version_ge "${branch}.0" "8.6.0"; then
    printf 'unknown'
  else
    printf 'no-upstream-fix'
  fi
}

cve_status_line() {
  local ver="$1" status fix branch
  status="$(cve_status "$ver")"
  branch="${ver%.*}"
  case "$status" in
    patched)
      printf 'PATCHED   %s  (CVE-2026-109618, CVE-2026-109619)\n' "$ver" ;;
    affected)
      fix="$(cve_fixed_version "$branch")"
      printf 'AFFECTED  %s  needs >= %s  (CVE-2026-109618, CVE-2026-109619)\n' "$ver" "$fix" ;;
    no-upstream-fix)
      printf 'AFFECTED  %s  no upstream fix on PHP < 8.2; migrate to 8.2.35+  (CVE-2026-109618, CVE-2026-109619)\n' "$ver" ;;
    *)
      printf 'UNKNOWN   %s  not in the 21 Oct 2026 advisory table\n' "$ver" ;;
  esac
}

branch_runtime_version() {
  local b="$1" bin ver
  for bin in "/usr/bin/php${b}" "/usr/sbin/php-fpm${b}"; do
    [[ -x "$bin" ]] || continue
    ver="$(php_cli_version "$bin" || true)"
    [[ -n "$ver" ]] || continue
    printf '%s' "$ver"
    return 0
  done
  return 1
}

candidate_upstream() {
  candidate_version "$1" | sed -nE 's/^(.*:)?([0-9]+\.[0-9]+\.[0-9]+).*/\2/p'
}

# Prints "upstream<TAB>status" for the best apt candidate of a branch.
candidate_cve_status() {
  local branch="$1" pkg ver
  for pkg in "php${branch}-cli" "php${branch}-fpm" "libapache2-mod-php${branch}"; do
    has_candidate "$pkg" || continue
    ver="$(candidate_upstream "$pkg")"
    [[ -n "$ver" ]] || continue
    printf '%s\t%s\n' "$ver" "$(cve_status "$ver")"
    return 0
  done
  return 1
}

# Refuse to upgrade or migrate onto a build that is still below the fix.
require_cve_candidate() {
  local branch="$1" cand_ver cand_status fix
  if ! IFS=$'\t' read -r cand_ver cand_status < <(candidate_cve_status "$branch"); then
    die "No apt candidate for PHP ${branch}, so CVE-2026-109618 / CVE-2026-109619 cannot be patched. Enable a repo that ships a fixed build (ondrej/php) and retry."
  fi
  case "$cand_status" in
    patched)
      log "Apt candidate for PHP ${branch} is ${cand_ver}, which fixes CVE-2026-109618 / CVE-2026-109619."
      ;;
    no-upstream-fix)
      die "PHP ${branch} has no upstream fix for CVE-2026-109618 / CVE-2026-109619. Migrate to 8.2.35 or newer (action 4)."
      ;;
    affected)
      fix="$(cve_fixed_version "$branch" || true)"
      die "Apt candidate for PHP ${branch} is ${cand_ver}, below the fixed release ${fix} (CVE-2026-109618, CVE-2026-109619)."
      ;;
    *)
      die "PHP ${branch} candidate ${cand_ver} is not in the 21 Oct 2026 advisory table. Refusing to treat it as patched."
      ;;
  esac
}

verify_branch_cve() {
  local branch="$1" ver status
  ver="$(branch_runtime_version "$branch" || true)"
  [[ -n "$ver" ]] || die "Could not read PHP ${branch} version after the change."
  status="$(cve_status "$ver")"
  log "$(cve_status_line "$ver")"
  [[ "$status" == patched ]] || die "PHP ${branch} is ${ver} and is still affected by CVE-2026-109618 / CVE-2026-109619."
}

print_cve_report() {
  local b ver
  echo "CVE-2026-109618 / CVE-2026-109619:"
  echo "  Fixed in 8.2.35, 8.3.36, 8.4.27, 8.5.12. No upstream fix before PHP 8.2."
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if ver="$(branch_runtime_version "$b")"; then
      printf '  PHP %-4s %s\n' "$b" "$(cve_status_line "$ver")"
    else
      printf '  PHP %-4s version unreadable\n' "$b"
    fi
  done < <(list_installed_branches)
}

# 0 when every installed branch reads as patched. 1 when any is still open.
cve_exposure_open() {
  local b ver status open=0 seen=0
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    seen=1
    ver="$(branch_runtime_version "$b" || true)"
    [[ -n "$ver" ]] || { open=1; continue; }
    status="$(cve_status "$ver")"
    [[ "$status" == patched ]] || open=1
  done < <(list_installed_branches)
  [[ "$seen" -eq 1 && "$open" -eq 0 ]]
}

self_check_cve() {
  local fail=0 got
  expect() {
    got="$(cve_status "$1")"
    if [[ "$got" == "$2" ]]; then
      printf 'ok  %s -> %s\n' "$1" "$got"
    else
      printf 'FAIL %s -> %s (want %s)\n' "$1" "$got" "$2"
      fail=1
    fi
  }
  expect 8.2.34 affected
  expect 8.2.35 patched
  expect 8.3.35 affected
  expect 8.3.36 patched
  expect 8.4.26 affected
  expect 8.4.27 patched
  expect 8.5.11 affected
  expect 8.5.12 patched
  expect 8.1.33 no-upstream-fix
  expect 7.4.33 no-upstream-fix
  expect 8.6.0 unknown
  [[ "$fail" -eq 0 ]] || exit 1
  echo "cve self-check ok"
}

active_apache_fpm_branch() {
  local f
  for f in /etc/apache2/conf-enabled/php*-fpm.conf; do
    [[ -e "$f" ]] || continue
    basename "$f" | sed -n 's/^php\([0-9]\+\.[0-9]\+\)-fpm\.conf$/\1/p'
  done | head -n1
}

active_mod_php_branch() {
  local f
  for f in /etc/apache2/mods-enabled/php*.load; do
    [[ -e "$f" ]] || continue
    basename "$f" | sed -n 's/^php\([0-9]\+\.[0-9]\+\)\.load$/\1/p'
  done | head -n1
}

installed_php_packages_for_branch() {
  local b_re; b_re="$(ere_escape "$1")"
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null \
    | grep -E "^php${b_re}(:[^[:space:]]+)?$|^php${b_re}-|^libapache2-mod-php${b_re}(:[^[:space:]]+)?$" \
    | sort -u || true
}

candidate_version() {
  # Read all input: an early awk exit SIGPIPEs apt-cache and trips pipefail.
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && !seen {print $2; seen=1}'
}

has_candidate() {
  local c; c="$(candidate_version "$1")"
  [[ -n "$c" && "$c" != "(none)" ]]
}

# Emit active (uncommented) directives from an ini file as "key<TAB>value".
active_directives() {
  awk '
    /^[[:space:]]*[;#]/ { next }
    /^[[:space:]]*\[/   { next }
    index($0, "=") {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      eq  = index(line, "=")
      key = substr(line, 1, eq - 1)
      val = substr(line, eq + 1)
      gsub(/[[:space:]]+$/, "", key); gsub(/^[[:space:]]+/, "", key)
      sub(/^[[:space:]]+/, "", val);  sub(/[[:space:]]+$/, "", val)
      sub(/[[:space:]]*;.*$/, "", val)
      if (key != "") print key "\t" val
    }
  ' "$1"
}

# Write a report of every active directive in old_ini that differs from new_ini.
report_ini_diff() {
  local old_ini="$1" new_ini="$2" out="$3"
  declare -A newmap=()
  local key val
  while IFS=$'\t' read -r key val; do
    newmap["$key"]="$val"
  done < <(active_directives "$new_ini")
  {
    echo "# Active directives in ${old_ini}"
    echo "# that are absent from or differ in ${new_ini}."
    echo "# The size/time directives are copied automatically; review the rest and"
    echo "# apply any that still matter to your application manually."
    echo
    printf '%-32s %-28s %s\n' "DIRECTIVE" "OLD VALUE" "NEW (target) VALUE"
    printf '%-32s %-28s %s\n' "---------" "---------" "------------------"
    while IFS=$'\t' read -r key val; do
      if [[ -z "${newmap[$key]+x}" ]]; then
        printf '%-32s %-28s %s\n' "$key" "$val" "(absent)"
      elif [[ "${newmap[$key]}" != "$val" ]]; then
        printf '%-32s %-28s %s\n' "$key" "$val" "${newmap[$key]}"
      fi
    done < <(active_directives "$old_ini")
  } > "$out"
}

show_audit() {
  local branch version pkg fpm_branch mod_branch
  . /etc/os-release
  echo
  echo "================ PHP / APACHE AUDIT ================"
  echo "OS: ${PRETTY_NAME:-unknown}"
  echo "CLI versions:"
  for pkg in /usr/bin/php /usr/bin/php8.*; do
    [[ -x "$pkg" ]] || continue
    version="$(php_cli_version "$pkg" || true)"
    [[ -n "$version" ]] && printf '  %-24s %s\n' "$pkg" "$version"
  done
  if have update-alternatives; then
    printf '  %-24s %s\n' "/usr/bin/php -> " "$(readlink -f /usr/bin/php 2>/dev/null || echo unknown)"
  fi
  fpm_branch="$(active_apache_fpm_branch || true)"
  mod_branch="$(active_mod_php_branch || true)"
  echo "Apache PHP handler:"
  if [[ -n "$fpm_branch" ]]; then
    echo "  PHP ${fpm_branch}-FPM config enabled"
    grep -hE 'SetHandler.*php[0-9]+\.[0-9]+-fpm\.sock' "/etc/apache2/conf-enabled/php${fpm_branch}-fpm.conf" 2>/dev/null | head -n2 || true
  elif [[ -n "$mod_branch" ]]; then
    echo "  mod_php ${mod_branch} enabled"
  else
    echo "  Standard PHP FPM/mod_php handler not detected"
  fi
  echo "FPM services:"
  for branch in 8.1 8.2 8.3 8.4 8.5; do
    if systemctl list-unit-files "php${branch}-fpm.service" --no-legend 2>/dev/null | grep -q "php${branch}-fpm.service"; then
      printf '  php%-7s active=%-8s enabled=%s\n' "${branch}-fpm" \
        "$(systemctl is-active "php${branch}-fpm" 2>/dev/null || true)" \
        "$(systemctl is-enabled "php${branch}-fpm" 2>/dev/null || true)"
    fi
  done
  echo "Installed PHP packages (first 100):"
  dpkg-query -W -f='${binary:Package}\t${Version}\n' 'php*' 'libapache2-mod-php*' 2>/dev/null \
    | grep -E '^(php[0-9]+\.[0-9]+|libapache2-mod-php[0-9]+\.[0-9]+)' | sort -u | head -100 || true
  echo
  print_cve_report
  echo "===================================================="
  echo
}

# Warn when vhosts pin a specific FPM socket inline; switching conf-enabled
# will not change those and may leave them on the old branch or break them.
warn_vhost_handlers() {
  local vhost_count pinned
  if have apache2ctl; then
    vhost_count="$(apache2ctl -S 2>/dev/null | grep -ciE 'namevhost' || true)"
    [[ "${vhost_count:-0}" -gt 1 ]] && \
      log "NOTE: ${vhost_count} name-based vhosts detected; the FPM handler switch is global."
  fi
  pinned="$(grep -rlE 'SetHandler[^#]*php[0-9]+\.[0-9]+-fpm' /etc/apache2/sites-enabled/ 2>/dev/null || true)"
  if [[ -n "$pinned" ]]; then
    log "WARNING: these vhost files pin a PHP-FPM socket inline via SetHandler:"
    printf '  %s\n' $pinned | tee -a "$LOG_FILE"
    echo "  Switching conf-enabled will NOT update them. Edit these manually if needed."
  fi
}

# List every installed PHP branch (e.g. "8.1", "8.2"), including an idle CLI-only
# branch that is not the active web runtime but may still be vulnerable.
list_installed_branches() {
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null \
    | sed -nE 's/^php([0-9]+\.[0-9]+)(-.*|:.*)?$/\1/p; s/^libapache2-mod-php([0-9]+\.[0-9]+)(:.*)?$/\1/p' \
    | sort -u
}

# Restart active FPM workers so they load new binaries, then refresh Apache.
# mod_php is a shared module, so it only picks up a new build on a full restart,
# not a graceful reload.
restart_active_handlers() {
  local b mod_branch
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if systemctl list-unit-files "php${b}-fpm.service" --no-legend 2>/dev/null | grep -q "php${b}-fpm.service"; then
      if systemctl is-active --quiet "php${b}-fpm"; then
        systemctl restart "php${b}-fpm" && log "Restarted php${b}-fpm."
      fi
    fi
  done < <(list_installed_branches)
  if have apache2ctl; then
    apache2ctl configtest 2>&1 | tee -a "$LOG_FILE"
    if systemctl is-active --quiet apache2; then
      mod_branch="$(active_mod_php_branch || true)"
      if [[ -n "$mod_branch" ]]; then
        systemctl restart apache2 && log "Restarted Apache (mod_php ${mod_branch})."
      else
        systemctl reload apache2 && log "Reloaded Apache."
      fi
    fi
  fi
}

# Run apt-get install, then judge success by the requested PHP packages only.
# An unrelated half-configured package (e.g. shim-signed on EC2) makes apt-get
# exit non-zero even when every PHP package installed cleanly.
apt_install_php() {
  local pkg status
  local -a requested=() broken=()
  for pkg in "$@"; do [[ "$pkg" == -* ]] || requested+=("$pkg"); done
  if ! apt-get "${APT_OPTS[@]}" install "$@" 2>&1 | tee -a "$LOG_FILE"; then
    log "WARNING: apt-get reported an error. Checking whether the PHP packages themselves installed cleanly."
  fi
  for pkg in "${requested[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || true)"
    [[ "$status" == "ii"* ]] || broken+=("${pkg}(${status:-missing})")
  done
  ((${#broken[@]} == 0)) || die "These PHP packages are not fully installed: ${broken[*]}"
  log "All ${#requested[@]} requested PHP packages are installed and configured."
}

# Upgrade only the already-installed packages of one branch. No prompt, backup,
# apt update, or service restart here; the caller owns those.
_upgrade_branch_pkgs() {
  local branch="$1" pkg candidate
  local packages=()
  mapfile -t packages < <(installed_php_packages_for_branch "$branch")
  if ((${#packages[@]} == 0)); then
    log "No installed PHP ${branch} packages; skipping."
    return 0
  fi
  echo "PHP ${branch} packages and candidate versions:"
  for pkg in "${packages[@]}"; do
    candidate="$(candidate_version "$pkg")"
    printf '  %-34s %s\n' "$pkg" "${candidate:-unknown}"
  done
  log "Upgrading installed PHP ${branch} packages only."
  apt_install_php --only-upgrade "${packages[@]}"
}

update_branch_packages() {
  local branch="$1"
  local packages=()
  mapfile -t packages < <(installed_php_packages_for_branch "$branch")
  ((${#packages[@]} > 0)) || die "No installed PHP ${branch} packages found."
  echo "Only these already-installed PHP ${branch} packages will be considered:"
  printf '  %s\n' "${packages[@]}"
  ask_yes_no "Run apt update and upgrade only these packages?" || { log "Cancelled."; return 0; }

  backup_config
  log "Refreshing apt metadata."
  apt-get update "${APT_UPDATE_OPTS[@]}" 2>&1 | tee -a "$LOG_FILE"
  require_cve_candidate "$branch"
  ask_yes_no "Proceed with package upgrade?" || { log "Cancelled before package upgrade."; return 0; }

  _upgrade_branch_pkgs "$branch"
  restart_active_handlers
  verify_branch_cve "$branch"
  log "Update finished. PHP ${branch} is at a release that fixes CVE-2026-109618 / CVE-2026-109619. Test the application and review $LOG_FILE."
}

update_all_branches() {
  local b
  local branches=()
  mapfile -t branches < <(list_installed_branches)
  ((${#branches[@]} > 0)) || die "No installed PHP branches found."
  echo "Installed PHP branches: ${branches[*]}"
  echo "This upgrades the already-installed packages of EVERY branch above,"
  echo "including an idle branch (e.g. a PHP 8.5 CLI) that is not Apache's runtime."
  ask_yes_no "Run apt update and upgrade all these branches?" || { log "Cancelled."; return 0; }

  backup_config
  log "Refreshing apt metadata."
  apt-get update "${APT_UPDATE_OPTS[@]}" 2>&1 | tee -a "$LOG_FILE"
  ask_yes_no "Proceed with upgrading all installed PHP branches?" || { log "Cancelled before upgrade."; return 0; }

  local -a skipped=()
  local cand_ver cand_status
  for b in "${branches[@]}"; do
    if ! IFS=$'\t' read -r cand_ver cand_status < <(candidate_cve_status "$b"); then
      log "WARNING: no apt candidate for PHP ${b}; left unchanged."
      skipped+=("$b")
      continue
    fi
    if [[ "$cand_status" != patched ]]; then
      log "WARNING: PHP ${b} candidate ${cand_ver} does not fix CVE-2026-109618 / CVE-2026-109619 (${cand_status}). Not upgrading this branch."
      skipped+=("$b")
      continue
    fi
    _upgrade_branch_pkgs "$b"
    verify_branch_cve "$b"
  done
  restart_active_handlers
  if ((${#skipped[@]} > 0)); then
    die "Still exposed to CVE-2026-109618 / CVE-2026-109619: ${skipped[*]}. PHP older than 8.2 must be migrated (action 4) to 8.2.35 or newer."
  fi
  log "All-branch update finished. Every installed branch fixes CVE-2026-109618 / CVE-2026-109619. Test the application and review $LOG_FILE."
}

copy_ini_directive() {
  local old_ini="$1" new_ini="$2" directive="$3" from="$4" value d_re
  value="$(awk -v d="$directive" '$0 ~ "^[[:space:]]*" d "[[:space:]]*=" {
    sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*;.*/, ""); print; exit
  }' "$old_ini")"
  [[ -n "$value" ]] || return 0
  d_re="$(ere_escape "$directive")"
  if grep -Eq "^[[:space:]]*${d_re}[[:space:]]*=" "$new_ini"; then
    # Use | as delimiter and escape it (and &) so values with slashes are safe.
    local v_esc="${value//&/\\&}"; v_esc="${v_esc//|/\\|}"
    sed -i -E "s|^[[:space:]]*${d_re}[[:space:]]*=.*|${directive} = ${v_esc}|" "$new_ini"
  else
    printf '\n; Preserved by php-safe-maintenance from PHP %s FPM\n%s = %s\n' "$from" "$directive" "$value" >> "$new_ini"
  fi
  log "Preserved ${directive}=${value} from PHP ${from} FPM config."
}

# Decide whether an FPM pool directive should carry over to the new branch.
# The listen socket path is version-specific and deliberately excluded.
pool_key_wanted() {
  case "$1" in
    listen|listen.*)                 return 1 ;;
    slowlog)                         return 1 ;;
    pm|pm.*)                         return 0 ;;
    request_terminate_timeout|request_slowlog_timeout) return 0 ;;
    rlimit_files|rlimit_core)        return 0 ;;
    catch_workers_output|decorate_workers_output|clear_env) return 0 ;;
    user|group)                      return 0 ;;
    security.limit_extensions)       return 0 ;;
    env\[*\])                        return 0 ;;
    php_value\[*\]|php_flag\[*\]|php_admin_value\[*\]|php_admin_flag\[*\]) return 0 ;;
    *)                               return 1 ;;
  esac
}

# Carry custom pool.d/www.conf overrides to the target branch and save a full diff.
migrate_pool_overrides() {
  local from="$1" to="$2"
  local old_pool="/etc/php/${from}/fpm/pool.d/www.conf"
  local new_pool="/etc/php/${to}/fpm/pool.d/www.conf"
  if [[ ! -f "$old_pool" || ! -f "$new_pool" ]]; then
    log "Pool www.conf missing for one branch; skipping pool override copy."
    return 0
  fi
  diff -u "$new_pool" "$old_pool" > "$BACKUP_DIR/pool-www.conf.diff" 2>/dev/null || true
  local -a collected=()
  local line key
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*[\;#] ]] && continue
    [[ "$line" =~ ^[[:space:]]*\[ ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    key="${key//[[:space:]]/}"
    if pool_key_wanted "$key"; then
      collected+=("$line")
    fi
  done < "$old_pool"
  if ((${#collected[@]} > 0)); then
    {
      echo ""
      echo "; === Preserved by php-safe-maintenance from PHP ${from} pool on ${TIMESTAMP} ==="
      echo "; 'listen' socket path intentionally NOT copied (kept ${to}-specific)."
      printf '%s\n' "${collected[@]}"
    } >> "$new_pool"
    log "Appended ${#collected[@]} pool directive(s) from PHP ${from} to PHP ${to} www.conf."
  else
    log "No custom pool overrides detected to copy from PHP ${from}."
  fi
}

migrate_fpm() {
  local from="$1" to="$2"
  local old_ini="/etc/php/${from}/fpm/php.ini"
  local new_ini="/etc/php/${to}/fpm/php.ini"
  local new_conf="/etc/apache2/conf-available/php${to}-fpm.conf"
  local oldpkg oldpkg_name ext
  local install_list=("php${to}-cli" "php${to}-common" "php${to}-fpm")
  local extensions=()

  [[ "$from" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid source branch '${from}'."
  [[ "$to"   =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid target branch '${to}'."
  [[ "$from" != "$to" ]] || die "Source and target branches are the same (${from})."
  [[ -e "/etc/apache2/conf-enabled/php${from}-fpm.conf" ]] || die "Apache PHP ${from}-FPM config is not enabled. No migration performed."
  [[ -f "$old_ini" ]] || die "PHP ${from} FPM php.ini not found."
  have apache2ctl || die "apache2ctl not found."
  have a2enconf && have a2disconf || die "a2enconf/a2disconf not found."
  . /etc/os-release
  [[ "${ID:-}" == ubuntu || "${ID_LIKE:-}" == *debian* ]] || die "Migration supports Debian/Ubuntu (apt) only."

  warn_vhost_handlers

  backup_config
  log "Refreshing apt metadata."
  apt-get update "${APT_UPDATE_OPTS[@]}" 2>&1 | tee -a "$LOG_FILE"

  # Fail early (before installing anything) if the target branch is not available.
  has_candidate "php${to}-fpm" || die "No installable candidate for php${to}-fpm. Enable a repo that ships it first, e.g.:
  sudo add-apt-repository ppa:ondrej/php && sudo apt-get update"
  require_cve_candidate "$to"

  # Install target-branch equivalents of the extensions installed for the source.
  while IFS= read -r oldpkg; do
    oldpkg_name="${oldpkg%%:*}"
    [[ "$oldpkg_name" == php${from}-* ]] || continue
    ext="${oldpkg_name#php${from}-}"
    case "$ext" in fpm|cli|common|readline) continue ;; esac
    if has_candidate "php${to}-${ext}"; then
      extensions+=("php${to}-${ext}")
    else
      log "No candidate for mapped extension php${to}-${ext}; skipped."
    fi
  done < <(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u)

  install_list+=("${extensions[@]}")
  mapfile -t install_list < <(printf '%s\n' "${install_list[@]}" | sort -u)
  echo "Planned actions (PHP ${from}-FPM -> PHP ${to}-FPM):"
  echo "  - Install/update PHP ${to} FPM and matching available PHP ${from} extensions."
  echo "  - Back up PHP and Apache configuration."
  echo "  - Copy max_execution_time, memory_limit, post_max_size, upload_max_filesize."
  echo "  - Carry over custom FPM pool (pm.*, env[], php_admin_value[], ...) overrides."
  echo "  - Write a full php.ini diff report for manual review of other directives."
  echo "  - Switch Apache only after php-fpm and apache2 config tests pass."
  echo "  - Keep PHP ${from} installed and its service untouched for rollback."
  echo "Packages:"
  printf '  %s\n' "${install_list[@]}"
  ask_yes_no "Proceed with this migration?" || { log "Cancelled."; return 0; }

  apt_install_php "${install_list[@]}"
  [[ -f "$new_ini" && -e "$new_conf" ]] || die "PHP ${to} FPM config files missing; Apache has not been switched."

  local directive
  for directive in max_execution_time memory_limit post_max_size upload_max_filesize; do
    copy_ini_directive "$old_ini" "$new_ini" "$directive" "$from"
  done
  report_ini_diff "$old_ini" "$new_ini" "$BACKUP_DIR/php-ini-diff-${from}-vs-${to}.txt"
  log "php.ini difference report: $BACKUP_DIR/php-ini-diff-${from}-vs-${to}.txt"
  migrate_pool_overrides "$from" "$to"

  "php-fpm${to}" -t 2>&1 | tee -a "$LOG_FILE"
  systemctl enable --now "php${to}-fpm"
  systemctl restart "php${to}-fpm"

  a2disconf "php${from}-fpm" 2>&1 | tee -a "$LOG_FILE"
  if ! a2enconf "php${to}-fpm" 2>&1 | tee -a "$LOG_FILE"; then
    a2disconf "php${to}-fpm" >/dev/null 2>&1 || true
    a2enconf "php${from}-fpm" >/dev/null 2>&1 || true
    die "Could not enable PHP ${to} FPM Apache config; PHP ${from} config restored."
  fi
  if ! apache2ctl configtest 2>&1 | tee -a "$LOG_FILE"; then
    log "Apache config test failed; restoring PHP ${from} config."
    a2disconf "php${to}-fpm" >/dev/null 2>&1 || true
    a2enconf "php${from}-fpm" >/dev/null 2>&1 || true
    apache2ctl configtest 2>&1 | tee -a "$LOG_FILE" || true
    die "Apache config test failed. Apache was not reloaded; old config restored."
  fi
  systemctl reload apache2
  systemctl is-active --quiet "php${to}-fpm" || die "PHP ${to} FPM is not active."
  systemctl is-active --quiet apache2 || die "Apache is not active."
  log "Migration finished. PHP ${from} packages/service were deliberately retained."
  verify_branch_cve "$to"
  log "PHP ${to} is at a release that fixes CVE-2026-109618 / CVE-2026-109619. PHP ${from} is still installed and still affected until you purge it (action 5)."

  # The CLI default (/usr/bin/php) is separate from the Apache handler.
  if have update-alternatives; then
    local cur_cli
    cur_cli="$(php_cli_version /usr/bin/php || true)"
    echo "CLI 'php' currently reports: ${cur_cli:-unknown} (cron/CLI jobs use this)."
    if [[ -x "/usr/bin/php${to}" ]] && ask_yes_no "Point the 'php' CLI default to ${to}?"; then
      update-alternatives --set php "/usr/bin/php${to}" 2>&1 | tee -a "$LOG_FILE" \
        || log "Could not switch CLI default; do it manually with update-alternatives."
    else
      log "CLI default left unchanged."
    fi
  fi

  echo
  echo "Now manually test login, database, uploads and scheduled jobs."
  echo "Backup: $BACKUP_DIR"
  echo "Log: $LOG_FILE"
  echo "Review:"
  echo "  $BACKUP_DIR/php-ini-diff-${from}-vs-${to}.txt   (other php.ini directives)"
  echo "  $BACKUP_DIR/pool-www.conf.diff                   (FPM pool differences)"
  echo "Rollback if needed:"
  echo "  sudo a2disconf php${to}-fpm && sudo a2enconf php${from}-fpm"
  echo "  sudo apache2ctl configtest && sudo systemctl reload apache2"
}

run_update_action() {
  local fpm_branch mod_branch branch
  fpm_branch="$(active_apache_fpm_branch || true)"
  mod_branch="$(active_mod_php_branch || true)"
  branch="${fpm_branch:-$mod_branch}"
  if [[ -z "$branch" ]]; then
    branch="$(ask_value "Active branch not detected. Enter branch like 8.2 (blank cancels): ")"
  else
    echo "Detected active Apache PHP branch: $branch"
    ask_yes_no "Use this branch?" || return 0
  fi
  [[ "$branch" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid branch; cancelled."
  update_branch_packages "$branch"
}

run_migrate_action() {
  local from to
  from="${OPT_FROM:-$(active_apache_fpm_branch || true)}"
  if [[ -z "$from" ]]; then
    from="$(ask_value "Source FPM branch (e.g. 8.1): ")"
  fi
  [[ "$from" =~ ^[0-9]+\.[0-9]+$ ]] || die "Unknown/invalid source branch; pass --from=X.Y."
  to="${OPT_TO:-}"
  if [[ -z "$to" ]]; then
    to="$(ask_value "Target FPM branch (e.g. ${from%.*}.$(( ${from#*.} + 1 ))): ")"
  fi
  [[ "$to" =~ ^[0-9]+\.[0-9]+$ ]] || die "Unknown/invalid target branch; pass --to=X.Y."
  migrate_fpm "$from" "$to"
}

run_purge_action() {
  local branch active_fpm active_mod refs b_re
  local pkgs=()
  branch="${OPT_FROM:-}"
  if [[ -z "$branch" ]]; then
    branch="$(ask_value "PHP branch to disable and PURGE (e.g. 8.1): ")"
  fi
  [[ "$branch" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid branch; pass --from=X.Y."

  active_fpm="$(active_apache_fpm_branch || true)"
  active_mod="$(active_mod_php_branch || true)"
  [[ "$branch" == "$active_fpm" ]] && die "PHP ${branch} is the ACTIVE Apache FPM handler; refusing to purge."
  [[ "$branch" == "$active_mod" ]] && die "PHP ${branch} is the ACTIVE Apache mod_php handler; refusing to purge."

  mapfile -t pkgs < <(installed_php_packages_for_branch "$branch")
  ((${#pkgs[@]} > 0)) || die "No installed PHP ${branch} packages found; nothing to purge."

  echo "Scanning Apache config and cron for references to PHP ${branch}..."
  b_re="$(ere_escape "$branch")"
  refs="$(grep -RIlE "php${b_re}([^0-9]|$)" \
    /etc/apache2/sites-enabled /etc/apache2/conf-enabled \
    /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly \
    2>/dev/null || true)"
  if [[ -n "$refs" ]]; then
    log "WARNING: references to PHP ${branch} found in:"
    printf '  %s\n' $refs | tee -a "$LOG_FILE"
    echo "Purging may break the above. Review them first."
    ask_yes_no "References exist. Still purge PHP ${branch}?" || { log "Cancelled."; return 0; }
  fi

  echo "These PHP ${branch} packages will be PURGED (their config removed too):"
  printf '  %s\n' "${pkgs[@]}"
  ask_yes_no "Disable the service and PURGE all PHP ${branch} packages?" || { log "Cancelled."; return 0; }

  backup_config
  if systemctl list-unit-files "php${branch}-fpm.service" --no-legend 2>/dev/null | grep -q "php${branch}-fpm.service"; then
    systemctl disable --now "php${branch}-fpm" 2>&1 | tee -a "$LOG_FILE" || true
  fi
  if have a2disconf && [[ -e "/etc/apache2/conf-enabled/php${branch}-fpm.conf" ]]; then
    a2disconf "php${branch}-fpm" 2>&1 | tee -a "$LOG_FILE" || true
  fi

  log "Purging PHP ${branch} packages."
  apt-get "${APT_OPTS[@]}" purge "${pkgs[@]}" 2>&1 | tee -a "$LOG_FILE"

  if ask_yes_no "Run 'apt-get autoremove' to drop now-unused dependencies?"; then
    echo "autoremove would remove:"
    apt-get --dry-run autoremove 2>/dev/null | awk '/^Remv/ {print "  " $2}' || true
    ask_yes_no "Proceed with autoremove?" && apt-get "${APT_OPTS[@]}" autoremove 2>&1 | tee -a "$LOG_FILE"
  fi

  restart_active_handlers
  if have apache2ctl; then
    apache2ctl configtest 2>&1 | tee -a "$LOG_FILE" \
      || die "Apache config test FAILED after purge; investigate now (backup: $BACKUP_DIR)."
  fi
  systemctl is-active --quiet apache2 || die "Apache is not active after purge (backup: $BACKUP_DIR)."
  log "Purge of PHP ${branch} complete. Apache healthy. Backup: $BACKUP_DIR"
}

main() {
  local choice
  show_audit

  choice="$OPT_ACTION"
  if [[ -z "$choice" ]]; then
    echo "Choose an action:"
    echo "  1) Audit only (no changes)"
    echo "  2) Update packages for the ACTIVE Apache PHP branch"
    echo "  3) Update packages for ALL installed PHP branches"
    echo "  4) Migrate Apache FPM from one PHP branch to another"
    echo "  5) Disable and PURGE an old (inactive) PHP branch"
    echo "  6) Exit"
    choice="$(ask_value "Selection [1]: ")"
    choice="${choice:-1}"
  fi

  case "$choice" in
    1)
      if cve_exposure_open; then
        log "Audit: one or more PHP branches are still affected by CVE-2026-109618 / CVE-2026-109619."
        echo "Audit complete. PHP is still affected; see the CVE lines above."
        exit 1
      fi
      log "Audit: installed PHP fixes CVE-2026-109618 / CVE-2026-109619."
      echo "Audit complete. Installed PHP is at a fixed release."
      ;;
    2) run_update_action ;;
    3) update_all_branches ;;
    4) run_migrate_action ;;
    5) run_purge_action ;;
    6) log "Exited without changes." ;;
    *) die "Invalid selection: ${choice}" ;;
  esac
}

if [[ "$SELF_CHECK" -eq 1 ]]; then
  self_check_cve
  exit 0
fi

main
