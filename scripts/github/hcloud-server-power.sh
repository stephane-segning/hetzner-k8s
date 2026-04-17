#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"

if [ -z "$ACTION" ]; then
  echo "usage: $0 <poweron|poweroff>" >&2
  exit 1
fi

case "$ACTION" in
  poweron|poweroff) ;;
  *)
    echo "unsupported action: $ACTION" >&2
    exit 1
    ;;
esac

: "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required}"

TF_DIR="${TF_DIR:-terraform/envs/prod}"
API_URL="https://api.hetzner.cloud/v1"

mapfile -t SERVER_IDS < <(terraform -chdir="$TF_DIR" output -json server_details | jq -r 'to_entries[].value.id')

if [ "${#SERVER_IDS[@]}" -eq 0 ]; then
  echo "No servers found in Terraform state"
  exit 0
fi

for server_id in "${SERVER_IDS[@]}"; do
  echo "Requesting ${ACTION} for server ${server_id}"
  response=$(curl -fsS \
    -X POST \
    -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API_URL}/servers/${server_id}/actions/${ACTION}") || {
      echo "Failed to request ${ACTION} for server ${server_id}" >&2
      exit 1
    }

  action_id=$(printf '%s' "$response" | jq -r '.action.id // empty')

  if [ -z "$action_id" ]; then
    echo "No action returned for server ${server_id}, continuing"
    continue
  fi

  for _ in $(seq 1 30); do
    status=$(curl -fsS \
      -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
      "${API_URL}/actions/${action_id}" | jq -r '.action.status')

    if [ "$status" = "success" ]; then
      echo "${ACTION} completed for server ${server_id}"
      break
    fi

    if [ "$status" = "error" ]; then
      echo "${ACTION} failed for server ${server_id}" >&2
      exit 1
    fi

    sleep 5
  done
done
