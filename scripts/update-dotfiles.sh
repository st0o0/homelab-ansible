#!/usr/bin/env bash
set -euo pipefail

CHEZMOI="$HOME/.local/bin/chezmoi"

if [ ! -x "$CHEZMOI" ]; then
    echo "==> chezmoi not installed yet, skipping dotfiles update (run postCreateCommand first)"
    exit 0
fi

if [ ! -d "$HOME/.local/share/chezmoi/.git" ]; then
    echo "==> chezmoi not initialized yet, skipping dotfiles update (run postCreateCommand first)"
    exit 0
fi

echo "==> Pulling latest dotfiles and re-applying..."
"$CHEZMOI" update --force

if command -v just >/dev/null 2>&1 && command -v ansible-inventory >/dev/null 2>&1; then
    echo "==> Syncing SSH config entries for hosts with a restored backup key..."
    just sshsync || true
fi
