#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------------
# Layer 1: Shell toolchain (zsh, tmux, starship, chezmoi, fzf, zoxide)
# --------------------------------------------------------------------------
# Owned by the dotfiles repo — single source of truth for shell tools.
echo "==> Installing shell toolchain via dotfiles/install.sh..."
curl -fsSL https://raw.githubusercontent.com/st0o0/dotfiles/main/install.sh \
    | bash -s -- --profile workstation

# --------------------------------------------------------------------------
# Layer 2: Infrastructure tools (DevContainer-specific)
# --------------------------------------------------------------------------
echo "==> Installing infrastructure dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
    sshpass \
    python3-pip \
    python3-venv \
    jq \
    > /dev/null

echo "==> Installing Ansible via pip..."
pip install --break-system-packages -q ansible ansible-lint

echo "==> Installing Ansible collections..."
ansible-galaxy collection install -r requirements.yml --force-with-deps > /dev/null

echo "==> Installing Bitwarden CLI (latest)..."
npm install -g @bitwarden/cli --silent

echo "==> Configuring Bitwarden CLI..."
if [ -n "${BW_SERVER_URL:-}" ]; then
    bw config server "$BW_SERVER_URL"
    echo "    Server: $BW_SERVER_URL"
else
    echo "    No BW_SERVER_URL set — using Bitwarden cloud"
fi

BW_HOST_DIRS=(
    "/home/${USER:-vscode}/snap/bw/current/Bitwarden CLI"
    "/root/snap/bw/current/Bitwarden CLI"
)
BW_TARGET="$HOME/.config/Bitwarden CLI"
if [ ! -d "$BW_TARGET/data" ]; then
    for dir in "${BW_HOST_DIRS[@]}"; do
        if [ -d "$dir/data" ]; then
            echo "    Found host BW config at $dir — linking..."
            rm -rf "$BW_TARGET"
            ln -s "$dir" "$BW_TARGET"
            break
        fi
    done
fi

echo "==> Installing age..."
curl -fsSL "https://dl.filippo.io/age/latest?for=linux/amd64" -o /tmp/age.tar.gz
sudo tar -xzf /tmp/age.tar.gz -C /usr/local/bin/ --strip-components=1 age/age age/age-keygen
rm /tmp/age.tar.gz

echo "==> Installing SOPS..."
SOPS_VERSION="v3.9.4"
curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" -o /tmp/sops
sudo install -m 0755 /tmp/sops /usr/local/bin/sops
rm /tmp/sops

echo "==> Installing just..."
curl -fsSL https://just.systems/install.sh | sudo bash -s -- --to /usr/local/bin

echo "==> Generating Ansible SSH key (if not present)..."
if [ ! -f "$HOME/.ssh/id_ansible" ]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ansible" -N "" -C "ansible-controller"
    echo "    New key generated. Public key:"
    echo ""
    echo "    $(cat "$HOME/.ssh/id_ansible.pub")"
    echo ""
else
    echo "    Key already exists (persistent volume)"
fi

echo "==> Restoring SOPS age key from Bitwarden (if not present)..."
AGE_KEY_DIR="$HOME/.config/sops/age"
AGE_KEY_FILE="$AGE_KEY_DIR/keys.txt"
if [ -f "$AGE_KEY_FILE" ]; then
    echo "    Age key already exists"
elif [ -n "${BW_SESSION:-}" ]; then
    echo "    BW_SESSION set — attempting restore from Bitwarden..."
    AGE_KEY=$(bw get item "Homelab SOPS Age Key" 2>/dev/null | jq -r '.notes // empty' 2>/dev/null || true)
    if [ -n "$AGE_KEY" ]; then
        mkdir -p "$AGE_KEY_DIR"
        printf '%s' "$AGE_KEY" > "$AGE_KEY_FILE"
        chmod 600 "$AGE_KEY_FILE"
        echo "    Age key restored from Bitwarden"
    else
        echo "    No age key found in Bitwarden — run 'age-keygen' to create one"
    fi
else
    echo "    No age key and no BW_SESSION — set BW_SESSION to auto-restore, or run:"
    echo "    age-keygen -o $AGE_KEY_FILE"
fi

# --------------------------------------------------------------------------
# Layer 3: DevContainer shell customizations
# --------------------------------------------------------------------------
echo "==> Configuring system-wide tmux autostart..."
TMUX_AUTOSTART_MARKER="# homelab-catalog: tmux autostart"
TMUX_AUTOSTART_SNIPPET="
${TMUX_AUTOSTART_MARKER}
if [ -z \"\${NO_AUTOSTART:-}\" ] && [ -z \"\${TMUX:-}\" ] && [ -n \"\${PS1:-}\" ] && command -v tmux >/dev/null 2>&1; then
    exec tmux new-session -A -s main
fi
"
for rc in /etc/bash.bashrc /etc/zsh/zshrc /etc/profile /etc/zsh/zprofile; do
    sudo mkdir -p "$(dirname "$rc")"
    sudo touch "$rc"
    if ! sudo grep -q "$TMUX_AUTOSTART_MARKER" "$rc"; then
        printf '%s\n' "$TMUX_AUTOSTART_SNIPPET" | sudo tee -a "$rc" > /dev/null
        echo "    Added to $rc"
    else
        echo "    Already present in $rc"
    fi
done

echo "==> Setting up devcontainer-specific shell aliases..."
ALIAS_DIR="$HOME/.bash_aliases.d"
mkdir -p "$ALIAS_DIR"
DEVCONTAINER_ALIASES="$ALIAS_DIR/00-devcontainer.sh"
if ! grep -q 'unlock()' "$DEVCONTAINER_ALIASES" 2>/dev/null; then
    cat > "$DEVCONTAINER_ALIASES" <<'ALIASES'
# Bitwarden unlock — sets BW_SESSION for the current shell
unlock() {
    export BW_SESSION=$(bw unlock --raw)
    echo "Bitwarden unlocked."
}
ALIASES
    echo "    Added 'unlock' alias"
else
    echo "    Aliases already present"
fi

# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------
echo "==> Verifying installations..."
ansible --version | head -1
bw --version
age --version
sops --version
just --version
tmux -V
zsh --version
fzf --version
starship --version | head -1
chezmoi --version | head -1
echo "    SSH key:  $([ -f "$HOME/.ssh/id_ansible" ] && echo 'present' || echo 'missing')"
echo "    Age key:  $([ -f "$AGE_KEY_FILE" ] && echo 'present' || echo 'missing')"

echo "==> Done."
