#!/usr/bin/env bash

set -euo pipefail

REVEAL_API_URL="${REVEAL_API_URL:-https://api.sekoia.io/api/v1/xdr-agent/compliance}"
TARGETS_JSON="${TARGETS_JSON:-}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-300}"

if [[ -z "$TARGETS_JSON" ]]; then
  read -r -s -p "Enter the JSON target list: " TARGETS_JSON
  echo
fi

if ! jq -e 'type == "array" and length > 0 and all(.[]; (.intake_key | type == "string" and length > 0))' <<< "$TARGETS_JSON" >/dev/null; then
  echo "Error: TARGETS_JSON must be a non-empty JSON array containing intake_key values." >&2
  exit 1
fi

agent_id_for_hostname() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

AGENT_ID_KRK01="$(agent_id_for_hostname "win-server-krk01")"
AGENT_ID_KRK02="$(agent_id_for_hostname "win-server-krk02")"

echo "Starting Reveal hygiene sender for $(jq 'length' <<< "$TARGETS_JSON") communities."
echo "Sending win-server-krk01 and win-server-krk02 every ${INTERVAL_SECONDS} seconds."

send_compliance_to_all_targets() {
  local hostname="$1"
  local agent_id="$2"
  local target key suffix payload response_file http_status response_body

  payload="$(jq -nc --arg hostname "$hostname" '{hostname: $hostname, firewall_enabled: false, last_seen: "2026-07-27T17:40:00+00:00"}')"

  while IFS= read -r target; do
    key="$(jq -r '.intake_key' <<< "$target")"
    suffix="$(jq -r '.suffix // "unknown"' <<< "$target")"
    response_file="$(mktemp)"

    http_status="$(curl -sS -o "$response_file" -w "%{http_code}" \
      --request POST \
      --header "Authorization: IntakeKey ${key}" \
      --header "Sekoia-Agent-ID: ${agent_id}" \
      --header "Content-Type: application/json" \
      --data "$payload" \
      "$REVEAL_API_URL")"

    response_body="$(cat "$response_file")"
    rm -f "$response_file"

    echo "${hostname}, target ${suffix}: HTTP ${http_status}"
    if [[ "$http_status" != "200" && "$http_status" != "202" ]]; then
      echo "${hostname}, target ${suffix} response: ${response_body}"
    fi
  done < <(jq -c '.[]' <<< "$TARGETS_JSON")
}

while true; do
  send_compliance_to_all_targets "win-server-krk01" "$AGENT_ID_KRK01"
  send_compliance_to_all_targets "win-server-krk02" "$AGENT_ID_KRK02"
  echo "Next Reveal hygiene cycle in ${INTERVAL_SECONDS} seconds."
  sleep "$INTERVAL_SECONDS"
done
