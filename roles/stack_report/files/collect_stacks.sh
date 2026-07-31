#!/usr/bin/env bash
# Reports Docker Compose stacks and the env var *names* explicitly set by the
# user (directly in the compose file's `environment:` or via `env_file`/.env).
# Image-default env vars (baked into the Dockerfile) are excluded.
# Never prints env var values.
set -uo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo '{"projects": []}'
  exit 0
fi

tmp_projects=$(mktemp)
trap 'rm -f "$tmp_projects"' EXIT

ls_json=$(docker compose ls -a --format json 2>/dev/null)
[ -z "$ls_json" ] && ls_json='[]'

echo "$ls_json" | jq -c '.[]?' 2>/dev/null | while IFS= read -r project; do
  name=$(jq -r '.Name' <<<"$project")
  status=$(jq -r '.Status' <<<"$project")
  config_files_raw=$(jq -r '.ConfigFiles' <<<"$project")
  working_dir=$(dirname "${config_files_raw%%,*}")

  # Build -f flags for every compose file in the project
  f_args=()
  IFS=',' read -ra _files <<<"$config_files_raw"
  for f in "${_files[@]}"; do
    [ -n "$f" ] && f_args+=(-f "$f")
  done

  # Resolved compose config: environment merges `environment:` + `env_file`/.env,
  # but NOT the image's own Dockerfile ENV defaults.
  compose_config_json=$(cd "$working_dir" 2>/dev/null && docker compose -p "$name" "${f_args[@]}" config --format json 2>/dev/null)
  [ -z "$compose_config_json" ] && compose_config_json='{"services":{}}'
  service_env_map=$(jq -c '[.services // {} | to_entries[] | {key: .key, value: ((.value.environment // {}) | keys | sort)}] | from_entries' <<<"$compose_config_json" 2>/dev/null)
  [ -z "$service_env_map" ] && service_env_map='{}'

  services_json="[]"
  while IFS='|' read -r cid service; do
    [ -z "$cid" ] && continue
    cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')
    [ -z "$cname" ] && cname="$cid"
    env_keys=$(jq -c --arg svc "$service" '.[$svc] // []' <<<"$service_env_map" 2>/dev/null)
    [ -z "$env_keys" ] && env_keys='[]'
    service_obj=$(jq -n --arg service "$service" --arg container "$cname" --argjson env_keys "$env_keys" \
      '{service: $service, container: $container, env_keys: $env_keys}')
    services_json=$(jq -c --argjson svc "$service_obj" '. + [$svc]' <<<"$services_json")
  done < <(docker ps -a --filter "label=com.docker.compose.project=${name}" \
    --format '{{.ID}}|{{.Label "com.docker.compose.service"}}' 2>/dev/null)

  jq -n --arg name "$name" --arg status "$status" --arg working_dir "$working_dir" --argjson services "$services_json" \
    '{name: $name, status: $status, working_dir: $working_dir, services: $services}'
done >>"$tmp_projects"

jq -M -s '{projects: .}' "$tmp_projects"
