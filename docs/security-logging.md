# Security Logging Reference

What the new security-hardening roles log, where those logs land, and how to
find them in Grafana (Explore → Loki/VictoriaLogs datasource) once the
central observability stack is up.

All entries below are shipped by Alloy from `/var/log/host/...` on each node
(see `stacks/observability-agent/alloy/config.alloy` in homelab-catalog) using
the `job` label to filter.

| Role | Log path (on host) | `job` label | Notes |
|---|---|---|---|
| `fail2ban` | `/var/log/fail2ban.log` | `fail2ban` | Ban/unban events, jail activity |
| `auditd` | `/var/log/audit/audit.log` | `auditd` | Raw audit records for watched files (see `auditd_rules`) |
| `rkhunter` | `/var/log/rkhunter-cron.log` | `rkhunter` | Daily cron run, warnings-only summary |
| `clamav` | `/var/log/clamav/scan.log` | `clamav` | Daily cron run, infected-files-only output |
| `lynis` | `/var/log/lynis.log` | `lynis` | Weekly cron run, human-readable audit report |

## Example LogQL queries

```logql
# Fail2Ban bans in the last 24h
{job="fail2ban"} |= "Ban"

# auditd: sudoers or SSH config changes
{job="auditd"} |= "sshd" or {job="auditd"} |= "scope"

# rkhunter: anything beyond a clean run
{job="rkhunter"} |= "Warning"

# clamav: any hit (file is infected-only, so any line here means a hit)
{job="clamav"}

# lynis: warnings and suggestions from the latest run
{job="lynis"} |= "Warning" or {job="lynis"} |= "Suggestion"
```

## What "normal" looks like

- **fail2ban**: empty or occasional `Ban`/`Unban` lines for known noisy IPs.
  A sudden spike in distinct banned IPs is worth a look.
- **auditd**: silence most of the time — these paths only change during
  actual maintenance (running `just deploy`, editing sudoers, rotating SSH
  keys). Any watched-file event outside of a deploy window is suspicious.
- **rkhunter**: `--report-warnings-only` means an empty log is the healthy
  state. Any line means rkhunter found something worth a human look.
- **clamav**: scan runs `-i` (infected-only), so an empty log is healthy.
- **lynis**: never empty — every run appends `Warning`/`Suggestion` lines.
  These are advisory, not incidents; review periodically rather than
  reacting per-line.

## Toggling roles

Each role is independently enabled/disabled via `<role>_enabled` in
`host_vars/<host>/vars.yml`, and has its own `just` deploy tag:

```bash
just deploy HOST --tags fail2ban
just deploy HOST --tags auditd
just deploy HOST --tags sysctl_hardening
just deploy HOST --tags pam_pwquality
just deploy HOST --tags rkhunter
just deploy HOST --tags clamav
just deploy HOST --tags lynis
```

## Deferred (not in this pass)

- Grafana dashboards and alert rules — needs the central Grafana stack
  deployed and a notification channel decided first.
- Fail2Ban jails for Vaultwarden/Authentik — those containers currently log
  only to Docker's json-file driver, not a plain-text file Fail2Ban can tail,
  and neither service is Ansible-managed yet.
- Lynis hardening-index metric extraction (would need a node_exporter
  textfile-collector job) — only useful once a dashboard exists to show it.
