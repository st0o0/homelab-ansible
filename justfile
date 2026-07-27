set dotenv-load
set windows-shell := ["pwsh", "-NoProfile", "-Command"]

# --- DevContainer management ---
# On Linux: wraps .devcontainer/devcontainer.sh (VARIANT default: linux)
# On Windows: wraps .devcontainer/devcontainer.ps1 (Variant default: windows)

variant := env_var_or_default("VARIANT", if os() == "windows" { "windows" } else { "linux" })

# Create/start the dev container
[unix]
up:
    .devcontainer/devcontainer.sh --variant {{variant}} up

[windows]
up:
    devcontainer up --workspace-folder . --config .devcontainer/{{variant}}/devcontainer.json

# Stop the dev container
[unix]
down:
    .devcontainer/devcontainer.sh --variant {{variant}} down

[windows]
down:
    docker stop $(docker ps -q --filter "label=devcontainer.local_folder=$PWD")

# Remove + rebuild the dev container from scratch (--no-cache)
[unix]
rebuild:
    .devcontainer/devcontainer.sh --variant {{variant}} rebuild

[windows]
rebuild:
    devcontainer up --workspace-folder . --config .devcontainer/{{variant}}/devcontainer.json --remove-existing-container --build-no-cache

# Open an interactive shell inside the dev container
[unix]
shell:
    .devcontainer/devcontainer.sh --variant {{variant}} shell

[windows]
shell:
    devcontainer exec --workspace-folder . --config .devcontainer/{{variant}}/devcontainer.json tmux new-session -A -s main

# Run a command inside the dev container, e.g.: just exec ansible --version
[unix]
exec *ARGS:
    .devcontainer/devcontainer.sh --variant {{variant}} exec {{ARGS}}

[windows]
exec *ARGS:
    devcontainer exec --workspace-folder . --config .devcontainer/{{variant}}/devcontainer.json {{ARGS}}

# --- Ansible ---

# Bootstrap a new host (first run, as root with password)
bootstrap HOST USER="root":
    ansible-playbook bootstrap.yml --limit {{HOST}} -e ansible_user={{USER}} -e ansible_ssh_private_key_file=~/.ssh/id_ansible --ask-pass

# Set up a new workstation (restore age key + SSH backup keys from Bitwarden)
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${BW_SESSION:-}" ]; then
        echo "BW_SESSION not set. Run 'unlock' first."
        exit 1
    fi
    echo "=== Restoring age key ==="
    bash scripts/init-secrets.sh
    echo ""
    echo "=== Restoring SSH backup keys ==="
    HOSTS=$(ansible-inventory --list 2>/dev/null | jq -r '._meta.hostvars | keys[]')
    for HOST in $HOSTS; do
        KEY_FILE="$HOME/.ssh/id_backup_$HOST"
        if [ -f "$KEY_FILE" ]; then
            echo "  ✓ $HOST — already present"
            continue
        fi
        BW_ITEM=$(bw get item "ssh-backup-$HOST" 2>/dev/null || true)
        if [ -n "$BW_ITEM" ]; then
            echo "$BW_ITEM" | python3 -c "import sys,json; print(json.load(sys.stdin)['sshKey']['privateKey'], end='')" > "$KEY_FILE"
            chmod 600 "$KEY_FILE"
            ssh-keygen -y -f "$KEY_FILE" > "$KEY_FILE.pub"
            echo "  ✓ $HOST — restored from Bitwarden"
        else
            echo "  ✗ $HOST — not found in Bitwarden"
        fi
    done
    echo ""
    echo "Done. Run 'just ping' to verify connectivity."

# Converge all hosts
run *ARGS:
    ansible-playbook run.yml {{ARGS}}

# Converge a single host
deploy HOST *ARGS:
    ansible-playbook run.yml --limit {{HOST}} {{ARGS}}

# Run system updates (all hosts or single host)
update *ARGS:
    ansible-playbook run.yml --tags base -e base_upgrade=true {{ARGS}}

# Sync dotfiles on all hosts
sync-dotfiles *ARGS:
    ansible-playbook run.yml --tags dotfiles {{ARGS}}

# Connectivity check
ping:
    ansible -m ping all

# Edit plaintext vars for a host (or 'all' for shared vars)
vars HOST:
    #!/usr/bin/env bash
    if [ "{{HOST}}" = "all" ]; then
        "${EDITOR:-nano}" group_vars/all/shared.yml
    else
        "${EDITOR:-nano}" host_vars/{{HOST}}/vars.yml
    fi

# Edit encrypted secrets (host or 'all' for shared secrets)
secret HOST:
    #!/usr/bin/env bash
    if [ "{{HOST}}" = "all" ]; then
        SECRET="group_vars/all/secret.sops.yml"
        TEMPLATE="group_vars/all/secret.sops.yml.tpl"
    else
        SECRET="host_vars/{{HOST}}/secret.sops.yml"
        TEMPLATE="host_vars/secret.sops.yml.tpl"
    fi
    if [ ! -f "$SECRET" ]; then
        mkdir -p "$(dirname "$SECRET")"
        cp "$TEMPLATE" "/tmp/secret.sops.yml"
        sops --config .sops.yaml --encrypt "/tmp/secret.sops.yml" > "$SECRET"
        rm "/tmp/secret.sops.yml"
    fi
    sops "$SECRET" || true

# Create a new host (scaffold host_vars + secrets)
new-host HOST:
    #!/usr/bin/env bash
    mkdir -p "host_vars/{{HOST}}"
    VARS="host_vars/{{HOST}}/vars.yml"
    VARS_TPL="host_vars/vars.yml.tpl"
    if [ ! -f "$VARS" ]; then
        cp "$VARS_TPL" "$VARS"
        echo "  Created $VARS from template"
    fi
    SECRET="host_vars/{{HOST}}/secret.sops.yml"
    TEMPLATE="host_vars/secret.sops.yml.tpl"
    if [ ! -f "$SECRET" ]; then
        cp "$TEMPLATE" "/tmp/secret.sops.yml"
        sops --config .sops.yaml --encrypt "/tmp/secret.sops.yml" > "$SECRET"
        rm "/tmp/secret.sops.yml"
    fi
    sops "$SECRET" || true
    echo ""
    echo "Add '    {{HOST}}:' under 'all: hosts:' in hosts.yml"

# First-time setup (age key, Bitwarden backup, scaffold secrets)
init:
    bash scripts/init-secrets.sh

# Show the container's SSH public key (copy this to your servers)
show-key:
    #!/usr/bin/env bash
    KEY_FILE="$HOME/.ssh/id_ansible.pub"
    if [ ! -f "$KEY_FILE" ]; then
        echo "No SSH key found. Run the DevContainer setup first."
        exit 1
    fi
    PUB=$(cat "$KEY_FILE")
    echo ""
    echo "Copy this public key to your servers from a terminal where"
    echo "your YubiKey works (e.g. Windows PowerShell):"
    echo ""
    echo "  ssh USER@HOST \"mkdir -p ~/.ssh && echo '$PUB' >> ~/.ssh/authorized_keys\""
    echo ""
    echo "Or just echo to copy-paste:"
    echo ""
    echo "  echo '$PUB' >> ~/.ssh/authorized_keys"
    echo ""

# Check if Ansible can reach a host (tries backup key, then id_ansible)
trust HOST:
    #!/usr/bin/env bash
    INV=$(ansible-inventory --host {{HOST}} 2>/dev/null) || { echo "Host '{{HOST}}' not found in inventory."; exit 1; }
    HOST_IP=$(echo "$INV" | jq -r '.ansible_host // empty')
    USER=$(echo "$INV" | jq -r '.ansible_user // empty')
    USER="${USER:-$USER}"
    BACKUP_KEY="$HOME/.ssh/id_backup_{{HOST}}"
    ANSIBLE_KEY="$HOME/.ssh/id_ansible"
    KEY=""
    if [ -f "$BACKUP_KEY" ]; then KEY="$BACKUP_KEY";
    elif [ -f "$ANSIBLE_KEY" ]; then KEY="$ANSIBLE_KEY"; fi
    if [ -z "$KEY" ]; then echo "No SSH key found."; exit 1; fi
    echo "Testing $USER@$HOST_IP with $(basename "$KEY")..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$KEY" "$USER@$HOST_IP" "echo OK" 2>/dev/null; then
        echo "✓ {{HOST}} reachable"
    else
        echo "✗ {{HOST}} NOT reachable"
        echo ""
        echo "If this is a new server, deploy the container key from Windows (YubiKey):"
        echo "  ssh $USER@$HOST_IP \"mkdir -p ~/.ssh && echo '$(cat "$ANSIBLE_KEY.pub")' >> ~/.ssh/authorized_keys\""
        echo ""
        echo "Then run: just bootstrap {{HOST}} $USER"
    fi

# Backfill ~/.ssh/config entries for hosts that already have a backup key
sshsync:
    #!/usr/bin/env bash
    set -euo pipefail
    touch "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
    HOSTS=$(ansible-inventory --list 2>/dev/null | jq -r '._meta.hostvars | keys[]')
    for HOST in $HOSTS; do
        KEY="$HOME/.ssh/id_backup_$HOST"
        if [ ! -f "$KEY" ]; then
            echo "  ✗ $HOST — no backup key, skipped"
            continue
        fi
        INV=$(ansible-inventory --host "$HOST" 2>/dev/null)
        HOST_IP=$(echo "$INV" | jq -r '.ansible_host // empty')
        SSH_USER=$(echo "$INV" | jq -r '.ansible_user // empty')
        if [ -z "$HOST_IP" ] || [ -z "$SSH_USER" ]; then
            echo "  ✗ $HOST — missing ansible_host/ansible_user in inventory, skipped"
            continue
        fi
        sed -i "/# BEGIN ANSIBLE MANAGED - $HOST\$/,/# END ANSIBLE MANAGED - $HOST\$/d" "$HOME/.ssh/config"
        printf '# BEGIN ANSIBLE MANAGED - %s\nHost %s %s\n    HostName %s\n    User %s\n    IdentityFile %s\n# END ANSIBLE MANAGED - %s\n' \
            "$HOST" "$HOST" "$HOST_IP" "$HOST_IP" "$SSH_USER" "$KEY" "$HOST" >> "$HOME/.ssh/config"
        echo "  ✓ $HOST — SSH config entry written"
    done

# Show bootstrap status of all hosts
check:
    #!/usr/bin/env bash
    HOSTS=$(ansible-inventory --list 2>/dev/null | jq -r '._meta.hostvars | keys[]')
    for HOST in $HOSTS; do
        INV=$(ansible-inventory --host "$HOST" 2>/dev/null)
        IP=$(echo "$INV" | jq -r '.ansible_host // "?"')
        BACKUP_KEY="$HOME/.ssh/id_backup_$HOST"
        if [ -f "$BACKUP_KEY" ]; then
            STATUS="bootstrapped"
            ICON="✓"
        else
            STATUS="no backup key"
            ICON="✗"
        fi
        printf "  %s %-20s %-15s %s\n" "$ICON" "$HOST" "$IP" "$STATUS"
    done

# Rename a host (host_vars, hosts.yml, SSH keys, SSH config)
rename OLD NEW:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "host_vars/{{OLD}}" ]; then
        echo "Host '{{OLD}}' not found in host_vars/."
        exit 1
    fi
    if [ -d "host_vars/{{NEW}}" ]; then
        echo "Host '{{NEW}}' already exists."
        exit 1
    fi
    echo "Renaming {{OLD}} → {{NEW}}..."
    # host_vars
    mv "host_vars/{{OLD}}" "host_vars/{{NEW}}"
    echo "  ✓ host_vars/{{OLD}} → host_vars/{{NEW}}"
    # hosts.yml
    sed -i 's/^    {{OLD}}:/    {{NEW}}:/' hosts.yml
    echo "  ✓ hosts.yml updated"
    # SSH backup key
    for f in "$HOME/.ssh/id_backup_{{OLD}}" "$HOME/.ssh/id_backup_{{OLD}}.pub"; do
        if [ -f "$f" ]; then
            NEW_F=$(echo "$f" | sed 's/{{OLD}}/{{NEW}}/')
            mv "$f" "$NEW_F"
            echo "  ✓ $(basename "$f") → $(basename "$NEW_F")"
        fi
    done
    # SSH config — remove old, add new
    if [ -f "$HOME/.ssh/config" ]; then
        sed -i '/# BEGIN ANSIBLE MANAGED - {{OLD}}/,/# END ANSIBLE MANAGED - {{OLD}}/d' "$HOME/.ssh/config"
    fi
    HOST_IP=$(ansible-inventory --host {{NEW}} 2>/dev/null | jq -r '.ansible_host // empty' || true)
    SSH_USER=$(ansible-inventory --host {{NEW}} 2>/dev/null | jq -r '.ansible_user // empty' || true)
    SSH_USER="${SSH_USER:-st0o0}"
    BACKUP_KEY="$HOME/.ssh/id_backup_{{NEW}}"
    if [ -n "$HOST_IP" ] && [ -f "$BACKUP_KEY" ]; then
        printf '# BEGIN ANSIBLE MANAGED - {{NEW}}\nHost {{NEW}} %s\n    HostName %s\n    User %s\n    IdentityFile %s\n# END ANSIBLE MANAGED - {{NEW}}\n' \
            "$HOST_IP" "$HOST_IP" "$SSH_USER" "$BACKUP_KEY" >> "$HOME/.ssh/config"
        echo "  ✓ SSH config entry created for {{NEW}}"
    else
        echo "  ⚠ Could not create SSH config (missing IP or backup key)"
    fi
    # Bitwarden — rename the backup key item
    if [ -n "${BW_SESSION:-}" ]; then
        BW_ITEM=$(bw get item "ssh-backup-{{OLD}}" 2>/dev/null || true)
        if [ -n "$BW_ITEM" ]; then
            ITEM_ID=$(echo "$BW_ITEM" | jq -r '.id')
            echo "$BW_ITEM" | jq '.name = "ssh-backup-{{NEW}}"' | bw encode | bw edit item "$ITEM_ID" > /dev/null
            echo "  ✓ Bitwarden item renamed to ssh-backup-{{NEW}}"
        else
            echo "  ⚠ No Bitwarden item 'ssh-backup-{{OLD}}' found"
        fi
    else
        echo "  ⚠ BW_SESSION not set — rename Bitwarden item manually:"
        echo "    unlock && bw get item ssh-backup-{{OLD}} | jq '.name=\"ssh-backup-{{NEW}}\"' | bw encode | bw edit item <ID>"
    fi
    echo ""
    echo "Done. Apply hostname on server + commit:"
    echo "  just deploy {{NEW}} --tags hostname"
    echo "  git add -A && git commit -m 'rename: {{OLD}} → {{NEW}}'"

# Lint
lint:
    ansible-lint
