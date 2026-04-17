#!/usr/bin/env bash
set -euo pipefail

LB_NAME="${1:-}"

if [ -z "$LB_NAME" ]; then
  echo "usage: $0 <load-balancer-name>" >&2
  exit 1
fi

: "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required}"

API_URL="https://api.hetzner.cloud/v1"

mapfile -t LB_IDS < <(curl -fsS \
  -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
  "${API_URL}/load_balancers" | jq -r --arg name "$LB_NAME" '.load_balancers[] | select(.name == $name) | .id')

if [ "${#LB_IDS[@]}" -eq 0 ]; then
  echo "No load balancer named ${LB_NAME} found"
  exit 0
fi

for lb_id in "${LB_IDS[@]}"; do
  echo "Deleting load balancer ${LB_NAME} (${lb_id})"
  curl -fsS \
    -X DELETE \
    -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    "${API_URL}/load_balancers/${lb_id}"
done
