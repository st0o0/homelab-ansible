# Ansible — Homelab Server Provisioning

Takes a fresh Debian server (IP + user + password) and makes it production-ready: SSH hardened, Docker installed, monitoring agent running, visible in Dockhand. Everything runs from the DevContainer — no local tool installation needed.

**Ansible provisions servers. [Dockhand](../README.md) manages what runs on them.**

## First-Time Setup

### 1. Open the DevContainer

Open this repo in VS Code and select **"Reopen in Container"**. Choose **Windows** or **Linux** depending on your host OS. The container comes with everything pre-installed: Ansible, SOPS, age, just, Bitwarden CLI.

### 2. Unlock Bitwarden

```bash
unlock
```

This sets `BW_SESSION` for the current shell. Required for SSH key management and age key recovery.

### 3. Initialize SOPS encryption

```bash
cd ansible
just init
```

This will:
- Generate an age keypair (or restore it from Bitwarden if it exists)
- Back up the private key to Bitwarden as a Secure Note
- Update `.sops.yaml` with your public key
- Create encrypted `secret.sops.yml` files for every host in `hosts.yml`

On a new machine, `just init` automatically restores your age key from Bitwarden — no manual key copying needed.

### 4. Fill in secrets

```bash
just secret obs-1
```

SOPS opens your editor with pre-populated fields. Replace the `CHANGEME` values:

```yaml
ansible_host: "10.0.20.102"
ansible_user: st0o0
node_agent_obs_host: "10.0.20.102"
node_agent_dockhand_url: "http://10.0.20.102:9000"
node_agent_dockhand_token: "your-actual-token"
```

Repeat for each host: `just secret <hostname>`

### 5. Deploy the container's SSH key to your servers

The DevContainer has its own SSH key. Servers need to trust it before Ansible can connect.

```bash
just show-key          # prints the public key + copy-paste command
```

From your **Windows terminal** (where YubiKey works):

```powershell
$env:SSH_AUTH_SOCK = "\\.\pipe\ssh-pageant"
ssh user@10.0.20.102 "mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys"
```

Back in the DevContainer, verify:

```bash
just trust obs-1       # should print: ✓ obs-1 reachable
```

### 6. Commit the encrypted secrets

```bash
git add .sops.yaml host_vars/
git commit -m "feat(ansible): add SOPS-encrypted host secrets"
```

The `secret.sops.yml` files are safely encrypted — values are hidden, but the YAML structure is visible in diffs.

---

## Provisioning a New Server

### Fresh server with root password

```bash
just new-host myserver                  # scaffold host_vars + edit secrets
# Add 'myserver:' to hosts.yml
just bootstrap myserver                 # SSH keys, user creation, sshd hardening
just deploy myserver                    # base packages, Docker, node agent
```

`bootstrap` connects as root with a password (`--ask-pass`), creates the deploy user, sets up SSH keys (backed up to Bitwarden), and hardens sshd. After this, root login is disabled and Ansible uses the backup key.

### Existing server (already has your SSH key)

```bash
just new-host myserver                  # scaffold host_vars + edit secrets
# Add 'myserver:' to hosts.yml
just show-key                           # deploy container SSH key from Windows
just trust myserver                     # verify access
just deploy myserver                    # provision everything
```

### Bootstrap as non-root user

```bash
just bootstrap myserver st0o0           # connects as st0o0 instead of root
```

---

## Daily Usage

### Commands

| Command | Description |
|---|---|
| `just ping` | Connectivity check — all hosts |
| `just check` | Show bootstrap status of all hosts |
| `just run` | Converge all hosts (all roles) |
| `just deploy HOST` | Converge a single host |
| `just deploy HOST --tags docker` | Run only specific roles on a host |
| `just update` | apt dist-upgrade on all hosts |
| `just sync-dotfiles` | Enable chezmoi where missing + pull/apply latest dotfiles everywhere |
| `just bootstrap HOST [USER]` | First-time setup (default: root) |
| `just setup` | New workstation — restore age key + SSH keys from Bitwarden |
| `just secret HOST` | Edit encrypted secrets |
| `just vars HOST` | Edit plaintext feature toggles |
| `just new-host HOST` | Scaffold a new host |
| `just show-key` | Show container SSH public key |
| `just trust HOST` | Test if Ansible can reach a host |
| `just sshsync` | Backfill `~/.ssh/config` entries for hosts with an existing backup key |
| `just rename OLD NEW` | Rename a host everywhere |
| `just init` | First-time SOPS/age setup |
| `just lint` | Run ansible-lint |

### Tags

Run specific roles with `--tags`:

```bash
just run --tags base                  # only base packages + timezone
just run --tags docker                # only Docker
just run --tags hostname              # only set hostnames
just run --tags motd                  # only login banner
just run --tags swap                  # only swap configuration
just run --tags ufw                   # only firewall
just run --tags cron                  # only cron jobs
just run --tags unattended_upgrades   # only auto-updates
just run --tags node_agent            # only Alloy/Hawser agents
just deploy myserver --tags docker,base
```

### Dry run

```bash
just run --check                  # show what would change without applying
just deploy myserver --check -v   # verbose dry run for one host
```

---

## Directory Structure

```
ansible/
  ansible.cfg                    # Ansible settings (inventory, key, SOPS plugin)
  justfile                       # All commands — run 'just --list' to see them
  .sops.yaml                    # SOPS encryption rules (age public key)

  bootstrap.yml                 # One-time playbook: root → deploy user + SSH
  run.yml                       # Main playbook: all roles

  hosts.yml                     # Flat inventory — just hostnames
  group_vars/all/               # Defaults shared by all hosts
    base.yml                    #   timezone, packages
    docker.yml                  #   Docker user, package list
    ssh.yml                     #   Bitwarden folder, YubiKey keys
    node_agent.yml              #   Alloy/Hawser defaults
  host_vars/<hostname>/
    vars.yml                    # Feature toggles (plaintext, in git)
    secret.sops.yml             # Secrets: IPs, passwords, tokens (encrypted, in git)

  roles/
    hostname/                   # Sets server hostname to inventory name
    base/                       # Timezone, apt packages (btop, git, curl, figlet)
    swap/                       # Optional swap file configuration
    unattended_upgrades/        # Automatic security updates
    ufw/                        # Firewall (SSH allowed by default)
    docker/                     # Docker CE from official repo
    cron/                       # Scheduled tasks (docker prune, custom jobs)
    motd/                       # Colored login banner with system info
    ssh/                        # SSH key management + sshd hardening
    node_agent/                 # Alloy + Hawser + optional Bifrost
```

---

## Roles

### hostname

Sets the server's hostname to match the Ansible inventory name. Runs on every converge to keep names in sync.

### base

Installs standard tools (`btop`, `git`, `curl`, `ca-certificates`, `figlet`), sets the timezone, and optionally runs `apt dist-upgrade`.

**Variables** (`group_vars/all/base.yml`):
- `base_timezone` — default: `Europe/Berlin`
- `base_packages` — list of packages to install
- `base_upgrade` — set to `true` for dist-upgrade (default: `false`, use `just update`)

### docker

Installs Docker CE from the official Docker APT repository (not the distro's `docker.io`). Detects architecture automatically (amd64, arm64).

**Variables** (`group_vars/all/docker.yml`):
- `docker_user` — user added to the docker group (default: `ansible_user`)
- `docker_packages` — `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`

### ssh

Handles the complete SSH lifecycle. In bootstrap mode (connecting as root), it creates the deploy user, generates an ed25519 backup key, stores it in Bitwarden, and deploys authorized_keys. In normal mode, it ensures keys are up to date.

SSHD is hardened via a drop-in config at `/etc/ssh/sshd_config.d/99-ansible-hardening.conf` — no conflicts with package updates.

**Variables** (`group_vars/all/ssh.yml`):
- `ssh_user` — deploy user to create/manage
- `ssh_yubikey_public_keys` — YubiKey public keys for authorized_keys
- `ssh_bitwarden_folder` — Bitwarden folder for backup keys
- `ssh_exclusive` — if `true`, only managed keys are allowed (removes others)

### swap

Configures a swap file. Useful for Pis and LXC containers with limited RAM. Disabled by default — enable per host.

**Variables** (`host_vars/<hostname>/vars.yml`):
- `swap_enabled` — default: `false`
- `swap_size` — default: `2G`
- `swap_swappiness` — default: `10` (prefer RAM over swap)

### unattended_upgrades

Automatic security updates via `apt`. Disabled by default — enable per host. Supports package blacklists and reboot control.

**Variables** (`host_vars/<hostname>/vars.yml`):
- `unattended_upgrades_enabled` — default: `false`
- `unattended_upgrades_blacklist` — list of packages to never auto-update (e.g. `["docker-ce", "wireguard*"]`)
- `unattended_upgrades_skip_reboot_required` — if `true`, only installs updates that don't require a reboot (default: `false`)
- `unattended_upgrades_auto_reboot` — if `true`, reboots automatically after updates (default: `false`)
- `unattended_upgrades_auto_reboot_time` — reboot time window (default: `04:00`)

### ufw

Firewall using UFW. SSH is allowed by default, everything else denied incoming.

**Variables** (`defaults/main.yml` + `host_vars/<hostname>/vars.yml`):
- `ufw_enabled` — default: `true`
- `ufw_rules` — default: `[{rule: allow, port: 22, proto: tcp, comment: "SSH"}]`
- `ufw_extra_rules` — per-host additional rules, e.g.:
  ```yaml
  ufw_extra_rules:
    - { rule: allow, port: 8978, proto: tcp, comment: "CloudBeaver" }
    - { rule: allow, port: 5432, proto: tcp, comment: "PostgreSQL" }
  ```

### cron

Scheduled maintenance tasks. Docker system prune runs weekly by default.

**Variables** (`host_vars/<hostname>/vars.yml`):
- `cron_enabled` — default: `true`
- `cron_docker_prune` — default: `true` (weekly Sunday 03:00)
- `cron_docker_prune_schedule` — cron expression (default: `0 3 * * 0`)
- `cron_extra_jobs` — list of custom cron jobs:
  ```yaml
  cron_extra_jobs:
    - { name: "cleanup-logs", job: "find /var/log -name '*.gz' -mtime +30 -delete", schedule: "0 4 * * 0" }
  ```

### motd

Colored login banner showing hostname (as ASCII art via figlet), OS, kernel, IPs, Docker containers, performance bars (load, memory, disk with color-coded thresholds), and available config tools (armbian-config, raspi-config, nmtui).

**Variables** (`host_vars/<hostname>/vars.yml`):
- `motd_enabled` — default: `true`

### dotfiles

Delegates to the [dotfiles repo](https://github.com/st0o0/dotfiles)'s
`install.sh --profile server`, which installs the full shell toolchain
(zsh, tmux, chezmoi, starship, zoxide) and applies the `server` profile
(`.zshrc`, `.tmux.conf`, aliases). On first run, the script installs
everything and runs `chezmoi init --apply`; on subsequent converges, only
`chezmoi update --force` runs, so dotfile changes propagate on the next
`just deploy`/`just run`.

The dotfiles repo's `install.sh` is the single source of truth for tool
installation — this role does not install shell tools itself.

**Variables** (`roles/dotfiles/defaults/main.yml`):
- `dotfiles_enabled` — default: `true`
- `dotfiles_github_user` — default: `st0o0`

### node_agent

Deploys monitoring and management agents as Docker containers. Each component is independently toggleable:

| Component | Default | Purpose |
|---|---|---|
| **Alloy** | enabled | Grafana Alloy — collects host metrics + Docker/system logs, pushes to central VictoriaMetrics/VictoriaLogs |
| **Hawser** | enabled | Dockhand edge agent — makes the server visible in Dockhand for stack management |
| **Bifrost** | disabled | WireGuard tunnel sidecar — routes Alloy + Hawser traffic through an encrypted tunnel for remote servers |

**Per-host toggles** (`host_vars/<hostname>/vars.yml`):
```yaml
node_agent_alloy_enabled: true    # metrics + logs
node_agent_hawser_enabled: true   # Dockhand agent
node_agent_bifrost_enabled: false  # WireGuard tunnel
```

**Per-host secrets** (`host_vars/<hostname>/secret.sops.yml`):
```yaml
node_agent_obs_host: "10.0.20.102"           # central monitoring server IP
node_agent_dockhand_url: "http://10.0.20.102:9000"
node_agent_dockhand_token: "your-token"
```

Uses the Docker Compose overlay pattern — each component is a separate compose file layered together at deploy time.

---

## Secret Management

### How it works

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age). SOPS encrypts only the **values**, leaving YAML keys visible. This means `git diff` shows which fields changed without revealing the values.

```yaml
# What's stored in git (encrypted):
ansible_host: ENC[AES256_GCM,data:aBcDeFg=,iv:...,tag:...,type:str]
ansible_user: ENC[AES256_GCM,data:xYz=,iv:...,tag:...,type:str]
```

### Editing secrets

```bash
just secret myhost         # opens in $EDITOR, auto-encrypts on save
```

### Template

New hosts get secrets pre-populated from `host_vars/secret.sops.yml.tpl`:

```yaml
ansible_host: "CHANGEME"
ansible_user: "CHANGEME"
node_agent_obs_host: "CHANGEME"
node_agent_dockhand_url: "http://CHANGEME:9000"
node_agent_dockhand_token: "CHANGEME"
```

Edit the template to add fields that every host needs.

### Key recovery

The age private key is backed up to Bitwarden as a Secure Note ("Homelab SOPS Age Key"). On a new machine:

```bash
unlock                    # set BW_SESSION
just init                 # auto-restores the key from Bitwarden
```

---

## Renaming a Host

```bash
just rename oldname newname
```

This renames everything in one step:
- `host_vars/oldname/` → `host_vars/newname/`
- Updates `hosts.yml`
- Renames SSH backup keys (`~/.ssh/id_backup_*`)
- Recreates SSH config entry with the new name + IP
- Renames the Bitwarden backup key item (if `BW_SESSION` is set)

Then apply the hostname on the server and commit:

```bash
just deploy newname --tags hostname
git add -A && git commit -m "rename: oldname → newname"
```

---

## DevContainer

Two platform-specific configurations under `.devcontainer/`:

| Platform | SSH/YubiKey | Bitwarden |
|---|---|---|
| **Windows** | Container SSH key (`id_ansible`) — deploy to servers from Windows where YubiKey works | `bw login` required |
| **Linux** | GPG agent socket mounted — YubiKey works directly | Snap config passed through — already logged in |

### Installed tools

The DevContainer's `postCreateCommand` installs tools in two layers:

| Layer | Tools | Source |
|---|---|---|
| Shell toolchain | zsh, tmux, chezmoi, starship, zoxide, fzf, kitty | `dotfiles/install.sh --profile workstation` |
| Infrastructure | Ansible, ansible-lint, SOPS, age, just, jq, Bitwarden CLI, sshpass | `scripts/install-dependencies.sh` |

### Shell prompt icons look broken / boxes instead of icons (Windows)

`terminal.integrated.fontFamily` in `.devcontainer/*/devcontainer.json` only tells VS Code *which* font to request — VS Code's integrated terminal is rendered by the Electron UI process on your **host** machine, not inside the container, so the Nerd Font glyphs Starship uses (segment icons, git branch symbol, etc.) only render if that font is actually installed on the host OS. This is why the Linux devcontainer can look right while Windows doesn't: the font has to be installed once per host, separately from anything the container/postCreateCommand can do.

Install it once on the Windows host, then fully restart VS Code (reload window is not enough — the font list is cached at process start):

```powershell
winget install -e --id DEVCOM.JetBrainsMonoNerdFont
```

### Persistent storage

- **SSH keys** — Docker volume `homelab-catalog-ssh`, survives rebuilds
- **SOPS age key** — Docker volume `homelab-catalog-sops`, survives rebuilds

---

## Troubleshooting

### "Permission denied (publickey)"

Ansible can't connect. Check which key it's trying:

```bash
just trust myhost          # tests backup key, shows deploy instructions if needed
```

If the host was just bootstrapped, the backup key should be at `~/.ssh/id_backup_<hostname>`. If it's missing, restore from Bitwarden:

```bash
unlock
just bootstrap myhost      # re-runs SSH role, restores key from BW
```

### "sops metadata not found"

The secret file wasn't created with SOPS. Delete and recreate:

```bash
rm host_vars/myhost/secret.sops.yml
just secret myhost
```

### "age key not found"

```bash
unlock
just init                  # restores from Bitwarden
```

### "dpkg was interrupted"

A previous apt run was interrupted on the server. Fix manually:

```bash
ssh myhost "sudo dpkg --configure -a"
just deploy myhost
```

### Windows: "Permission denied" when SSHing with YubiKey

```powershell
# Point SSH at the GPG agent
$env:SSH_AUTH_SOCK = "\\.\pipe\ssh-pageant"
ssh-add -L                # should show your YubiKey key

# Make permanent:
[Environment]::SetEnvironmentVariable("SSH_AUTH_SOCK", "\\.\pipe\ssh-pageant", "User")
```
