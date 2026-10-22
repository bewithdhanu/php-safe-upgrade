# php-safe-upgrade

**Safely patch PHP on Ubuntu + Apache** — audit, upgrade, migrate PHP-FPM between versions, and clean up old branches, without breaking a running site. It checks two critical engine bugs from the 21 October 2026 security release, [CVE-2026-109618](https://www.php.net/archive/2026.php#2026-10-21-5) and [CVE-2026-109619](https://www.php.net/archive/2026.php#2026-10-21-5). Both can allow unauthenticated remote code execution. Updating to a fixed release is the only complete fix.

Backup-first, confirmation-gated, and idempotent. It never removes the active runtime, and validates Apache before switching anything.

## Quick start

Interactive (recommended — the menu needs a terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/bewithdhanu/php-safe-upgrade/main/php-safe-maintenance.sh -o php-safe-maintenance.sh \
  && sudo bash php-safe-maintenance.sh
```

Unattended single action (safe to pipe — needs no TTY):

```bash
# Patch the active Apache PHP branch
curl -fsSL https://raw.githubusercontent.com/bewithdhanu/php-safe-upgrade/main/php-safe-maintenance.sh | sudo bash -s -- --action=2 --yes

# Patch every installed PHP branch (incl. idle CLI-only versions)
curl -fsSL https://raw.githubusercontent.com/bewithdhanu/php-safe-upgrade/main/php-safe-maintenance.sh | sudo bash -s -- --action=3 --yes
```

Always read a script before piping it to a root shell.

## Actions

| Action | Description |
| --- | --- |
| 1 Audit | Report OS, CLI versions, Apache handler, FPM services, installed packages, and whether each branch fixes CVE-2026-109618 / CVE-2026-109619. No changes. Exits non-zero if any branch is still affected. |
| 2 Update active branch | Upgrade only the installed packages of the branch Apache uses, then restart FPM / Apache. Refuses to run unless the apt candidate is a fixed release, and checks `php -v` afterwards. |
| 3 Update all branches | Same, for every installed branch whose apt candidate is a fixed release. Exits non-zero if any branch is still affected (PHP 8.1 and older cannot be patched in place). |
| 4 Migrate FPM | Install a new FPM branch alongside the old, carry over php.ini + pool.d settings, validate, switch, keep old for rollback. The target candidate must be a fixed release (8.2.35 or newer). |
| 5 Purge old branch | Disable + purge an inactive branch. Refuses the active handler, scans for references, confirms first. |

## Usage

```bash
sudo ./php-safe-maintenance.sh [options]

  --action=N     1=audit, 2=update active, 3=update all,
                 4=migrate FPM, 5=purge an old branch, 6=exit
  --audit-only   Shorthand for --action=1
  --from=X.Y     Source branch for migration, or branch to purge (action 5)
  --to=X.Y       Target PHP branch for migration
  -y, --yes      Assume "yes" to all prompts (unattended)
  -h, --help     Show help
```

## Safety model

- Backs up `/etc/php` and `/etc/apache2` plus a package inventory before any change.
- apt runs with `DEBIAN_FRONTEND=noninteractive` and `--force-confold`, so a customized `php.ini` is kept, never overwritten, and the run never stalls on a dpkg prompt.
- Runs `php-fpm -t` and `apache2ctl configtest`; migration rolls back the handler if the config test fails.
- Only action 5 removes anything, and it refuses the active handler, scans Apache/cron, and double-confirms (`autoremove` is a separate opt-in).
- `flock` single-instance guard; full log at `/var/log/php-safe-maintenance.log`.
- Restarts Apache (not just reload) when mod_php is the handler.

## Requirements

Ubuntu/Debian with apt, Apache (mod_php or PHP-FPM), root.

For migrations the target branch must be installable — on stock Ubuntu that usually means the `ondrej/php` PPA. The script detects a missing candidate and tells you.

## Affected versions

CVE-2026-109618 and CVE-2026-109619 are in the PHP engine. They are not fixed by application code, a WAF rule, or an Ubuntu package bump that stays on an unfixed upstream version.

| Branch | Affected | First fixed release |
| --- | --- | --- |
| 8.5 | 8.5.0 – 8.5.11 | 8.5.12 |
| 8.4 | 8.4.0 – 8.4.26 | 8.4.27 |
| 8.3 | 8.3.0 – 8.3.35 | 8.3.36 |
| 8.2 | 8.2.0 – 8.2.34 | 8.2.35 |
| 8.1 and older | Affected | No upstream fix. Migrate to 8.2.35 or newer. |

The audit prints `PATCHED` or `AFFECTED` from `php -v` for every installed branch. Actions 2 and 4 stop before changing the system if apt's candidate is still below that floor. Action 3 upgrades only the branches whose candidate is fixed, then fails if anything (typically PHP 8.1) is still exposed so you can migrate it with action 4 and remove it with action 5.

A distro package whose `php -v` string is still below the fixed release is treated as affected, even if the Debian revision number changed. Confirm the result against the [php.net advisory](https://www.php.net/archive/2026.php#2026-10-21-5) if a vendor says they backported the fix without bumping that version.

## License

MIT
