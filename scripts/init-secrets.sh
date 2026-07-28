#!/usr/bin/env bash
set -euo pipefail

# First-time setup: generates an age keypair, backs it up to Bitwarden,
# configures SOPS, and creates empty encrypted secret files for every host
# in hosts.yml. Safe to re-run — skips steps that are already done.

AGE_KEY_DIR="$HOME/.config/sops/age"
AGE_KEY_FILE="$AGE_KEY_DIR/keys.txt"
SOPS_CONFIG=".sops.yaml"
HOSTS_FILE="hosts.yml"
BW_ITEM_NAME="Homelab SOPS Age Key"

cd "$(git rev-parse --show-toplevel)"

# `bw get item <name>` aborts with a non-JSON error if more than one item
# shares that name, so look items up by exact-name filter instead. If several
# match, let the user pick one (falls back to the most recent when non-interactive).
bw_find_item() {
    local name="$1"
    local matches count
    matches=$(bw list items --search "$name" 2>/dev/null \
        | jq -c --arg name "$name" '[.[] | select(.name == $name)]' 2>/dev/null) || matches="[]"
    count=$(echo "$matches" | jq 'length' 2>/dev/null || echo 0)

    if [ "$count" -gt 1 ] && [ -t 0 ]; then
        echo "==> Found $count Bitwarden items named '$name':" >&2
        local i=0
        while [ "$i" -lt "$count" ]; do
            local id date
            id=$(echo "$matches" | jq -r ".[$i].id")
            date=$(echo "$matches" | jq -r ".[$i].revisionDate")
            echo "    [$((i + 1))] id=$id  last modified=$date" >&2
            i=$((i + 1))
        done
        local choice
        read -rp "Which one do you want to use? [1-$count] " choice >&2
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
            echo "Invalid selection." >&2
            return 1
        fi
        echo "$matches" | jq ".[$((choice - 1))]"
        return 0
    fi

    if [ "$count" -gt 1 ]; then
        echo "==> Warning: found $count Bitwarden items named '$name'. Using the most recently modified one." >&2
        echo "    Consider deleting the duplicates in Bitwarden." >&2
    fi
    if [ "$count" -ge 1 ]; then
        echo "$matches" | jq 'sort_by(.revisionDate) | last'
    fi
}

# ── Step 1: Age keypair ──────────────────────────────────────────────

if [ -f "$AGE_KEY_FILE" ]; then
    echo "==> Age key already exists at $AGE_KEY_FILE"
else
    RESTORED=false
    if [ -n "${BW_SESSION:-}" ]; then
        echo "==> No local age key found. Checking Bitwarden for an existing key..."
        BW_ITEM=$(bw_find_item "$BW_ITEM_NAME")
        NOTES=$(echo "$BW_ITEM" | jq -r '.notes // empty' 2>/dev/null || true)
        if [ -n "$NOTES" ]; then
            echo "==> Restoring age key from Bitwarden..."
            mkdir -p "$AGE_KEY_DIR"
            echo "$NOTES" > "$AGE_KEY_FILE"
            chmod 600 "$AGE_KEY_FILE"
            RESTORED=true
            echo "    Restored: $AGE_KEY_FILE"
        else
            echo "==> No age key found in Bitwarden ($BW_ITEM_NAME)"
        fi
    else
        echo "==> BW_SESSION not set — cannot check Bitwarden for an existing key."
        echo "    export BW_SESSION=\$(bw unlock --raw)"
    fi

    if [ "$RESTORED" = false ]; then
        read -rp "No age key found locally or in Bitwarden. Generate a new one? [y/N] " REPLY
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            echo "==> Generating age keypair..."
            mkdir -p "$AGE_KEY_DIR"
            age-keygen -o "$AGE_KEY_FILE" 2>&1
            chmod 600 "$AGE_KEY_FILE"
        else
            echo "Aborting. Restore your key manually, or set BW_SESSION and re-run."
            exit 1
        fi
    fi
fi

PUBLIC_KEY=$(grep "public key:" "$AGE_KEY_FILE" | sed 's/.*public key: //')
echo "    Public key: $PUBLIC_KEY"

# ── Step 2: Backup to Bitwarden ──────────────────────────────────────

if [ -z "${BW_SESSION:-}" ]; then
    echo ""
    echo "==> BW_SESSION not set. To back up the age key to Bitwarden, run:"
    echo "    export BW_SESSION=\$(bw unlock --raw)"
    echo "    Then re-run this script."
    echo ""
    echo "    Continuing without Bitwarden backup..."
    echo ""
else
    EXISTING=$(bw_find_item "$BW_ITEM_NAME" | jq -r '.id // empty' 2>/dev/null || true)
    if [ -n "$EXISTING" ]; then
        echo "==> Age key already in Bitwarden ($BW_ITEM_NAME)"
    else
        echo "==> Backing up age key to Bitwarden..."
        KEY_CONTENT=$(cat "$AGE_KEY_FILE")
        bw get template item | \
            jq --arg name "$BW_ITEM_NAME" \
               --arg notes "$KEY_CONTENT" \
               '.type=2 | .name=$name | .notes=$notes | .secureNote={"type":0} | del(.login) | del(.folderId)' | \
            bw encode | bw create item > /dev/null
        echo "    Saved as Secure Note: $BW_ITEM_NAME"
    fi
fi

# ── Step 3: Update .sops.yaml ────────────────────────────────────────

CURRENT_KEY=$(grep -oP 'age1[a-z0-9]+' "$SOPS_CONFIG" 2>/dev/null || true)
if [ "$CURRENT_KEY" = "$PUBLIC_KEY" ]; then
    echo "==> .sops.yaml already has the correct public key"
elif echo "$CURRENT_KEY" | grep -q "TODO"; then
    echo "==> Updating .sops.yaml with public key..."
    sed -i "s|age1TODO_REPLACE_WITH_YOUR_PUBLIC_KEY|$PUBLIC_KEY|" "$SOPS_CONFIG"
    echo "    Updated: $SOPS_CONFIG"
elif [ -n "$CURRENT_KEY" ]; then
    echo "==> .sops.yaml already has a different key: $CURRENT_KEY"
    echo "    Not overwriting. Edit manually if you want to change it."
else
    echo "==> Updating .sops.yaml with public key..."
    sed -i "s|age1TODO_REPLACE_WITH_YOUR_PUBLIC_KEY|$PUBLIC_KEY|" "$SOPS_CONFIG"
    echo "    Updated: $SOPS_CONFIG"
fi

# ── Step 4: Scaffold secrets.sops.yml for each host ────────────────────────

export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

HOSTS=$(grep -oP '^\s{4}\S+(?=:)' "$HOSTS_FILE" | sed 's/^ *//' || true)

if [ -z "$HOSTS" ]; then
    echo "==> No hosts found in $HOSTS_FILE"
else
    echo "==> Checking secret files for hosts: $(echo $HOSTS | tr '\n' ' ')"
    for HOST in $HOSTS; do
        SECRET_FILE="host_vars/$HOST/secrets.sops.yml"
        if [ -f "$SECRET_FILE" ]; then
            echo "    $HOST: secrets.sops.yml already exists"
        else
            echo "    $HOST: creating from template..."
            mkdir -p "host_vars/$HOST"
            TEMPLATE="host_vars/secrets.sops.yml.tpl"
            cp "$TEMPLATE" "/tmp/secrets.sops.yml"
            sops --encrypt --age "$PUBLIC_KEY" --input-type yaml --output-type yaml "/tmp/secrets.sops.yml" > "$SECRET_FILE"
            rm "/tmp/secrets.sops.yml"
        fi
    done
fi

# ── Done ──────────────────────────────────────────────────────────────

echo ""
echo "==> Setup complete!"
echo ""
echo "    Next steps:"

NEEDS_EDIT=false
for HOST in $HOSTS; do
    SECRET_FILE="host_vars/$HOST/secrets.sops.yml"
    if sops -d "$SECRET_FILE" 2>/dev/null | grep -q "CHANGEME"; then
        NEEDS_EDIT=true
        break
    fi
done

if [ "$NEEDS_EDIT" = true ]; then
    echo "    1. Edit secrets for each host:"
    for HOST in $HOSTS; do
        echo "       just secrets $HOST"
    done
    echo "    2. Commit: git add .sops.yaml host_vars/ && git commit -m 'feat(ansible): add SOPS-encrypted host secrets'"
    echo "    3. Test:   just ping"
else
    echo "    All secrets already configured."
    echo "    Test: just ping"
fi
