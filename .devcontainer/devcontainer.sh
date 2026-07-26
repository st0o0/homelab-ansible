#!/usr/bin/env bash
# Manage the dev container without VS Code, via the devcontainer CLI.
#
# Usage:
#   .devcontainer/devcontainer.sh up                 # create/start container
#   .devcontainer/devcontainer.sh down                # stop container
#   .devcontainer/devcontainer.sh rebuild             # remove + rebuild (--no-cache)
#   .devcontainer/devcontainer.sh shell               # open a shell inside the container
#   .devcontainer/devcontainer.sh exec <cmd> [args…]  # run a command inside the container
#
# Options (before the subcommand):
#   --variant linux|windows   which .devcontainer/<variant>/devcontainer.json to use
#                             (default: linux)
#
# Requires Node/npx (falls back to `npx --yes @devcontainers/cli` if the
# `devcontainer` CLI isn't installed globally).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_FOLDER="$(cd "${SCRIPT_DIR}/.." && pwd)"
VARIANT="linux"

if command -v devcontainer >/dev/null 2>&1; then
  DEVCONTAINER=(devcontainer)
else
  DEVCONTAINER=(npx --yes @devcontainers/cli)
fi

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      VARIANT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

CONFIG="${SCRIPT_DIR}/${VARIANT}/devcontainer.json"
if [[ ! -f "${CONFIG}" ]]; then
  echo "error: no devcontainer.json for variant '${VARIANT}' at ${CONFIG}" >&2
  exit 1
fi

COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift || true

case "${COMMAND}" in
  up)
    "${DEVCONTAINER[@]}" up \
      --workspace-folder "${WORKSPACE_FOLDER}" \
      --config "${CONFIG}"
    ;;
  down)
    CID="$(docker ps -q --filter "label=devcontainer.local_folder=${WORKSPACE_FOLDER}")"
    if [[ -z "${CID}" ]]; then
      echo "no running container for ${WORKSPACE_FOLDER} (variant: ${VARIANT})"
    else
      docker stop "${CID}"
    fi
    ;;
  rebuild)
    "${DEVCONTAINER[@]}" up \
      --workspace-folder "${WORKSPACE_FOLDER}" \
      --config "${CONFIG}" \
      --remove-existing-container \
      --build-no-cache
    ;;
  shell)
    # docker/devcontainer exec doesn't forward the calling terminal's TERM
    # by default (it defaults to a plain "xterm"), which can make a real
    # Kitty/etc. session render Unicode/Powerline glyphs differently than
    # it does outside the container. Forward it explicitly.
    "${DEVCONTAINER[@]}" exec \
      --workspace-folder "${WORKSPACE_FOLDER}" \
      --config "${CONFIG}" \
      --remote-env "TERM=${TERM:-xterm-256color}" \
      zsh
    ;;
  exec)
    if [[ $# -eq 0 ]]; then
      echo "error: exec requires a command, e.g.: ${BASH_SOURCE[0]} exec bash -lc 'echo hi'" >&2
      exit 1
    fi
    "${DEVCONTAINER[@]}" exec \
      --workspace-folder "${WORKSPACE_FOLDER}" \
      --config "${CONFIG}" \
      --remote-env "TERM=${TERM:-xterm-256color}" \
      "$@"
    ;;
  ""|help)
    usage
    ;;
  *)
    echo "error: unknown subcommand '${COMMAND}'" >&2
    usage
    exit 1
    ;;
esac
