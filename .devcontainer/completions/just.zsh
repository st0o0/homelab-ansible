# Host-aware zsh completion for `just` in this repo.
#
# `just --completions zsh` only knows recipe names, not that `deploy`,
# `bootstrap`, `vars`, `secrets`, `trust`, and `rename` take an inventory
# HOST as their first argument. This wraps the generated `_just` completer
# and offers real host names (from `ansible-inventory`) for those recipes,
# falling back to `_just` for everything else.

_homelab_just_hosts() {
    local root
    root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ -f "$root/ansible.cfg" && -f "$root/hosts.yml" ]] || return 1
    local -a hosts
    hosts=(${(f)"$(cd "$root" && ansible-inventory --list 2>/dev/null | jq -r '._meta.hostvars | keys[]' 2>/dev/null)"})
    (( ${#hosts} )) || return 1
    hosts+=(all)
    _describe 'host' hosts
}

_homelab_just() {
    local host_recipes='deploy|bootstrap|vars|secrets|trust|rename'
    if [[ ${words[2]} == (${~host_recipes}) && $CURRENT -le 4 ]]; then
        _homelab_just_hosts && return
    fi
    _just "$@"
}

compdef _homelab_just just
