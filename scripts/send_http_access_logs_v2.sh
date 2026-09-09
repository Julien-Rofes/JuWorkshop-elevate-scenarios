#!/usr/bin/env bash

set -euo pipefail

INTAKE_URL="https://intake.sekoia.io/plain"
TARGETS_JSON="${TARGETS_JSON:-}"
HOST="http-server-krk01:443"

if [[ -z "$TARGETS_JSON" && -n "${INTAKE_KEY:-}" ]]; then
  TARGETS_JSON="$(jq -nc --arg key "$INTAKE_KEY" '[{suffix:"single", intake_key:$key}]')"
fi

if [[ -z "$TARGETS_JSON" ]]; then
  read -r -s -p "Enter the JSON target list or intake key: " TARGETS_JSON
  echo
fi

if ! jq -e 'type == "array" and length > 0 and all(.[]; (.intake_key | type == "string" and length > 0))' <<< "$TARGETS_JSON" >/dev/null; then
  echo "Error: TARGETS_JSON must be a non-empty JSON array containing intake_key values." >&2
  exit 1
fi

USERS=("bob" "alice" "tom" "lukas" "john" "gerald")
METHODS=("PUT" "GET")
PUT_STATUSES=(200 201 204)
GET_STATUSES=(200 304 404)
ENDPOINTS=("/api/data" "/api/users" "/api/config" "/api/events" "/dashboard" "/api/reports")
REFERRERS=("https://app.example.com/dashboard" "https://app.example.com/reports" "https://app.example.com/settings" "-")
USER_AGENTS=(
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36"
  "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0"
)

random_element() {
  local arr=("$@")
  echo "${arr[RANDOM % ${#arr[@]}]}"
}

random_ip() {
  echo "$(( RANDOM % 223 + 1 )).$(( RANDOM % 256 )).$(( RANDOM % 256 )).$(( RANDOM % 254 + 1 ))"
}

send_to_all_targets() {
  local payload="$1"
  local target key suffix response_file http_response response_body

  while IFS= read -r target; do
    key="$(jq -r '.intake_key' <<< "$target")"
    suffix="$(jq -r '.suffix // "unknown"' <<< "$target")"
    response_file="$(mktemp)"

    http_response="$(curl -sS -o "$response_file" -w "%{http_code}" \
      -X POST "$INTAKE_URL" \
      -H "X-SEKOIAIO-INTAKE-KEY: $key" \
      -H "Content-Type: text/plain" \
      --data "$payload")"

    response_body="$(cat "$response_file")"
    rm -f "$response_file"

    echo "Target ${suffix}: HTTP ${http_response}"
    if [[ "$http_response" != "200" && "$http_response" != "202" ]]; then
      echo "Target ${suffix} response: ${response_body}"
    fi
  done < <(jq -c '.[]' <<< "$TARGETS_JSON")
}

echo "Starting HTTP access-log sender for $(jq 'length' <<< "$TARGETS_JSON") communities. Press Ctrl+C to stop."

while true; do
  CLIENT_IP=$(random_ip)
  USER=$(random_element "${USERS[@]}")
  METHOD=$(random_element "${METHODS[@]}")
  ENDPOINT=$(random_element "${ENDPOINTS[@]}")
  REFERRER=$(random_element "${REFERRERS[@]}")
  UA=$(random_element "${USER_AGENTS[@]}")
  TIMESTAMP=$(date +"%d/%b/%Y:%H:%M:%S %z")

  if [[ "$METHOD" == "PUT" ]]; then
    STATUS=$(random_element "${PUT_STATUSES[@]}")
  else
    STATUS=$(random_element "${GET_STATUSES[@]}")
  fi

  if [[ "$STATUS" == "204" || "$STATUS" == "304" ]]; then
    SIZE=0
  else
    SIZE=$(( RANDOM % 4096 + 256 ))
  fi

  LOG_LINE="${HOST} ${CLIENT_IP} - ${USER} [${TIMESTAMP}] \"${METHOD} ${ENDPOINT} HTTP/1.1\" ${STATUS} ${SIZE} \"${REFERRER}\" \"${UA}\""

  echo "[$(date +"%H:%M:%S")] User: ${USER} | IP: ${CLIENT_IP} | Method: ${METHOD} | Status: ${STATUS}"
  send_to_all_targets "$LOG_LINE"

  sleep $(( RANDOM % 31 + 15 ))
done
