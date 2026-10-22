# php-safe-upgrade

**Safely patch PHP on Ubuntu + Apache** — audit, upgrade, migrate PHP-FPM between versions, and clean up old branches, without breaking a running site. Built for applying the October 2026 PHP security releases on production Laravel/PHP servers, but useful for any routine PHP upgrade.

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
| 1 Audit | Report OS, CLI versions, Apache handler, FPM services, installed packages. No changes. |
| 2 Update active branch | Upgrade only the installed packages of the branch Apache uses, then restart FPM / Apache. |
| 3 Update all branches | Same, for every installed PHP branch — patches idle CLI-only versions too. |
| 4 Migrate FPM | Install a new FPM branch alongside the old, carry over php.ini + pool.d settings, validate, switch, keep old for rollback. |
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

## Note on the CVEs

Confirm exact fixed versions and your package's patch status against the official [php.net](https://www.php.net) advisory and your distro's security notices before declaring a server fixed — a version number alone, or a backported distro package, may not tell the whole story.

## License

MIT
